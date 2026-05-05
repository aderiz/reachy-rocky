---
title: Motors reference
type: reference
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
  - sources/agents-md.md
tags: [motors, hardware]
---

# Motors reference

All motors share a single Dynamixel TTL bus at baud **1,000,000**.

## Names (used by JS SDK and some Python APIs)

`body_rotation`, `stewart_1`–`stewart_6`, `right_antenna`, `left_antenna`.

## IDs

| ID | Group | Notes |
|---|---|---|
| 10 | Body / foot | Custom XC330-M288-PG (plastic gear). |
| 11–16 | Stewart platform 1–6 | XL330-M288-T. |
| 17 | Right antenna | XL330-M077-T. |
| 18 | Left antenna | XL330-M077-T. |

## Verifying motors are alive

On the Wireless:

```bash
ssh pollen@reachy-mini.local
source /venvs/mini_daemon/bin/activate
python -m reachy_mini.tools.scan_motors --wireless
```

Healthy output:

```
Trying baudrate: 1000000
Found motors at baudrate 1000000: [10, 11, 12, 13, 14, 15, 16, 17, 18]
```

If anything's missing → check cabling first; if still missing, it's a hardware fault.

## Common faults

| Symptom | Likely cause | First action |
|---|---|---|
| Blinking red LED | Overload / overheating | Power-cycle; check load. |
| "Input Voltage Error" | (False positive) | Reachy Mini intentionally runs higher voltage; ignore. |
| "Electrical Shock Error" | Damaged cable / short | Inspect power and 3-wire cables (40, 100, 200, 300 mm). |
| Antenna shaking near 0° | Inverted-pendulum equilibrium with backlash | Default firmware now offsets antennas a few degrees; or tune PID (P→180, D→10 on motors 10, 17, 18). |
| "No motor found on port" | Cable issue or wrong baud | Re-seat cables; rerun scanner. |
| Squeaking during head motion | Stewart spherical joints need re-grease | See HF troubleshooting page (open gap in [hf-docs](../sources/hf-docs.md)). |

## PID tuning

Hardware config: `src/reachy_mini/assets/config/hardware_config.yaml`. Per-motor variance is normal; a unit may need P/D adjustments. Common starting tweaks: reduce P to 180 on motors 10/17/18; if still shaky, raise D to 10 on the same set.

## See also

- [Hardware reference](hardware.md)
- [Safety limits](../concepts/safety-limits.md)
- [Run and debug](../workflows/run-and-debug.md)
