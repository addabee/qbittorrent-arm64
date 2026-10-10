# qBittorrent for Windows on ARM (unofficial)

Native **Windows ARM64** builds of [qBittorrent](https://www.qbittorrent.org/), compiled from the unmodified upstream release tags (apart from the small changes listed below). These run natively on Snapdragon / Windows on ARM devices with no x64 emulation.

> **Unofficial builds.** They are not produced, endorsed or supported by the qBittorrent project. Please report problems with these builds here rather than upstream, unless you can also reproduce them with an official build.

## Download

Get the latest release from [Releases](../../releases):

| File | What it is |
|---|---|
| `qbittorrent_<version>_arm64_setup.exe` | Installer. Includes `.torrent` and `magnet:` associations, Start Menu shortcut, firewall rule and uninstaller. |
| `qBittorrent-<version>-arm64-portable.zip` | Portable version. Unzip and run `qbittorrent.exe`; settings are kept in the `profile` folder next to it. |
| `SHA256SUMS.txt` | Checksums for both files. |

The files are not code-signed, so SmartScreen will warn the first time: choose **More info → Run anyway**. Search plugins need [Python 3 for ARM64](https://www.python.org/downloads/windows/).

## What's in a build

- qBittorrent (latest stable `release-X.Y.Z` tag), Qt 6, libtorrent **2.0.x**, Boost, OpenSSL, zlib, all compiled natively for ARM64 with MSVC and [vcpkg](https://github.com/microsoft/vcpkg).
- Every `.exe` and `.dll` is checked to be ARM64. The exceptions are Microsoft's `vcruntime140_1.dll`, which is an ARM64X hybrid, and the installer's NSIS uninstaller, which is x86 as in upstream.
- Each release is smoke-tested: native process, Web UI authentication, and a real (legal) download of a Debian ARM64 image.

## Changes from upstream

GPLv2 §2(a) requires modified versions to say what changed. These are all the changes:

1. **Update checker.** In `src/gui/programupdater.cpp`, the build variant string is set to `Windows ARM64` instead of `Windows x64`, so the built-in update checker doesn't offer x64 installers. Check this repository's Releases for updates.
2. **libtorrent 2.0.x.** libtorrent is pinned to the newest 2.0.x port in vcpkg's history, because qBittorrent 5.x doesn't support libtorrent 2.1.
3. **Installer**, built from upstream's `dist/windows` NSIS scripts with `QBT_CPU_ARCH=arm64`:
   - **Uninstaller.** It removes the Qt, OpenSSL and libtorrent DLLs, plus the Qt plugins, that this build ships as separate files. Upstream links everything into one exe, so its uninstaller only removes that exe.
   - **64-bit registry.** The installer and uninstaller use the 64-bit registry view (`SetRegView 64`), so the Default apps registration points at the right place.
   - **Clean uninstall.** The uninstaller also removes the `RegisteredApplications` value.

No other source changes are made.

## Building it yourself

You need an ARM64 Windows machine with Visual Studio 2022 or its Build Tools (the *Desktop development with C++* workload plus the *MSVC ARM64 build tools*), CMake, Git and, for the installer, [NSIS](https://nsis.sourceforge.io/). All scripts take `-Root` as the working directory (default `C:\dev\qbt-arm64`). Keep it short, with no spaces.

```powershell
git clone --depth 1 --branch release-5.2.4 https://github.com/qbittorrent/qBittorrent.git C:\dev\qbt-arm64\qBittorrent
.\scripts\install-deps.ps1      # vcpkg dependencies; takes about 30-60 min the first time
.\scripts\build-qbt.ps1         # build, then stage dist\qBittorrent and the portable zip
.\scripts\build-installer.ps1   # NSIS installer
.\scripts\smoke-test.ps1        # optional: verify the build
```

## Automated builds

[`.github/workflows/build-arm64.yml`](.github/workflows/build-arm64.yml) runs on GitHub's `windows-11-arm` runner. Every day it checks for a new stable qBittorrent tag, and when there is one it builds it, tests it and publishes a release.

To build manually, open **Actions → Build qBittorrent Windows ARM64 → Run workflow**. You can optionally enter a tag such as `5.2.4`.

## License

- **qBittorrent** is licensed under GPL-2.0-or-later. Each release links to the exact upstream source tag. The complete corresponding source is that tag plus this repository at the commit named in the release notes. Third-party license texts (Qt, OpenSSL, libtorrent, Boost, zlib, …) are in the `licenses` folder of every build.
- **The scripts and workflow in this repository** are licensed under the [MIT License](LICENSE).

qBittorrent is a trademark of its respective owners. This project is not affiliated with it.
