# nvidia-rtx-ota-export

[![Latest Release](https://img.shields.io/github/v/release/Talya1412/nvidia-rtx-ota-export?color=76b900&label=latest%20OTA)](https://github.com/Talya1412/nvidia-rtx-ota-export/releases/latest)
[![ota-release](https://github.com/Talya1412/nvidia-rtx-ota-export/actions/workflows/ota-release.yml/badge.svg)](https://github.com/Talya1412/nvidia-rtx-ota-export/actions/workflows/ota-release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Automated, unattended exporter for the **newest NVIDIA RTX DLLs** — the DLSS Super Resolution /
Ray Reconstruction / Frame Generation runtime and the Streamline plugin set — tracked across
**every available NVIDIA feed**: the NGX OTA **staging** (pre-release) and **production**
channels, plus the official **Streamline SDK** GitHub releases. Each component (DLSS, Streamline)
independently comes from whichever feed is newest.

One command (or double-click `run-export.bat`) produces a verified folder of drop-in DLLs:

```
nvngx_dlss.dll      DLSS Super Resolution   (newest available build, e.g. 310.9.1)
nvngx_dlssd.dll     DLSS Ray Reconstruction
nvngx_dlssg.dll     DLSS Frame Generation
sl.common.dll       Streamline 2.x runtime plugins
sl.dlss.dll / sl.dlss_d.dll / sl.dlss_g.dll / sl.deepdvc.dll / sl.nis.dll / sl.nvperf.dll / sl.pcl.dll / sl.reflex.dll
export-summary.txt  per-file version + SHA-256
export-sources.txt  which feed won each component (dlss=/sl=) + all feeds compared
```

> The exporter automatically includes `nvngx_dlssnr.dll` (DLSS Neural Rendering) once any feed
> starts serving a `dlssnr` payload, and picks up extra SDK-only DLLs (`nvngx_deepdvc.dll`,
> `sl.directsr.dll`, `sl.interposer.dll`) whenever the Streamline SDK zip is the winning set.

## Automated releases

`.github/workflows/ota-release.yml` runs **weekly** (Monday 09:00 UTC) and on demand via
*Run workflow* (source picker: **Newest** — all feeds, the default; **Sdk**; **Staging**; **Production**).
It calls `New-OtaRelease.ps1`, which:

1. exports the current **newest state**: per-component winner across OTA staging, OTA
   production and the latest Streamline SDK release — production is not always behind staging,
   and the SDK repo is sometimes ahead of both,
2. builds the release tag `v<dlss>-sl<streamline>` (e.g. `v310.9.1-sl2.14.1`),
3. **exits without publishing** unless the candidate is strictly newer than every existing release —
   so a release only appears when NVIDIA ships a new version, and a stale feed can never
   pull "Latest release" backwards,
4. otherwise packs the DLLs into a flat **7z** (same drop-in layout as a game folder), attaches
   `checksums.txt`, and publishes release notes with a real changelog: version deltas, per-file
   added/changed/removed diff (by SHA-256 against the previous release's checksums), and the
   per-component source table (which feed each component came from) plus the lag of every feed.

Local run (uses your `gh` login):

```powershell
./New-OtaRelease.ps1
```

## Usage

```powershell
# default: newest available across OTA staging/production + Streamline SDK (per component)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Zip

# SDK-only (Streamline SDK GitHub release, no OTA download)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Sdk -Zip

# force one OTA channel: staging (pre-release) or production (what the driver serves normally)
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Staging -Zip
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Channel Production -Zip

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
   newest one (ties prefer the Streamline SDK repo).
2. **Resolve versions** — OTA: reads `app_E658700` / `app_E658703` generic app pins for sections
   `dlss`, `dlssd`, `dlssg`, `dlss_override` (the Streamline bundle); SDK: reads the DLL
   FileVersions inside the Streamline SDK zip (`bin/x64`, production flavor).
3. **Download + verify** — pulls `dlss_override/versions/<packed>/files/160_E658700.zip`
   per OTA channel and the `streamline-sdk-v*.zip` asset, then composes the export: the
   SL winner's full set as base, DLSS DLLs overwritten from the DLSS winner, and a raw `.bin`
   refresh whenever any OTA manifest pin is strictly newer than an exported DLL. OTA payloads
   are checked against NVIDIA's published `.sha256` sidecars.
   Packed version layout: `(major << 16) | (minor << 8) | patch` — e.g. 310.9.0 → 20318464.
4. **Authenticode gate** — every exported file must be a valid PE signed (Valid) by
   *NVIDIA Corporation*; anything else aborts the run.
5. **Output + optional ZIP** — writes `export-summary.txt` / `export-sources.txt` and, with
   `-Zip`, a ready-to-share archive.

Verified live 2026-09-13: Streamline SDK (GitHub) served DLSS 310.9.1 + Streamline 2.14.1 while
OTA staging served 310.9.0 / 2.14.0 and OTA production 310.7.128 / 2.12.128 — the export takes
310.9.1 / 2.14.1 and publishes `v310.9.1-sl2.14.1`.

## Notes

- The staging channel is a **pre-release** feed: real, NVIDIA-signed builds, but the driver will not
  serve them to a game unless an override points at them.
- The DLSS SDK (headers/samples) is intentionally **not** downloaded here — only runtime DLLs.
  Official SDKs: <https://github.com/NVIDIA/DLSS>, <https://github.com/NVIDIA-RTX/Streamline>.
- Requires Windows 10/11 with an NVIDIA GPU (Authenticode verification) and internet access.
- Endpoint provenance and the payload-layout reverse engineering draw on
  [scubamount/dlss-version-toolkit](https://github.com/scubamount/dlss-version-toolkit) (Apache-2.0).

## Disclaimer

Downloaded DLLs are NVIDIA-copyrighted binaries fetched from NVIDIA's own CDN for personal use on
your own machine. This repository contains no binaries — only the automation script.
