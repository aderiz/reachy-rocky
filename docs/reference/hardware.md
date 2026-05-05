---
title: Hardware reference (Wireless)
type: reference
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # platforms/reachy_mini/hardware
tags: [hardware, wireless]
---

# Hardware reference — Reachy Mini Wireless

## Physical

- Dimensions: **30 × 20 × 15.5 cm** (extended).
- Mass: **1.475 kg**.
- Materials: ABS, PC, aluminium, steel.
- Power input: **6.8–7.6 V** (battery-fed; USB-C is data-only and does not charge).

## Degrees of freedom

| Group | DOF | Detail |
|---|---|---|
| Head | 6 | 3 rotations + 3 translations via Stewart platform (6 motors). |
| Body | 1 | Yaw rotation. |
| Antennas | 2 | One rotation each. |

Total: 9 motorized joints.

## Motors (Dynamixel TTL bus, baud 1,000,000)

| Group | Count | Model |
|---|---|---|
| Body / foot | 1 | Custom XC330-M288-PG (XC330-M288-T with plastic gear). |
| Antennas | 2 | XL330-M077-T. |
| Stewart platform | 6 | XL330-M288-T. |

IDs: `10` (body), `11`–`16` (Stewart), `17` (right antenna), `18` (left antenna). Verify with `python -m reachy_mini.tools.scan_motors --wireless`. See [motors reference](motors.md).

## Camera

- Raspberry Pi Camera Module v3 (wide).
- Sensor: **Sony IMX708**, 12 MP.
- FOV: ~120°.
- Autofocus.
- Connection: CSI.

## Microphone array

- Seeed Studio reSpeaker XMOS XVF3800.
- 4 × PDM MEMS digital mics.
- Up to 16 kHz sample rate. −26 dB FS sensitivity. 64 dBA SNR.
- Provides Direction-of-Arrival via `mini.media.get_DoA()`.

## Speaker

- 5 W @ 4 Ω.

## IMU (Wireless-only)

- Accelerometer (m/s²), gyroscope (rad/s), quaternion (w, x, y, z), temperature (°C).

## Compute

- Raspberry Pi Compute Module 4 — **CM4104016** (4 GB RAM, 16 GB eMMC, WiFi).
- WiFi: dual-band 2.4 / 5 GHz, 2.79 dBi patch antenna.

## Power

- LiFePO4 battery, 2000 mAh, 6.4 V, 12.8 Wh.
- BMS with overcharge / over-discharge / over-current / short / temperature protections.
- LED indicator: green → orange → red as battery drops.
- USB-C is **data only**, does not charge.

## Ports / interfaces

- USB-C (data, host side — plug a USB key in if needed).
- Power input.
- Camera CSI (internal).
- Mic array connection (internal FPC cable; 12-pin, 0.5 mm pitch, Type A, 15 mm).

## See also

- [Motors reference](motors.md)
- [Media architecture](../concepts/media-architecture.md)
- [Architecture](../concepts/architecture.md)
