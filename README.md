# nvidia-rtx-ota-export

Automated, unattended exporter for the **newest NVIDIA RTX DLLs** shipped over NVIDIA's NGX OTA
channel — the DLSS Super Resolution / Ray Reconstruction / Frame Generation runtime and the
Streamline plugin set — including the **pre-release staging channel** that runs ahead of every
public SDK release.

One command (or double-click `run-export.bat`) produces a verified folder of drop-in DLLs:

```
nvngx_dlss.dll      DLSS Super Resolution   (staging build, e.g. 310.9.0)
nvngx_dlssd.dll     DLSS Ray Reconstruction
nvngx_dlssg.dll     DLSS Frame Generation
sl.common.dll       Streamline 2.x runtime plugins (9 files)
sl.dlss.dll / sl.dlss_d.dll / sl.dlss_g.dll / sl.deepdvc.dll / sl.nis.dll / sl.nvperf.dll / sl.pcl.dll / sl.reflex.dll
export-summary.txt  per-file version + SHA-256
```

## Automated releases

`.github/workflows/ota-release.yml` runs every 6 hours (and on demand via *Run workflow*).
It calls `New-OtaRelease.ps1`, which:

1. exports the current staging OTA state (the pipeline above),
2. builds the release tag `v<dlss>-sl<streamline>` (e.g. `v310.9.0-sl2.14.0`),
3. **exits without publishing** if a release with that tag already exists — so a release only
   appears when NVIDIA ships a new OTA version,
4. otherwise packs the DLLs into a flat **7z** (same drop-in layout as a game folder), attaches
   `checksums.txt`, and publishes release notes with a real changelog: version deltas, per-file
   added/changed/removed diff (by SHA-256 against the previous release's checksums), and the
   public-SDK lag table.

Local run (uses your `gh` login):

```powershell
./New-OtaRelease.ps1
```

## Usage

```powershell
# default: staging (pre-release) channel, output to Downloads, plus a ZIP
powershell -NoProfile -ExecutionPolicy Bypass -File Export-RtxOtaPreRelease.ps1 -Zip

# production channel (what the driver serves a normal machine)
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
2. **Resolve versions** — reads `app_E658700` / `app_E658703` generic app pins for sections
   `dlss`, `dlssd`, `dlssg`, `dlss_override` (the Streamline bundle).
3. **GitHub cross-check** — compares against the latest public `NVIDIA/DLSS` and
   `NVIDIA-RTX/Streamline` releases to label how far ahead the OTA channel is
   (e.g. 2026-09-04: OTA staging 310.9.0 / 2.14.0 vs GitHub 310.7.0 / 2.12.0).
4. **Download + verify** — pulls `dlss_override/versions/<packed>/files/160_E658700.zip`
   (all 12 DLLs), checks SHA-256 against NVIDIA's published `.sha256` sidecar, and refreshes the
   three DLSS DLLs from their raw `.bin` payloads when the manifest version is newer than the bundle.
   Packed version layout: `(major << 16) | (minor << 8) | patch` — e.g. 310.9.0 → 20318464.
5. **Authenticode gate** — every exported file must be a valid PE signed (Valid) by
   *NVIDIA Corporation*; anything else aborts the run.
6. **Output + optional ZIP** — writes `export-summary.txt` and, with `-Zip`, a ready-to-share archive.

Verified live 2026-09-04 against staging: DLSS 310.9.0 + Streamline 2.14.0, while production served
310.7.128 / 2.12.128 and GitHub still had 310.7.0 / 2.12.0.

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
