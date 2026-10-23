# UI Spec — Device Telemetry Dashboard (Agent A output)

Source: `docs/specs/product-spec.md` (Leadership stage, approved)
Frontend target: Angular (standalone components, `ChangeDetectionStrategy.OnPush`,
typed reactive forms per `.claude/rules/code-style.md`).

## Assumptions (documented, non-blocking — see open_questions in handoff.json)

These fill gaps the product spec left open. They are design defaults, not
guesses about correctness-critical business logic, so they do not block
handoff. Agent B should confirm/adjust in the ADR if infra constraints differ.

1. **Sensor channels are backend-driven, not hardcoded.** The spec doesn't
   name specific sensor types for "dosing devices" (e.g. flow rate, pressure,
   dose volume, battery). `SensorChartComponent` is generic: it renders
   whatever channels the API returns (`name`, `unit`, `series`), so the UI
   does not need to know the exact sensor taxonomy up front.
2. **Realtime transport** for "live chart" / "alerts within 30s" is assumed to
   be a push channel (SignalR/WebSocket) fed by IoT Hub, with a polling
   fallback. UI components only depend on an Observable stream — the
   transport is Agent B's call, documented as an open question.
3. **Auth mechanism** ("only authenticated operators can view") is assumed to
   be OIDC/OAuth2 via an identity provider fronting the app; the UI only
   needs a route guard + session state, not a specific IdP. IdP choice is an
   open question for Agent B/security.
4. **Alert severity levels**: `info | warning | critical`, threshold values
   and breach definitions supplied by backend — not hardcoded in UI.
5. **Alerts panel scope**: spec is ambiguous whether alerts are global or
   per-device. Resolved by designing both: a persistent global alert
   indicator in the app shell, and a per-device alert panel filtered to the
   open device, backed by the same data source/component.

No "TBD" placeholders remain in this document.

---

## Screens

### 1. Login Screen (`LoginComponent`)
Route: `/login`
Purpose: gate access per acceptance criterion 4 (authenticated operators only).

**States**
- *default*: username/password (or SSO button) form, typed reactive form.
- *loading*: submit button shows spinner, form disabled.
- *error*: inline banner "Invalid credentials" or "Service unavailable";
  form re-enabled, field-level validation errors shown inline.
- *empty*: n/a (form always renders).

**Flow**: operator submits credentials → on success, redirect to `/devices`;
on failure, show error state and keep operator on screen.

---

### 2. Device List / Dashboard (`DeviceListComponent`, shell: `AppShellComponent`)
Route: `/devices` (default authenticated landing page)
Purpose: acceptance criterion 1 — list all devices with online/offline status.

**Layout**: `AppShellComponent` (top nav + `NotificationBellComponent` +
router outlet) wraps `DeviceListComponent`.

**States**
- *loading*: skeleton rows (6 placeholder rows) while initial fetch runs.
- *empty*: "No devices registered yet" illustration + copy, no CTA (out of
  scope: device provisioning is not in this slice).
- *error*: "Couldn't load devices" banner with a **Retry** button; list area
  collapses to the error state only (no stale data shown behind it).
- *default (populated)*: table/grid of `DeviceListItemComponent`, each with
  `DeviceStatusBadgeComponent` (online/offline), search/filter reactive form
  (typed) for device name and status filter.
- *partial-stale*: if the device list loaded but the live status feed
  disconnects, show a non-blocking banner "Status may be out of date" while
  keeping the last-known list visible.

**Flow**: operator lands here after login → filters/searches → clicks a
device row → navigates to Device Detail.

---

### 3. Device Detail (`DeviceDetailComponent`)
Route: `/devices/:deviceId`
Purpose: acceptance criteria 2 & 3 — live 24h sensor chart, alerts within 30s.

**Composition**: `DeviceHeaderComponent` + `SensorChartComponent` (one per
channel or tabbed) + `AlertPanelComponent` (scoped to `deviceId`).

**States**
- *loading*: header skeleton + chart skeleton + alert-panel skeleton, shown
  independently per sub-component (each has its own load lifecycle).
- *not-found / error*: device id doesn't resolve → "Device not found" full
  page state with a back-to-list link.
- *error (partial)*: header loads but chart or alerts fail independently —
  each region shows its own inline error + Retry, other regions unaffected.
- *empty (no readings)*: chart region shows "No sensor data in the last 24h"
  instead of an empty canvas.
- *empty (no alerts)*: alert panel shows "No active alerts for this device".
- *offline device*: header shows offline badge + banner "Device is offline —
  showing last known readings"; chart still renders historical data but does
  not expect new live points.
- *stale-live-feed*: if no new point/alert has arrived and the connection
  reports disconnected, chart/alert panel show a small "reconnecting…"
  indicator (ties to the 30s alert-latency requirement — operators must be
  able to tell when "no alerts" might just mean "no data").

**Flow**: operator opens a device → watches live chart update → sees new
alert appear in panel within 30s of ingest → can acknowledge alert inline →
can navigate back to list.

---

### 4. Global Alert Awareness (`NotificationBellComponent`, in `AppShellComponent`)
Not a route — persistent UI in the shell across all authenticated screens.

**States**
- *default*: bell icon with unread-critical-alert count badge (0 = no badge).
- *loading*: bell shown without count until first alert-summary fetch
  resolves (never blocks shell render).
- *error*: bell shows a muted/disconnected icon variant if the alert stream
  is down; no numeric badge shown (avoids showing stale/misleading counts).
- *populated*: clicking bell opens a dropdown list of the most recent
  cross-device alerts (`AlertPanelComponent` reused in "global" mode), each
  linking to its device detail screen.

**Flow**: alert breaches threshold anywhere → bell badge increments within
30s → operator clicks → sees alert list → clicks an alert → navigates to
that device's detail screen with the alert highlighted.

---

## User flows (end-to-end)

1. **Monitor fleet**: Login → Device List (see online/offline at a glance) →
   filter by status → open a device.
2. **Investigate device**: Device Detail → watch live chart → review alert
   panel → acknowledge alert.
3. **React to new alert**: anywhere in app → bell badge updates → open
   dropdown → jump to affected device's detail screen.
4. **Recover from data gaps**: any live-data region (chart, alert panel,
   status badges) distinguishes "no data" from "connection lost" from
   "fetch failed", so operators never mistake silence for "all clear".
