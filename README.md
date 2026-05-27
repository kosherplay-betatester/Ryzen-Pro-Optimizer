# Ryzen Pro Optimizer

A friendly, local web-based UI for tuning AMD Ryzen Curve Optimizer values — wraps [CoreCycler](https://github.com/sp00n/corecycler) under the hood.

**Status:** In development. See `docs/superpowers/specs/` for the design spec and `docs/superpowers/plans/` for the implementation plan.

## What it does

- Detect existing Curve Optimizer values from your BIOS / current session
- Set Curve Optimizer offsets from Windows (no BIOS reboot) — all cores, per-CCD, or per-core
- Run stability tests via CoreCycler (Prime95 SSE / AVX2 / AVX512)
- Parse the logs into a friendly pass/fail report with Smart Suggestions
- Live telemetry: temps, power, voltage, per-core clocks — updating in real time
- WHEA Bodyguard — background watcher that alerts on hardware errors
- Save/load named profiles for quick re-apply after reboot
- Panic Reset (Esc key or red button) — instant return to zero offsets if the system goes unstable

## Supported CPUs

- AMD Ryzen 5000 series (Zen 3) and newer — Curve Optimizer is a Zen 3+ feature
- Single- and dual-CCD chips (auto-detected)
- 7950X3D / 7900X3D V-Cache CCDs are recognized and labeled

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (ships with Windows)
- [CoreCycler](https://github.com/sp00n/corecycler) installed in the parent folder
- Administrator rights (required to write Curve Optimizer values)

## Install

This tool sits inside your existing CoreCycler folder:

```
CoreCycler-master/
├── Run CoreCycler.bat
├── tools/...
└── Ryzen-Pro-Optimizer/    ← clone here
```

```powershell
cd C:\path\to\CoreCycler-master
git clone https://github.com/kosherplay-betatester/Ryzen-Pro-Optimizer.git
```

Then double-click `Ryzen-Pro-Optimizer\Launch.bat` (once it exists — see implementation plan).

## License

TBD by author.

## Safety

This tool writes to your CPU's SMU registers via `ryzen-smu-cli`. Values are temporary — they reset on every reboot. To make settings permanent, write them into your BIOS. Always have a recovery plan; pressing Esc in this app instantly resets all cores to zero offset.
