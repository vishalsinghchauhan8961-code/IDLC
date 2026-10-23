# Component Contracts (Agent A output)

Angular standalone components, `ChangeDetectionStrategy.OnPush`. Reactive
forms are typed (`FormGroup<{...}>` / `FormControl<T>`). All timestamps are
ISO 8601 strings over the wire, converted to `Date` at the component
boundary. All list/detail data arrives via services returning `Observable<T>`
(Agent B defines the transport — REST fetch + push channel per
`ui-spec.md` assumption #2).

Every component below lists: selector, exact input/output data fields, and
which UI states (from `ui-spec.md`) it is responsible for rendering.

---

## `AppShellComponent`
Selector: `app-shell`
Not routed — wraps the router outlet for all authenticated routes.

**Inputs**: none (reads session state from an injected `AuthService`)
**Outputs**: none
**Consumes (via services, not @Input)**:
- `currentUser: { id: string; displayName: string }`
- `alertSummary: { unreadCriticalCount: number; connectionState: 'connected' | 'reconnecting' | 'disconnected' }`

**States handled**: passes through loading/error to `NotificationBellComponent`; itself has no loading state (renders immediately, children handle their own).

---

## `LoginComponent`
Selector: `app-login`
Route: `/login`

**Inputs**: none
**Outputs**:
- `loginSubmit: EventEmitter<{ username: string; password: string }>` — only
  emitted if `authMode === 'password'`; see open question on SSO in
  handoff.json.

**Form model** (typed reactive form):
```ts
interface LoginForm {
  username: FormControl<string>;
  password: FormControl<string>;
}
```

**Inputs (state flags, set by container/route resolver)**:
- `isSubmitting: boolean`
- `errorMessage: string | null`

**States handled**: default, loading (`isSubmitting`), error (`errorMessage`).

---

## `DeviceListComponent`
Selector: `app-device-list`
Route: `/devices`

**Inputs**:
- `devices: DeviceSummary[]`
- `status: 'loading' | 'loaded' | 'empty' | 'error' | 'partial-stale'`
- `errorMessage: string | null`

```ts
interface DeviceSummary {
  deviceId: string;
  name: string;
  status: 'online' | 'offline';
  lastSeenAt: string;        // ISO 8601
  activeAlertCount: number;
  highestActiveSeverity: 'info' | 'warning' | 'critical' | null;
}
```

**Outputs**:
- `deviceSelected: EventEmitter<string>` — emits `deviceId`
- `retry: EventEmitter<void>`
- `filterChange: EventEmitter<DeviceListFilter>`

**Filter form model** (typed reactive form):
```ts
interface DeviceListFilter {
  search: FormControl<string>;
  statusFilter: FormControl<'all' | 'online' | 'offline'>;
}
```

**States handled**: loading (skeleton rows), empty, error (+ retry),
default/populated, partial-stale (banner while list stays visible).

---

## `DeviceListItemComponent`
Selector: `app-device-list-item`
Presentational child of `DeviceListComponent` (one row per device).

**Inputs**:
- `device: DeviceSummary` (see shape above)

**Outputs**:
- `selected: EventEmitter<string>` — emits `deviceId`

**States handled**: none of its own (purely presentational; parent controls
loading/empty/error).

---

## `DeviceStatusBadgeComponent`
Selector: `app-device-status-badge`

**Inputs**:
- `status: 'online' | 'offline'`
- `lastSeenAt: string` (ISO 8601, used for offline tooltip "last seen 3m ago")

**Outputs**: none

**States handled**: visual-only mapping of `status` to token colors
(`color.status.deviceOnline` / `deviceOffline`); no loading/error state
(parent owns data fetch lifecycle).

---

## `DeviceDetailComponent`
Selector: `app-device-detail`
Route: `/devices/:deviceId`

**Inputs**:
- `deviceId: string` (from route param)
- `device: DeviceDetail | null`
- `status: 'loading' | 'loaded' | 'not-found' | 'error'`
- `errorMessage: string | null`

```ts
interface DeviceDetail {
  deviceId: string;
  name: string;
  status: 'online' | 'offline';
  lastSeenAt: string;
  location: string | null;
  channels: SensorChannelMeta[];   // drives SensorChartComponent tabs/panels
}

interface SensorChannelMeta {
  channelId: string;
  label: string;      // e.g. "Flow Rate" — backend-supplied, not hardcoded in UI
  unit: string;        // e.g. "L/min"
}
```

**Outputs**:
- `retry: EventEmitter<void>`
- `back: EventEmitter<void>`

**States handled**: loading (header/chart/alert skeletons independently),
not-found, error (+ retry), offline-device banner. Composes
`DeviceHeaderComponent`, `SensorChartComponent` (one per `channels[]`
entry, or tabbed), and `AlertPanelComponent` (scoped mode).

---

## `DeviceHeaderComponent`
Selector: `app-device-header`
Child of `DeviceDetailComponent`.

**Inputs**:
- `device: DeviceDetail | null`
- `status: 'loading' | 'loaded' | 'error'`

**Outputs**:
- `back: EventEmitter<void>`

**States handled**: loading (skeleton), error (inline), loaded (name,
status badge, last-seen, location).

---

## `SensorChartComponent`
Selector: `app-sensor-chart`
Child of `DeviceDetailComponent`, one instance per sensor channel.

**Inputs**:
- `channel: SensorChannelMeta` (see shape above)
- `series: SensorPoint[]` — last 24h of readings
- `windowHours: number` — default `24` (from `design-tokens.json`
  `chart.windowHours`)
- `liveStatus: 'connected' | 'reconnecting' | 'disconnected'`
- `status: 'loading' | 'loaded' | 'empty' | 'error'`
- `errorMessage: string | null`

```ts
interface SensorPoint {
  timestamp: string;  // ISO 8601
  value: number;
}
```

**Outputs**:
- `retry: EventEmitter<void>`

**States handled**: loading (chart skeleton), empty ("no readings in last
24h"), error (+ retry), default (live-updating line chart), stale indicator
when `liveStatus !== 'connected'` (per `chart.staleAfterSeconds` token —
30s, matching acceptance criterion 3's alert-latency requirement).

---

## `AlertPanelComponent`
Selector: `app-alert-panel`
Used in two modes: scoped (`DeviceDetailComponent`) and global
(`NotificationBellComponent` dropdown).

**Inputs**:
- `mode: 'device-scoped' | 'global'`
- `deviceId: string | null` — required when `mode === 'device-scoped'`
- `alerts: Alert[]`
- `status: 'loading' | 'loaded' | 'empty' | 'error'`
- `errorMessage: string | null`

```ts
interface Alert {
  alertId: string;
  deviceId: string;
  deviceName: string;         // needed for global mode display
  channelId: string;
  channelLabel: string;
  severity: 'info' | 'warning' | 'critical';
  message: string;             // backend-composed, e.g. "pH above threshold"
  breachedAt: string;          // ISO 8601 — must render within 30s of ingest
  acknowledgedAt: string | null;
  acknowledgedBy: string | null;
}
```

**Outputs**:
- `acknowledge: EventEmitter<string>` — emits `alertId`
- `retry: EventEmitter<void>`
- `alertSelected: EventEmitter<{ deviceId: string; alertId: string }>` —
  global mode only, navigates to device detail with alert highlighted

**States handled**: loading (skeleton rows), empty ("no active alerts" /
"no active alerts for this device"), error (+ retry), default (severity-
colored list, ack action per row).

---

## `NotificationBellComponent`
Selector: `app-notification-bell`
Lives in `AppShellComponent`, always mounted for authenticated routes.

**Inputs**:
- `unreadCriticalCount: number`
- `connectionState: 'connected' | 'reconnecting' | 'disconnected'`
- `recentAlerts: Alert[]` (see shape above) — populates the dropdown, reuses
  `AlertPanelComponent` in `mode="global"`

**Outputs**:
- `opened: EventEmitter<void>` — used to trigger a fetch/mark-seen
- `alertSelected: EventEmitter<{ deviceId: string; alertId: string }>`
  (bubbled from inner `AlertPanelComponent`)

**States handled**: default (badge count, hidden if 0), loading (no badge
until first fetch resolves), error/disconnected (muted bell icon variant,
no numeric badge).

---

## Cross-cutting notes for Agent B / Agent C

- All `status: 'loading' | 'loaded' | ...` inputs are container-driven; no
  component below the container level performs its own HTTP calls, so
  Agent C can implement data-fetch/streaming services independently of
  presentational component logic.
- `SensorChannelMeta[]` on `DeviceDetail` is the seam that lets Agent B
  define actual sensor taxonomy in the OpenAPI contract without a UI change.
- `Alert.breachedAt` → UI render must be verifiably ≤ 30s in QA e2e tests
  (Agent D); Agent B's push-transport choice must support this budget.
