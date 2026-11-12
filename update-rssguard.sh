#!/bin/bash

# Script for updating or installing RSSGuard on Linux
# Features:
# - Smart caching: Reuses builds only on compatible CPU architectures and Debian releases
# - Resume capability: Continues from where it left off if interrupted
# - State tracking: Remembers completed build steps per version, architecture, and OS release
# - Run-state preservation: Only restarts if RSSGuard was running
# - Patch system: Supports code replacements for problematic versions

set -e  # Exit on error
set -u  # Exit on undefined variable

# When already running as root (e.g. inside a CI build container), there is no
# sudo binary and none is needed: execute the commands directly instead.
if [ "$(id -u)" -eq 0 ]; then
  sudo() { "$@"; }
fi

#==============================================================================
# BUILD CONFIGURATION
#==============================================================================
# Use 2 parallel jobs for compilation (leaves 2 CPUs free on 4-core Pi)
CMAKE_BUILD_JOBS=2

## Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_LIBRARY="${SCRIPT_DIR}/build-library"
WORKING_DIR="$HOME/Documents/rssguard-build"
INSTALL_PREFIX="/usr/local"
RSSGUARD_SYSTEMD_SERVICE="rssguard.service"

## Step 0: Check for command-line argument
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <version_or_url> [options]"
  echo "Examples:"
  echo "  $0 4.8.6"
  echo "  $0 5.0.0 --build-only"
  echo "  $0 https://github.com/martinrotter/rssguard/archive/refs/tags/4.8.6.zip"
  echo ""
  echo "Options:"
  echo "  --build-only    Build and cache without installing (run without flag to install later)"
  echo "  --no-prebuilt   Ignore prebuilt GitHub releases, always compile"
  exit 1
fi

INPUT="$1"
BUILD_ONLY=false
PREBUILT_ENABLED=true # Default: use prebuilt GitHub release when available

# Parse options (remaining arguments after version/URL)
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    --no-prebuilt)
      PREBUILT_ENABLED=false
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

GIT_REPO_URL="https://github.com/martinrotter/rssguard.git"

