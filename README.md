# update-rssguard.sh

Build and install [RSSGuard](https://github.com/martinrotter/rssguard) from
source on Debian / Raspberry Pi OS — with smart caching so you only ever
compile each version once.

## Features

- **Smart caching** — compiled versions are stored in `build-library/`, keyed
  by RSSGuard version, CPU architecture, and OS release. Re-running the script
  for an already-built version installs it from cache in seconds.
- **Resumable** — the download, configure, and build steps track their state,
  so an interrupted build continues where it left off.
- **Run-state preservation** — if RSSGuard is running when the update starts,
  it is stopped first and restarted afterwards; if it was not running, it
  stays stopped.
- **Optional systemd support** — if RSSGuard runs as a systemd service, the
  script stops and restarts it via `systemctl`. Without such a service it
  falls back to plain process handling, so the script works on any system.
- **Patch system** — supports small version-specific source fixes before
  compiling.

## Requirements

- Debian 13 / Raspberry Pi OS (Trixie), 64-bit (aarch64; x86_64 also works)
- Internet access, and enough free space in `~/Documents` (~2 GB during the
  build) and next to the script (~200 MB per cached version)

## Usage

On Raspberry Pi OS / Debian 13+ (aarch64) the script first checks whether an
official prebuilt build of the requested version exists on this repository's
[Releases](../../releases) page. If yes, it downloads and installs it in
seconds — no compilation. If not (or on other systems/OS versions), it falls
back to building from source. Either way the script handles stopping and
restarting RSSGuard, installing to `/usr/local`, and updating the desktop,
icon, and linker caches.

```sh
./update-rssguard.sh 5.3.0                  # install prebuilt (or build from source)
./update-rssguard.sh 5.3.0 --no-prebuilt    # force a local source build
./update-rssguard.sh 5.3.0 --build-only     # fetch/build into the cache only, install later
./update-rssguard.sh <URL-to-source-zip>    # build from a direct download link
```

The script installs itself everything it needs (Qt6, cmake, libmpv, etc. via
`apt`), clones the given tag from the upstream repository, builds, installs to
`/usr/local`, and updates the desktop/icon caches and dynamic linker.

Build time: **1–2 hours on a Raspberry Pi**, 10–30 minutes on faster systems.
Subsequent installs of the same version are instant.

## Prebuilt binaries

This repository builds RSSGuard automatically for **Raspberry Pi OS / Debian
13 (aarch64)** via GitHub Actions (Debian 13 container on an ARM64 runner),
and the script consumes these builds directly: `./update-rssguard.sh <version>`
downloads the matching release, seeds the local cache, and installs it with
full run-state handling.

The tarballs can also be installed by hand:

```sh
sudo tar -xzf rssguard-<version>-linux-aarch64.tar.gz -C /usr/local
sudo ldconfig
```

(note that Qt6 runtime libraries such as `libqt6core6t64`, `libqt6gui6` and
`libqt6widgets6` must be installed in that case — the script's dependency
step takes care of this automatically)

## How CI builds work

- Trigger: push a tag `v<version>` (e.g. `v5.3.0`), run the workflow manually
  from the *Actions* tab (leaving the version empty auto-detects the latest
  upstream release), or wait for the **daily scheduled check**, which builds
  and publishes every new upstream RSSGuard release automatically.
- The workflow runs `./update-rssguard.sh <version> --build-only` inside a
  `debian:13` container, so binaries match Raspberry Pi OS Trixie.
- Tag builds are attached to a GitHub Release; manual runs are available as
  workflow artifacts.

## Notes

- RSSGuard is GPLv3; these builds are compiled from unmodified upstream
  source. This repository's script itself is MIT licensed.
- The script only *uses* an existing `rssguard.service` — it does not create
  one.
