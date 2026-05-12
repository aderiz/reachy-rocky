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

## Antennas resonate at vertical — never command 0 rad

The XL330-M077-T antenna motors **mechanically vibrate when held at
exactly 0 rad (vertical)**. The shake is a hardware characteristic
of the motor + low-inertia antenna assembly, not a control-loop
problem — no amount of setpoint smoothing, easing, or quantisation
will silence it because the noise is downstream of the setpoint
(motor mechanics, not control).

Pollen's daemon documents this on `reachy_mini/reachy_mini.py:58`:

```python
INIT_ANTENNAS_JOINT_POSITIONS = [-0.1745, 0.1745]
# ~10° offset to reduce shaking at vertical
```

The factory wake-up pose sets the antennas at **±0.1745 rad (~10°)**
for this reason. The signs mirror — left negative, right positive,
both tilting outward from the bot's centreline.

**How to apply:** Any Mac-side or Mac-derived antenna setpoint
stream must rest at the same ±0.1745 rad offsets and treat twitches
as deltas around them. Commanding 0 rad — even briefly between
idle-twitch cycles — produces the vibration. Rocky's
`MacFaceTracker.tickAntennas` (`Sources/Perception/MacFaceTracker.swift`)
holds the antennas at `config.antennaLeftRestRad / antennaRightRestRad`
between twitches, and twitches are `rest + Δ` with `Δ ∈ [-amplitude,
+amplitude]`.

Two prior attempts (amplitude/rate reduction, eased ramp + 0.02 rad
output quantisation) left the vibration intact — both were
addressing the wrong layer.

## Reading supply voltage from motors

Every Dynamixel servo continuously samples its own supply rail.
Read it via the **`PRESENT_INPUT_VOLTAGE` register at address 144**
(2 bytes, signed, deci-volts). The daemon's
`reachy_mini/daemon/backend/robot/backend.py:626` (`voltage_ok`)
reads it internally; Rocky reads it through the daemon's raw-packet
WebSocket and surfaces the values via the on-bot relay's
`/battery` endpoint. See [power monitoring](power-monitoring.md).

## See also

- [Hardware reference](hardware.md)
- [Safety limits](../concepts/safety-limits.md)
- [Run and debug](../workflows/run-and-debug.md)