# Detect if input is a version number or URL
if [[ "$INPUT" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  # Input is a version number - use git clone
  VERSION="$INPUT"
  USE_GIT_CLONE=true
  echo "Version detected: ${VERSION}"
  echo "Using git clone: ${GIT_REPO_URL} (tag: ${VERSION})"
  echo ""
else
  # Input is a direct URL - fall back to zip download
  DOWNLOAD_URL="$INPUT"
  USE_GIT_CLONE=false
  VERSION=$(basename "$DOWNLOAD_URL" | sed -E 's/^(rssguard-)?([0-9.]+)(\.zip|\.tar\.gz)?$/\2/')
fi

## Step 1: Validate version
if [ -z "$VERSION" ]; then
  echo "ERROR: Failed to determine version."
  exit 1
fi

MAJOR_VERSION=$(echo "$VERSION" | cut -d. -f1)
EXTRACT_DIR="rssguard-${VERSION}"
BUILD_DIR="build-dir-${VERSION}"

echo "Building RSSGuard version ${VERSION}..."
echo ""

## State tracking functions
# CACHE_DIR and STATE_DIR are initialized after architecture detection.

mark_task_done() {
  mkdir -p "$STATE_DIR"
  touch "${STATE_DIR}/$1"
}

is_task_done() {
  [ -f "${STATE_DIR}/$1" ]
}

clear_state() {
  rm -rf "$STATE_DIR"
}

## Architecture detection
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
  ARCH_SUFFIX="aarch64"
elif [ "$ARCH" = "x86_64" ]; then
  ARCH_SUFFIX="x86_64"
else
  echo "WARNING: Unsupported architecture: $ARCH"
  ARCH_SUFFIX="$ARCH"
fi

# Native build caches must not be shared across CPU architectures or
# incompatible Debian releases.
OS_CACHE_ID="$(
  . /etc/os-release
  printf '%s-%s' "${ID:-linux}" "${VERSION_ID:-unknown}"
)"

CACHE_DIR="${BUILD_LIBRARY}/rssguard/${VERSION}-${ARCH_SUFFIX}-${OS_CACHE_ID}"
STATE_DIR="${CACHE_DIR}/state"

echo "Build cache target: ${CACHE_DIR}"

## Check if already cached
INSTALLED_DESKTOP="${INSTALL_PREFIX}/share/applications/io.github.martinrotter.rssguard.desktop"

# Check if cache exists
CACHE_COMPLETE=false

if [ -x "${CACHE_DIR}/bin/rssguard" ] && \
   [ -f "${CACHE_DIR}/lib/librssguard.so" ] && \
   [ -d "${CACHE_DIR}/lib/rssguard" ] && \
   [ -n "$(find "${CACHE_DIR}/lib/rssguard" -maxdepth 1 -type f -name 'librssguard-*.so' -print -quit)" ]; then
  CACHE_COMPLETE=true
fi

if [ "$CACHE_COMPLETE" = true ]; then
  echo "✓ RSSGuard ${VERSION} already cached"
  if [ "$BUILD_ONLY" = true ]; then
    echo "  Build-only mode: skipping installation"
  else
    echo "  Will install from cache"
  fi
  echo ""
else
  echo "NOTE: First build will take 1-2 hours on Raspberry Pi, 10-30 min on faster systems."
  echo "Subsequent builds will use cached installation."
  echo ""
fi

## Step 2: Install system dependencies
# NOTE: Dependencies are system packages (Qt6, libmpv, etc.) and must be installed
# even when using cached RSSGuard build, as they are not included in the cache.
echo "Installing system dependencies..."
sudo apt-get update

# Core dependencies (all versions)
DEPS="cmake build-essential git qt6-base-dev qt6-tools-dev qt6-declarative-dev \
  qt6-multimedia-dev qt6-webengine-dev qt6-5compat-dev libmpv-dev wget unzip"

# v5+ requires golang-go for the standalone article extractor
if [ "$MAJOR_VERSION" -ge 5 ]; then
  DEPS="$DEPS golang-go"
fi

# shellcheck disable=SC2086
sudo apt-get install -y $DEPS

echo "✓ Dependencies installed"
echo ""

## Optional fast path: official prebuilt build from GitHub Releases.
# Supported only on aarch64 with Debian 13 or newer (the release binaries are
# built in a debian:13 container). Anything else, or a version without a
# published release, falls back to compiling from source.
if [ "$PREBUILT_ENABLED" = true ] && [ "$CACHE_COMPLETE" = false ]; then
  PREBUILT_COMPATIBLE="$(
    . /etc/os-release
    if [ "$ARCH_SUFFIX" = "aarch64" ] && [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-0}" -ge 13 ] 2>/dev/null; then
      echo yes
    else
      echo no
    fi
  )"

  if [ "$PREBUILT_COMPATIBLE" = yes ]; then
    PREBUILT_URL="https://github.com/Bro-Account/rssguard-rpi/releases/download/v${VERSION}/rssguard-${VERSION}-linux-aarch64.tar.gz"
    PREBUILT_TARBALL="${CACHE_DIR}.prebuilt.tar.gz"

    echo "Checking for prebuilt RSSGuard ${VERSION} on GitHub Releases..."
    if wget --spider -q "$PREBUILT_URL"; then
      echo "  Found: downloading prebuilt build (no compilation needed)..."
      if wget --timeout=30 --tries=3 \
         --output-document="$PREBUILT_TARBALL" "$PREBUILT_URL" \
         && tar tzf "$PREBUILT_TARBALL" >/dev/null 2>&1; then

        # Store it in the same layout a fresh build would have produced,
        # so the rest of the script (cache check, installation) just works.
        mkdir -p "$CACHE_DIR"
        tar xzf "$PREBUILT_TARBALL" -C "$CACHE_DIR"
        rm -f "$PREBUILT_TARBALL"

        CACHE_COMPLETE=true
        mark_task_done "cached"

        echo "  ✓ Prebuilt build stored in ${CACHE_DIR}"
      else
        echo "  ⚠ Download failed - falling back to building from source"
      fi
    else
      echo "  No prebuilt release for ${VERSION} - will build from source"
    fi
    echo ""
  fi
