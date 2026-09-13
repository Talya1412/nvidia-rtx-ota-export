# nvidia-rtx-ota-export

[![Latest Release](https://img.shields.io/github/v/release/Talya1412/nvidia-rtx-ota-export?color=76b900&label=latest%20OTA)](https://github.com/Talya1412/nvidia-rtx-ota-export/releases/latest)
[![ota-release](https://github.com/Talya1412/nvidia-rtx-ota-export/actions/workflows/ota-release.yml/badge.svg)](https://github.com/Talya1412/nvidia-rtx-ota-export/actions/workflows/ota-release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Automated, unattended exporter for the **newest NVIDIA RTX DLLs** — the DLSS Super Resolution /
Ray Reconstruction / Frame Generation runtime and the Streamline plugin set — tracked across
**every available feed**: the NGX OTA **staging** (pre-release) and **production** channels, the
official **Streamline SDK** GitHub releases, and the official **NVIDIA/DLSS** GitHub releases
(runtime demo with `nvngx_dlss.dll`). Each component (DLSS, Streamline) independently comes from
whichever feed is newest. **rhi-repo** mirrors (dlss/dlssd/dlssg/streamline/dlssnr) are indexed as
a hash-verified rescue path — never raced, never shipped unverified.

One command (or double-click `run-export.bat`) produces a PE-validated folder of drop-in DLLs:

```
nvngx_dlss.dll      DLSS Super Resolution   (newest available build, e.g. 310.9.1)
nvngx_dlssd.dll     DLSS Ray Reconstruction
nvngx_dlssg.dll     DLSS Frame Generation
sl.common.dll       Streamline 2.x runtime plugins
sl.dlss.dll / sl.dlss_d.dll / sl.dlss_g.dll / sl.deepdvc.dll / sl.nis.dll / sl.nvperf.dll / sl.pcl.dll / sl.reflex.dll
export-summary.txt  per-file version + signature status + SHA-256
export-sources.txt  which feed won each component (dlss=/sl=) + all feeds compared
```

> `Newest` also packages DLSS 5 Neural Rendering as a separate per-GPU 7z asset (`nvngx_dlssnr_310.8.0.7z`):
> the pinned universal build is accepted only when its exact DLL SHA-256 matches; its UNVERIFIED
> Authenticode status is documented in the release notes. Authenticode status for allowlisted
> DLSS/Streamline DLLs is reported, not used as a hard reject.

## Automated releases

`.github/workflows/ota-release.yml` runs **every 3 hours** (and on demand via *Run workflow* —
source picker: **Newest** — all feeds, the default; **Sdk**; **Staging**; **Production**).
It calls `New-OtaRelease.ps1`, which:

0. **cheap pre-gate**: reads the two OTA manifests plus three GitHub "latest" tags (no payload
   downloads) and compares against the `probe-state.json` asset attached to the newest release —
   when nothing changed anywhere, the run exits in ~5 seconds; only a real feed change runs the
   heavy export (first run of a change typically lands within 3 hours of NVIDIA publishing it),
1. exports the current **newest state**: per-component winner across OTA staging, OTA
   production, the latest Streamline SDK release and the NVIDIA/DLSS release — production is not
   always behind staging, and the SDK repo is sometimes ahead of both (the `sl_sdk_0` manifest
   section carries the real Streamline version, so only the winning channel's bundle is ever
   downloaded),
2. builds the release tag `v<dlss>-sl<streamline>` (e.g. `v310.9.1-sl2.14.1`),
3. **exits without publishing** unless the candidate is strictly newer than every existing release —
   so a release only appears when NVIDIA ships a new version, and a stale feed can never
   pull "Latest release" backwards,
4. otherwise packs the DLLs into a flat **7z** (same drop-in layout as a game folder), attaches
   `checksums.txt` + `probe-state.json`, and publishes release notes with a real changelog:
   version deltas, per-file added/changed/removed diff (by SHA-256 against the previous release's
   checksums), and the per-component source table (which feed each component came from) plus the
   lag of every feed,
5. runs the **fixture integration tests** first (`tests/run-tests.ps1 -Integration`): downloads the
   frozen release artifacts listed in `tests/fixtures/manifest.json`, verifies every archive
   SHA-256, and validates DLL count, FileVersions, and dependency consistency of the shipped sets.

Local run (uses your `gh` login):

```powershell
./New-OtaRelease.ps1
```

## Usage

```powershell
# default: newest available across OTA staging/production + Streamline SDK (per component)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Archive

# SDK-only (Streamline SDK GitHub release, no OTA download)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Sdk -Archive

# force one OTA channel: staging (pre-release) or production (what the driver serves normally)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Staging -Archive
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Production -Archive

# custom output dir
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -OutDir D:\rtx-dlls
```

Or double-click `run-export.bat`.

## How it works

1. **Manifest** — fetches NVIDIA's OTA version manifest:
   `https://ngx.download.nvidia.com/{channel}/org/nvidia/team/ngx/models/config/versions/2/files/nvngx_server_config.txt`
   with channel `dev-models` = **staging / pre-release**, `3e933c08-ea30-45ae-93d1-5114edf9c3b9` =
   **production** (same switch as NVIDIA's own Streamline OTA client: registry `NGXCore\CDNServerType`,
   `0 - production / 1 - staging`, see `sl.ota/ota.cpp` in the Streamline SDK).
   In **Newest** mode (the default) all feeds are compared and each component comes from the
   newest one (ties prefer the Streamline SDK repo). DLSS 5 Neural Rendering also comes from the
   user-pinned universal asset when its exact SHA-256 matches; Authenticode status is reported,
   not used as a hard reject for allowlisted DLSS/Streamline sources or mirror candidates.
2. **Resolve versions** — OTA: reads `app_E658700` / `app_E658703` generic app pins for sections
   `dlss`, `dlssd`, `dlssg`, `dlss_override` (the Streamline bundle); SDK: reads the DLL
   FileVersions inside the Streamline SDK zip (`bin/x64`, production flavor).
3. **Download + verify** — pulls `dlss_override/versions/<packed>/files/160_E658700.zip`
   per OTA channel and the `streamline-sdk-v*.zip` asset, then composes the export: the
   SL winner's full set as base, DLSS DLLs overwritten from the DLSS winner, and a raw `.bin`
   refresh whenever any OTA manifest pin is strictly newer than an exported DLL. OTA payloads
   are checked against NVIDIA's published `.sha256` sidecars.
   Packed version layout: `(major << 16) | (minor << 8) | patch` — e.g. 310.9.0 → 20318464.
4. **PE gate + signature report** — every exported file must be a valid PE/MZ image. Authenticode
   status is recorded (`Valid (NVIDIA)` or `UNVERIFIED (...)`), but `Valid` is not required for
   allowlisted DLSS/Streamline sources. OTA payloads still require the NVIDIA SHA-256 sidecar.
5. **Output + optional archive** — writes `export-summary.txt` / `export-sources.txt` and, with
   `-Archive`, a ready-to-share flat **7z** (same layout as the release asset).

Verified live 2026-09-13: Streamline SDK (GitHub) served DLSS 310.9.1 + Streamline 2.14.1 while
OTA staging served 310.9.0 / 2.14.0 and OTA production 310.7.128 / 2.12.128 — the export takes
310.9.1 / 2.14.1 and publishes `v310.9.1-sl2.14.1`.

## Notes

- Every exported DLL must be a valid PE/MZ image. Authenticode status is recorded as
  `Valid (NVIDIA)` or `UNVERIFIED (...)`, but it is not a hard reject for allowlisted
  DLSS/Streamline sources. OTA payloads still require NVIDIA's SHA-256 sidecar.
- **dlssnr ships newest-wins**: the user-pinned universal build (immutable SHA-256 `e67dee20…`,
  310.8.0) races the rhi-repo `dlssnr-*` mirror builds; the newest PE-valid candidate is packaged.
  A pinned-universal failure falls through to mirrors automatically. All archives ship as **7z**;
  the UNVERIFIED Authenticode status of these builds is documented in the release notes and
  `dlssnr-notes.txt`, not in the filename.
- **rhi-repo mirrors are never trusted on faith**: mirror builds are not raced against official
  feeds. They are used only as a rescue when an official OTA payload is unreachable — and even
  then only when the fetched DLL hashes to NVIDIA's published OTA `.sha256` sidecar digest.
  Community variants (renodx-*, DLSS-Enabler-*) and third-party update tools (dlss-swapper,
  DLSS-Updater, Streamline-Updater) are deliberately not used as sources.
- 7-Zip itself is supply-chain controlled: trusted local installs are used when present;
  otherwise the official standalone `7zr.exe` is downloaded from `7-zip.org` and verified against
  an exact SHA-256 pin (`Get-Pinned7zrSpec`) before any execution — a mismatched binary is refused.
- Requires Windows 10/11 with an NVIDIA GPU (PE validation; signatures are reported, not required) and internet access.
- Endpoint provenance and the payload-layout reverse engineering draw on
  [scubamount/dlss-version-toolkit](https://github.com/scubamount/dlss-version-toolkit) (Apache-2.0).

## Disclaimer

Downloaded DLLs are NVIDIA-copyrighted binaries fetched from NVIDIA's own CDN for personal use on
your own machine. This repository contains no binaries — only the automation script.
