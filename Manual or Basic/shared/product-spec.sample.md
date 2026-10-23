# Product Spec — Device Telemetry Dashboard (Leadership stage output)

## Goal
Operators monitor industrial dosing devices in near-real-time.

## Acceptance criteria
1. List all devices with online/offline status.
2. Device detail shows the last 24h of sensor readings as a live chart.
3. Alerts panel surfaces threshold breaches within 30s of ingest.
4. Only authenticated operators can view device data.
5. Each device authenticates with its own credential (no shared key).

## Non-goals
- Device firmware updates (out of scope for this slice).