fi

## Early exit if binary and resources are cached
if [ "$CACHE_COMPLETE" = true ]; then
  # Skip to installation section
  SKIP_BUILD=true
else
  SKIP_BUILD=false
fi

if [ "$SKIP_BUILD" = false ]; then
  # State files are persistent, but the temporary build workspace may have
  # been removed after an earlier successful build or manual cleanup.
  if { is_task_done "extracted" && [ ! -d "${WORKING_DIR}/${EXTRACT_DIR}" ]; } || \
     { is_task_done "configured" && [ ! -d "${WORKING_DIR}/${BUILD_DIR}" ]; }; then
    echo "WARNING: Build state exists but its workspace is missing."
    echo "         Clearing stale state and starting this build cleanly."
    clear_state
  fi
  ## Step 3: Setup working directory
  mkdir -p "$WORKING_DIR"
  cd "$WORKING_DIR" || { echo "ERROR: Failed to access working directory"; exit 1; }
  
  ## Steps 4+5: Fetch source code (git clone includes submodules; zip falls back for direct URLs)
  if ! is_task_done "extracted"; then
    # Remove any incomplete previous attempt
    [ -d "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
    
    if [ "$USE_GIT_CLONE" = true ]; then
      echo "Cloning RSSGuard ${VERSION} with submodules (this downloads ~100 MB)..."
      git clone --recurse-submodules --depth 1 --branch "$VERSION" \
        "$GIT_REPO_URL" "$EXTRACT_DIR" || {
        echo "ERROR: git clone failed"
        exit 1
      }
      # Clear downstream states so patches/configure run fresh on new source
      rm -f "${STATE_DIR}/patched" "${STATE_DIR}/configured"
    else
      # Fallback: wget + unzip for direct URL input
      # Note: submodule directories will be empty with this method
      ZIP_NAME="rssguard-${VERSION}.zip"
      echo "Downloading RSSGuard ${VERSION} source via URL..."
      wget --output-document="$ZIP_NAME" "$DOWNLOAD_URL" || {
        echo "ERROR: Download failed"
        exit 1
      }
      echo "Extracting source..."
      unzip -qo "$ZIP_NAME" || {
        echo "ERROR: Failed to extract package"
        exit 1
      }
      if [ ! -d "$EXTRACT_DIR" ]; then
        FOLDER_ADJUST=$(find . -maxdepth 1 -type d -name "rssguard-*" | grep -F "$VERSION" | head -n1)
        [ -n "$FOLDER_ADJUST" ] && mv "$FOLDER_ADJUST" "$EXTRACT_DIR"
      fi
    fi
    
    mark_task_done "downloaded"
    mark_task_done "extracted"
    echo "✓ Source ready in ${EXTRACT_DIR}/"
    echo ""
  else
    echo "✓ Source already fetched"
    echo ""
  fi
  
  ## Step 6: Apply patches (if needed)
  # This section allows version-specific fixes
  if ! is_task_done "patched"; then
    echo "Checking for required patches..."
    
    PATCHES_APPLIED=false
    
    # Example patch structure (add version-specific fixes here):
    # if [ "$VERSION" = "4.8.1" ]; then
    #   echo "  Applying fix for version 4.8.1..."
    #   sed -i 's/old_code/new_code/g' "$EXTRACT_DIR/path/to/file.cpp"
    #   PATCHES_APPLIED=true
    # fi
    
    if [ "$PATCHES_APPLIED" = true ]; then
      echo "✓ Patches applied"
    else
      echo "✓ No patches required for version ${VERSION}"
    fi
    
    mark_task_done "patched"
    echo ""
  else
    echo "✓ Patches already applied (if any)"
    echo ""
  fi
  
  ## Step 7: Configure build
  if ! is_task_done "configured"; then
    echo "Configuring build..."
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || {
      echo "ERROR: Failed to access build directory"
      exit 1
    }
    
    cmake \
      -DUSE_SYSTEM_SQLITE=OFF \
      -DCMAKE_BUILD_TYPE="Release" \
      "../$EXTRACT_DIR" || {
      echo "ERROR: CMake configuration failed"
      exit 1
    }
    
    mark_task_done "configured"
    echo "✓ Build configured"
    echo ""
  else
    echo "✓ Build already configured"
    cd "$BUILD_DIR" || {
      echo "ERROR: Failed to access build directory"
      exit 1
    }
    echo ""
  fi
  
  ## Step 8: Build RSSGuard
  if ! is_task_done "built"; then
    echo "Building RSSGuard ${VERSION}..."
    echo "This will take 10-30 minutes depending on your system..."
    echo ""
    
    cmake --build . --parallel ${CMAKE_BUILD_JOBS} || {
      echo "ERROR: Build failed"
      echo ""
      echo "To resume after fixing issues, run the script again."
      exit 1
    }
    
    mark_task_done "built"
    echo ""
    echo "✓ Build completed successfully"
    echo ""
  else
    echo "✓ Already built"
    echo ""
  fi
  
  ## Step 9: Cache using cmake install
  if ! is_task_done "cached"; then
    echo "Caching RSSGuard installation for future use..."
    echo "  Using cmake to install to cache directory..."
    
    # Remove old cache if exists to ensure clean installation
    rm -rf -- \
      "${CACHE_DIR:?}/bin" \
      "${CACHE_DIR:?}/lib" \
      "${CACHE_DIR:?}/include" \
      "${CACHE_DIR:?}/share" \
      2>/dev/null || true
    
    # Let cmake install everything to cache directory with proper structure
    cmake --install . --prefix "${CACHE_DIR}" || {
      echo "ERROR: Failed to cache installation"
      exit 1
    }
    
    # Verify the cache using the same strict criteria used before installation.
    if [ ! -x "${CACHE_DIR}/bin/rssguard" ] || \
       [ ! -f "${CACHE_DIR}/lib/librssguard.so" ] || \
       [ ! -d "${CACHE_DIR}/lib/rssguard" ] || \
       [ -z "$(find "${CACHE_DIR}/lib/rssguard" -maxdepth 1 -type f -name 'librssguard-*.so' -print -quit)" ]; then

      echo "ERROR: Cache validation failed after installation."
      echo "       Required RSS Guard binary, core library, or plugins are missing."

      rm -f "${STATE_DIR}/cached"
      exit 1
    fi

    mark_task_done "cached"
    echo "✓ Complete installation cached to ${CACHE_DIR}/"
    echo ""
  else
    echo "✓ Installation already cached"
    echo ""
  fi
fi

## Step 10: Install / run-state management (skipped in --build-only mode)
if [ "$BUILD_ONLY" = true ]; then
  echo "Build-only mode: skipping installation."
  echo ""
  echo "=================================================="
  echo "RSSGuard ${VERSION} build and cache complete!"
  echo "Run the script again without --build-only to install."
  echo "=================================================="
  exit 0
fi

## Step 10: Check RSS Guard run state

echo "Checking RSS Guard run state..."

WAS_RUNNING=false
WAS_MANAGED_BY_SYSTEMD=false

# Prefer systemd management when the configured RSS Guard service is active.
if sudo systemctl is-active --quiet "$RSSGUARD_SYSTEMD_SERVICE"; then
  WAS_RUNNING=true
  WAS_MANAGED_BY_SYSTEMD=true

  echo "  RSS Guard is running as systemd service: ${RSSGUARD_SYSTEMD_SERVICE}"
  echo "  It will be stopped before installation and restarted afterwards."
  echo ""

  echo "Stopping RSS Guard through systemd..."
  sudo systemctl stop "$RSSGUARD_SYSTEMD_SERVICE"

  if sudo systemctl is-active --quiet "$RSSGUARD_SYSTEMD_SERVICE"; then
    echo "ERROR: RSS Guard systemd service is still active after stop request."
    exit 1
  fi

  echo "✓ RSS Guard systemd service stopped successfully"
  echo ""

else
  # Fallback for a manually launched RSS Guard instance.
  RSSGUARD_PIDS=$(pgrep -x rssguard || true)

  if [ -n "$RSSGUARD_PIDS" ]; then
    WAS_RUNNING=true

    echo "  RSS Guard is running outside systemd (PIDs: ${RSSGUARD_PIDS})"
    echo "  It will be restarted manually after installation."
    echo ""

    echo "Stopping manually launched RSS Guard..."

    for PID in $RSSGUARD_PIDS; do
      kill -SIGTERM "$PID" 2>/dev/null || true
    done

    echo "  Waiting for RSS Guard to close..."

    WAIT_COUNT=0

    while pgrep -x rssguard >/dev/null 2>&1; do
      sleep 2
      WAIT_COUNT=$((WAIT_COUNT + 1))

      if [ $((WAIT_COUNT % 15)) -eq 0 ]; then
        echo "    Still waiting... ($((WAIT_COUNT * 2)) seconds)"
      fi
    done

    echo "✓ Manually launched RSS Guard stopped successfully"
    echo ""

  else
    echo "  RSS Guard is not currently running"
    echo "  It will not be started after installation"
    echo ""
  fi
fi

## Step 11: Install RSSGuard
echo "Installing RSSGuard ${VERSION}..."
  
  # Install from cache or from build directory
  if [ -f "${CACHE_DIR}/bin/rssguard" ]; then
    # Install from cache - copy entire directory structure
    echo "  Installing from cache to ${INSTALL_PREFIX}..."
    
    # RSS Guard plugins must exactly match the installed librssguard library.
    # Remove plugins from earlier versions before installing this version.
    echo "    Removing old RSS Guard plugin directory..."
    sudo rm -rf -- "${INSTALL_PREFIX}/lib/rssguard"

    # Ensure installation directories exist.
    for DIR in bin lib include share; do
      sudo install -d -m 0755 "${INSTALL_PREFIX}/${DIR}"
    done

    # Copy the cached installation. '/.' copies all contents reliably,
    # including hidden files if any exist.
    for DIR in bin lib include share; do
      if [ -d "${CACHE_DIR}/${DIR}" ]; then
        echo "    Copying ${DIR}/..."
        sudo cp -a "${CACHE_DIR}/${DIR}/." "${INSTALL_PREFIX}/${DIR}/"
      fi
    done

    # Ensure executable permission is set.
    sudo chmod 0755 "${INSTALL_PREFIX}/bin/rssguard"

    # System-installed binaries and libraries should not remain writable by
    # the regular build user.
    sudo chown root:root "${INSTALL_PREFIX}/bin/rssguard"
    sudo chown root:root "${INSTALL_PREFIX}/lib/librssguard.so"
    sudo chmod 0644 "${INSTALL_PREFIX}/lib/librssguard.so"

    sudo chown -R root:root "${INSTALL_PREFIX}/lib/rssguard"
    sudo find "${INSTALL_PREFIX}/lib/rssguard" -type d -exec chmod 0755 {} +

    sudo find "${INSTALL_PREFIX}/lib/rssguard" -type f -exec chmod 0644 {} +

    # Verify that the installed binary and plugins exactly match the cache.
    if ! cmp -s \
      "${CACHE_DIR}/bin/rssguard" \
      "${INSTALL_PREFIX}/bin/rssguard"; then

      echo "ERROR: Installed RSS Guard executable does not match cached executable."
      exit 1
    fi

    if ! diff -qr \
      "${CACHE_DIR}/lib/rssguard" \
      "${INSTALL_PREFIX}/lib/rssguard"; then

      echo "ERROR: Installed RSS Guard plugins do not match cached plugins."
      exit 1
    fi

    echo "  ✓ All files installed from cache and verified"
  else

    echo "ERROR: RSS Guard cache is missing or incomplete at installation time."
    echo "       Refusing to install directly because stale plugins could remain installed."
    echo "       Run the script again to rebuild and recreate the cache."
    exit 1

  fi
  
  echo "✓ RSSGuard installed to ${INSTALL_PREFIX}/bin/rssguard"
  
  # Verify installation and update desktop database
  if [ -f "$INSTALLED_DESKTOP" ]; then
    echo "✓ Desktop entry installed"
    
    # Update desktop database to make menu entry appear immediately
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database "${INSTALL_PREFIX}/share/applications" 2>/dev/null || true
      sudo update-desktop-database /usr/share/applications 2>/dev/null || true
      echo "✓ Desktop database updated"
    fi
    
    # Update icon cache to ensure icon appears correctly
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      sudo gtk-update-icon-cache -f -t "${INSTALL_PREFIX}/share/icons/hicolor" 2>/dev/null || true
      echo "✓ Icon cache updated"
    fi
  else
    echo "⚠ Warning: Desktop entry not found at $INSTALLED_DESKTOP"
    echo "  Checking what was installed..."
    ls -la "${INSTALL_PREFIX}/share/applications/"*rssguard* 2>/dev/null || echo "  No RSSGuard desktop files found"
  fi
  echo ""

## Step 11.5: Configure dynamic linker for shared libraries
echo "Configuring dynamic linker for shared libraries..."
LINKER_CONF="/etc/ld.so.conf.d/local.conf"

# Check if /usr/local/lib is already in linker configuration
if ! grep -qx "/usr/local/lib" "$LINKER_CONF" 2>/dev/null; then
  echo "  Adding /usr/local/lib to dynamic linker search path..."
  echo "/usr/local/lib" | sudo tee "$LINKER_CONF" >/dev/null
  echo "✓ Linker configuration created at ${LINKER_CONF}"
else
  echo "✓ /usr/local/lib already in linker search path"
fi

# Update the dynamic linker cache
echo "  Updating dynamic linker cache..."
sudo ldconfig
echo "✓ Dynamic linker cache updated"
echo ""

## Step 12: Restart RSS Guard only if it was running

if [ "$WAS_RUNNING" = true ]; then
  echo "Restarting RSS Guard..."

  if [ "$WAS_MANAGED_BY_SYSTEMD" = true ]; then
    sudo systemctl start "$RSSGUARD_SYSTEMD_SERVICE"

    if sudo systemctl is-active --quiet "$RSSGUARD_SYSTEMD_SERVICE"; then
      echo "✓ RSS Guard restarted successfully through systemd"
    else
      echo "WARNING: RSS Guard systemd service failed to start."
      echo "Run: sudo systemctl status ${RSSGUARD_SYSTEMD_SERVICE} --no-pager"
      echo "Run: sudo journalctl -u ${RSSGUARD_SYSTEMD_SERVICE} -n 100 --no-pager"
    fi

  else
    nohup "${INSTALL_PREFIX}/bin/rssguard" >/dev/null 2>&1 &

    sleep 2

    if pgrep -x rssguard >/dev/null 2>&1; then
      echo "✓ RSS Guard restarted successfully"
    else
      echo "WARNING: RSS Guard failed to start. Please start it manually."
    fi
  fi

  echo ""
fi

## Step 13: Cleanup temporary files
echo "Cleaning up temporary build files..."
if [ -d "$WORKING_DIR" ]; then
  # Only clean if build was successful and cached
  if is_task_done "cached"; then
    rm -rf "$WORKING_DIR"
    echo "✓ Temp files cleaned from ${WORKING_DIR}"
  else
    echo "✓ Build directory preserved at ${WORKING_DIR} (not yet cached)"
  fi
else
  echo "✓ No temp files to clean"
fi
echo "✓ Build cache preserved in ${CACHE_DIR}"
echo ""

## Final summary
echo "=================================================="
echo "RSSGuard update completed successfully!"
echo "Version: ${VERSION}"
echo "Binary location: ${INSTALL_PREFIX}/bin/rssguard"
echo "Cache location: ${CACHE_DIR}"
echo ""
if [ "$WAS_RUNNING" = true ]; then
  echo "Status: Running (restarted)"
else
  echo "Status: Installed (not started)"
fi
echo "=================================================="