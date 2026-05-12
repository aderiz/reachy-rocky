---
title: Power monitoring — supply voltage via Dynamixel reg 144
type: reference
status: current
last_updated: 2026-05-12
sources:
  - OnBot/rocky_media_relay/rocky_media_relay/main.py
  - Sources/Rocky/BatteryService.swift
  - Sources/Rocky/UI/BatteryChip.swift
  - reachy_mini/daemon/backend/robot/backend.py (daemon source on the bot)
tags: [battery, power, dynamixel, hardware-workaround]
---

# Power monitoring

How Rocky reads supply voltage and presents power state, given that
the Reachy Mini Wireless **has no fuel-gauge IC** and the daemon
exposes no battery API.

## Why this is non-trivial

Per the [Reachy Mini hardware spec](hardware.md), the BMS is purely
**protective** — over-charge / over-discharge / over-current / short
/ thermal cutoff. There's no SOC measurement, no charging-status
output, no I²C-readable register. The on-bot kernel's
`/sys/class/power_supply/` is empty:

```
$ ls /sys/class/power_supply/
$ lsmod | grep -iE 'bq2|max1|fuel|charger'
(no modules)
```

We confirmed by physical experiment: with the bot running on
battery, peripheral scans show nothing battery-related on any
exposed bus. GPIO 23 *looks* like a charger-detect pin but is in
fact the shutdown push-button (the Pollen daemon's `gpio_shutdown`
service consumes it).

The daemon's REST API has no `/battery` or analogous endpoint:

```
$ curl http://reachy-mini.local:8000/openapi.json | grep -i batter
(empty)
```

## The workaround — Dynamixel `PRESENT_INPUT_VOLTAGE`

Every Dynamixel servo on the bot continuously samples its own supply
rail and exposes it via register **144**
(`PRESENT_INPUT_VOLTAGE`, 2 bytes, signed, deci-volts). The Pollen
daemon reads this internally for over-voltage protection — see
`reachy_mini/daemon/backend/robot/backend.py:626` (`voltage_ok`).
It just doesn't surface the value anywhere.

Rocky reads it directly through the daemon's existing **raw-packet
WebSocket** (`/api/move/ws/raw/write`), which forwards arbitrary
Dynamixel Protocol 2.0 frames to the motor bus and returns the
status response. We construct a READ packet for reg 144, send it
to each motor, parse the response, take the median.

### Empirical thresholds

Measured across the bot's 9 servos with the bot in known states:

| Source | Median across motors | Spread |
|---|---|---|
| DC plugged in | **7.30 V** | ±0.1 V |
| Battery, LiFePO4 nominal plateau | **6.40–6.50 V** | ±0.1 V |
| Battery, low (knee of curve) | 6.0–6.2 V | — |
| Battery, critical | <5.9 V | BMS cutoff imminent |

The 0.8 V gap between "on DC" and "on battery" is **unambiguous** —
a 6.9 V threshold separates them with no false positives.

### LiFePO4 voltage → SOC mapping

LiFePO4's discharge curve is famously flat — the cell sits at ~6.4 V
across roughly 80%-to-20% of usable charge then collapses near
empty. So voltage-derived SOC is **necessarily coarse**, but it's
enough for a green / amber / red indicator. Anchors used in
`OnBot/rocky_media_relay/rocky_media_relay/main.py:_estimate_lifepo4_percent`:

```
7.00 V → 100%   (rested or charger-disconnected freshly full)
6.70 V →  90%   (top of plateau)
6.50 V →  60%   (mid plateau, observed when discharging)
6.40 V →  35%   (bottom of plateau, BMS still happy)
6.20 V →  15%   (knee of curve)
6.00 V →   5%   (close to BMS cutoff)
5.80 V →   0%   (BMS will trip very shortly)
```

Piecewise-linear interpolation between anchors.

## API shape — `GET http://<bot>:8042/battery`

The on-bot relay exposes the result over HTTP. Schema:

```json
{
  "present": true,
  "percent": 78,
  "status": "Charging",
  "charging": true,
  "plugged_in": true,
  "voltage_v": 7.3,
  "current_a": null,
  "temperature_c": null,
  "source": "dynamixel:reg144",
  "motor_samples_v": [7.3, 7.3, 7.2, 7.3, 7.3, 7.3, 7.3, 7.3, 7.3],
  "power_source": "dc"
}
```

`current_a` and `temperature_c` are reserved — the BMS doesn't
expose them. `source` indicates how the values were derived
(`dynamixel:reg144` for the motor-voltage path, future revisions
may add a fuel-gauge path if Pollen ships one).

The relay falls back to a `/sys/class/power_supply/`-based reader
first; on a stock Wireless image that always returns
`present: false` so the Dynamixel path takes over.

Cached 2 s in the relay so adding the battery field to `/health`
doesn't hammer the motor bus.

## Mac side

`BatteryService` (`Sources/Rocky/BatteryService.swift`) polls
`/battery` every 30 s (60 s after consecutive failures), publishes
`Snapshot` events through an `AsyncStream`, and `AppServices`
mirrors them onto an `@Observable` surface for SwiftUI.

The `BatteryChip` (top-right overlay on the portrait, see
`Sources/Rocky/UI/BatteryChip.swift`) renders an iOS-style pill
glyph with a charge-tier fill and an inline percent readout.
Tint tier:

- DC plugged in → green + lightning-bolt overlay
- Battery ≥30% → green
- Battery 15–30% → amber
- Battery <15% → red

The Inspector → Status → Body row mirrors the chip with the full
diagnostic line (voltage, source, motor sample count).

## Failure modes + tooltips

| Snapshot state | Chip displays |
|---|---|
| Not polled yet | hidden |
| Relay unreachable (`reachable: false`) | hidden |
| Relay up, BMS not detected (`present: false`) | hidden |
| Normal | iOS pill with `78%` or `DC` |

The chip hides itself when there's no useful signal so the avatar
isn't permanently bracketed by a grey placeholder. The Inspector
row stays visible with a diagnostic message so the user can still
see *why* there's no reading.

## Why not poll motors directly from the Mac?

We could — `RobotLinkClient` has the raw-packet WS available too.
We route through the on-bot relay's `/battery` instead because:

1. The relay can cache + rate-limit. Each Mac fetch produces one
   small HTTP call instead of 9 motor reads.
2. Future fuel-gauge support (if Pollen ships one) can be added
   inside the relay without any Mac-side change.
3. The same endpoint serves `/health`, which Rocky polls anyway.
4. A daemon-side change (e.g. Pollen adds `/api/state/battery`)
   becomes a single relay-side swap, again no Mac change.

## See also

- [Hardware](hardware.md) — battery + BMS spec.
- [Motors](motors.md) — Dynamixel register map references.
- [On-bot media relay](../concepts/on-bot-media-relay.md) — where
  the `/battery` endpoint lives in the broader relay surface.
