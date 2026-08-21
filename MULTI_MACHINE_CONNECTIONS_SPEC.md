# Multi-Machine Connections Spec

Herdr's native apps (iOS + Mac) currently pair with exactly one harness. This feature lets
one app connect to **multiple machines** (multiple tailscale harness URLs) at once:

- Default view is **All Machines**: the sidebar lists every machine's sessions, grouped by
  machine, with **starred chats from all machines combined above everything** (as today).
- A **machine picker** (dropdown) scopes the app to one machine or all.
- A **Machines management UI** (add / edit / test / delete) replaces the single
  Server URL + token fields.
- **Zero backend changes.** The harness already exposes machine identity via
  `GET /api/v1/network` (`tailscale.dnsName`, `hostname`) and per-server stars.

Reference machines for manual testing:
- rocketbot (this Mac): `http://localhost:9092` in sim / `https://rocketbot.tail1db61d.ts.net:8463`
- work Mac: `https://ronniesitym4mbp.tail1db61d.ts.net:8444`

## Non-negotiable doctrine

- `State/HerdrAppModel.swift`, `Models/SidebarTree.swift`, `Infrastructure/HerdrAPIClient.swift`
  and all `Models/*` stay **byte-identical** between `herdr-harness-ios/` and
  `herdr-harness-mac/` (verify with `herdr-harness-mac/Scripts/check-ios-drift.sh`).
  Implement in iOS first; port verbatim; only the already-drifted view/driver files adapt.
- Mac sidebar rows keep the single-tone doctrine (`SidebarTone.status = mist`); machine
  status dots in the MAC sidebar use mist/dim, not per-status hues. iOS may use status colors.
- `HerdPulseContentState`'s Codable shape is pinned by `HerdPulseMenuBarPrivacyTests` — do
  not change it. HerdPulse consumes *merged* workspaces + the *aggregate* connection state.
- Preserve the generation-guard idiom (capture generation before await, compare after).

## 1. Machine model + persistence

New file `Models/HerdrMachine.swift`:

```swift
struct HerdrMachine: Codable, Identifiable, Equatable, Sendable {
    let id: String          // UUID string, generated at creation, never changes
    var name: String        // user label, e.g. "rocketbot"; never empty after save
    var urlString: String   // e.g. https://ronniesitym4mbp.tail1db61d.ts.net:8444
}
```

- Machine list persisted as JSON in UserDefaults key **`herdr.machines`** (`[HerdrMachine]`,
  array order = display order).
- Token per machine in Keychain (existing `KeychainStore`), account **`"api-token.\(machine.id)"`**.
  (Mac's UserDefaults fallback mirrors follow automatically via `fallbackKey(for:)`.)
- Composite ID helpers, new file `Models/MachineScopedID.swift`:

```swift
enum MachineScopedID {
    static let separator: Character = "|"   // cannot appear in server IDs ([A-Za-z0-9:._-]) or UUIDs
    static func compose(machineID: String, rawID: String) -> String
    static func split(_ id: String) -> (machineID: String, rawID: String)?  // split on FIRST "|"
}
```

- Machine scope, new file `Models/MachineScope.swift`:
  `enum MachineScope: Equatable { case all; case machine(String) }`, persisted in
  UserDefaults key **`herdr.machineScope`** ("all" or the machine id). Deleted/unknown
  machine id → fall back to `.all`.

### Migration (must be lossless, runs once in `HerdrAppModel.init`)

If `herdr.machines` is absent and legacy `herdr.serverURL` exists:
1. Create one machine: `id = UUID().uuidString`, `urlString` = legacy URL,
   `name` = first DNS label of the URL host (e.g. `ronniesitym4mbp`), or `"my mac"` for localhost.
2. Copy Keychain `"api-token"` → `"api-token.\(id)"` (leave the legacy account in place).
3. Prefix every entry of `herdr.sidebar.starredChats` and `herdr.sidebar.collapsedWorkspaces`
   with `"\(id)|"` (they currently hold bare server IDs).
4. Write `herdr.machines`. `herdr.completedSetup` semantics unchanged
   (`hasCompletedSetup` == completedSetup flag; machines empty + not demo → onboarding).

## 2. Machine-scoped entity IDs

Server IDs (`w1`, `w1:t1`, `w1:p1`) collide across machines. Fix at the model layer:

- `HerdrWorkspace`, `HerdrTab`, `HerdrPane`, `HerdrAlert` gain
  `var machineID: String = ""` (excluded from CodingKeys — never decoded).
- `Identifiable.id` becomes the **composite**: `MachineScopedID.compose(machineID:rawID:)`
  when `machineID` is non-empty, else the raw ID (pre-stamp safety).
  Raw fields (`workspaceID`, `tabID`, `paneID`) keep the server values.
- After each fetch/decode, stamp recursively: `workspace.stamped(machineID:)` sets
  `machineID` on the workspace and every nested tab/pane (agents/layouts reference panes by
  raw ID and are only ever used within one workspace — leave them raw). Alerts stamped too.
- Cross-references used for UI lookup (`pane.workspaceID` → workspace) resolve via
  composite helpers on the model: e.g. `workspace(id:)` / `pane(id:)` match on composite `id`.
- **Audit every `HerdrAPIClient` call site**: paths must receive the RAW id
  (`pane.paneID`, `workspace.workspaceID`), and the call must go to that entity's machine's
  client. Anywhere that currently passes `pane.id`/`workspace.id` into a client method is a bug
  after this change. `pane.displayTitle`'s "Pane N" derivation already uses raw `paneID` — keep.
- Selection (`selectedWorkspaceID`, `selectedPaneID`, `workspacePath`), starred
  (`starredChatIDs`), collapse sets, and all `ForEach`/accessibility ids now carry composite
  ids with **no further changes needed** — that is the point of this design.
- Deep links / notifications carry bare raw pane ids (`herdr://pane/w1:p1`, APNs `pane_id`):
  resolve via `panes.first(where: { $0.paneID == raw })` preferring, in order:
  (a) the only match, (b) a match on the machine that produced the most recent matching alert,
  (c) the first match in machine order. `pendingPaneID` keeps working on raw ids the same way.

## 3. Per-machine connection runtime (inside `HerdrAppModel`, byte-identical file)

Replace the single `client` / `activeServerConnection` with:

```swift
struct MachineRuntime {           // in-model, not persisted
    var client: HerdrAPIClient?
    var connection: ActiveServerConnection?
    var state: ConnectionState = .disconnected
    var lastUpdated: Date?
    var lastError: String?
    var firstFailureAt: Date?     // per-machine failure grace (same 10s rule as today)
}
@ObservationIgnored private var runtimes: [String: MachineRuntime]
var machines: [HerdrMachine]
```

- `connectionGeneration` (global int) stays and **bumps on any machine add/edit/delete** —
  AppRootView's `.task(id:)` (iOS) and `HerdrConnectionDriver.syncConnection` (Mac) keep
  working unchanged.
- `runConnection()` becomes a `withTaskGroup` fan-out: one `runMachineConnection(machine:)`
  loop per machine, each with its own backoff (2s → 15s cap), its own SSE `/api/v1/events`
  stream, and per-machine refresh. The task group is restarted wholesale when
  `connectionGeneration` bumps (config changes are rare; coarse restart is fine).
- **Merged stores with per-machine slices**: `workspaces`/`alerts` stay the app-wide arrays;
  a machine's refresh replaces only entries with its `machineID`
  (order: machine list order, then `workspace.number`). A machine going offline KEEPS its
  last-known slice visible (status dot shows offline); slices are removed only when the
  machine is deleted.
- **Stars reconcile per machine**: from machine M's `starredPaneIds`, replace only the
  members of `starredChatIDs` whose machineID == M. Missing key (old server) → leave M's
  subset untouched (existing local-only fallback, now per machine).
  `toggleStarredChat` routes `setPaneStar(rawID)` to the pane's machine client.
- **Pruning/repair is per machine**: `repairNavigation()` and star/collapse pruning only
  drop ids belonging to machines whose CURRENT refresh succeeded. Offline machines' state
  must never be purged.
- Aggregate `connectionState` (drives `ConnectionPill`, HerdPulse):
  demo → `.demo`; no machines → `.disconnected`; any machine `.live` → `.live`;
  else any `.connecting` → `.connecting`; else `.failed`.
- `canControl` becomes per-machine: `canControl(machineID:) == isDemoMode || runtime.state == .live`.
  Global `canControl` (existing callers) = `isDemoMode || any machine live`. Actions on an
  offline machine's pane show the existing "Reconnect before controlling Herdr" toast.
- Global "Connection issue" alert fires only when **all** machines are failed; individual
  machine errors surface in the Machines UI + status dots only.
- Push devices (`syncPushDevice`): register with EVERY machine that reaches `.live`
  (each harness pushes its own alerts). Live Activity (iOS `HerdPulseCoordinator`): register
  with the **primary machine only** (first in list); `activeServerConnection` (used by
  `HerdPulseSyncContext`) now means the primary machine's connection.
- Per-pane consumers (`PaneSessionView` terminal SSE + polling, `PiConversationStore`,
  git/skills/files/jira/attachments/voice) resolve their client from the entity:
  `model.client(forMachine: pane.machineID)`. Task ids keep using the global
  `connectionGeneration` as today.

## 4. Sidebar: machine grouping + combined starred

`Models/SidebarTree.swift` (byte-identical file):

- New row model:
  `struct MachineGroup: Identifiable { let machine: HerdrMachine; let state: ConnectionState;`
  `  let isExpanded: Bool; let entries: [ProjectEntry]; var id: String { "machine:\(machine.id)" } }`
- `SidebarTree.machineGroups(machines:states:workspaces:query:collapsedMachineIDs:collapsedWorkspaceIDs:starredIDs:)`
  → groups the existing `build(...)` output per machine (machine list order). Searching
  force-expands machine groups (same rule as workspaces). Empty machines still get a group
  (so an offline/new machine is visible) — entries empty → placeholder row.
- `starredGroups` unchanged in shape — `StarredGroup.id = "starred:\(workspace.id)"` is now
  automatically machine-unique (composite workspace id). Groups sort by machine order then
  workspace number.
- Machine collapse state: UserDefaults key **`herdr.sidebar.collapsedMachines`** ([machineID]).

Views (`HerdrSidebarView` — already drifted per platform, adapt both):

- **Scope == .all && machines.count > 1**: render machine header rows
  (`SidebarMachineRow` in `SidebarRowViews.swift`): collapse chevron, status dot
  (iOS: `ConnectionState.color`; Mac: mist/dim per single-tone doctrine), machine name
  lowercased in the existing mono chrome style, pane-count detail. Under each header, the
  machine's project tree exactly as today.
- **Single machine, or scope == .machine**: NO machine headers — pixel-parity with today's
  sidebar. Scope `.machine(id)` filters workspaces AND starred groups to that machine.
- **Starred section**: stays above everything, combined across the scope. When scope == .all
  and machines.count > 1, each starred group's header reads
  `"\(machine.name.lowercased()) · \(workspace label)"` (today: workspace label only).
- **Machine picker**: shown between the brand header and search when machines.count > 1.
  A compact `Menu` styled like the existing chrome: current scope title
  ("all machines" / machine name) + `chevron.up.chevron.down`. Items: "All Machines",
  each machine (with status indicator), divider, "Manage Machines…" (opens the machines UI).
  Selecting persists `herdr.machineScope`.
- "new workspace" / "new pi session" buttons: scope == .machine or 1 machine → direct
  (that machine). Scope == .all with >1 machine → the button becomes a Menu listing machines.

## 5. Machines management UI (the nice UX)

New files `Views/Settings/MachinesView.swift` + `Views/Settings/MachineEditorView.swift`
(both platforms; adapt chrome per platform like the rest of Settings):

- **MachinesView**: list of machines — status dot + name + host (secondary) + chevron;
  reorder via drag (iOS `.onMove`) / not required on Mac v1; "add machine" button in the
  existing key-deck button style. Rows navigate to the editor.
- **MachineEditorView** (add + edit):
  - Fields: Name (TextField, placeholder "auto from server"), Server URL, Pairing token
    (SecureField).
  - **Test connection** button: async — validates `ServerConfiguration`, calls
    `GET /api/v1/health` with the token; on 200 shows ✓ "Connected · \(hostname)" using
    `GET /api/v1/network` (`tailscale.dnsName` first label, else `hostname`), and auto-fills
    Name if empty. On failure shows the error inline (401 → "Token rejected", timeout →
    "Unreachable"). Add `fetchHealthProbe`/`fetchNetworkInfo` to `HerdrAPIClient` if missing.
  - Save → `model.addMachine(...)` / `model.updateMachine(...)` (persist + keychain +
    `connectionGeneration` bump). Editing a URL/token restarts connections; editing name doesn't
    need a reconnect but a global restart is acceptable.
  - Delete (edit mode only): confirmation dialog "Remove \(name)? Sessions stay on the
    machine; this only removes the connection." → `model.removeMachine(id:)` purges its
    workspaces/alerts slice, its starred/collapse entries, keychain token, scope fallback to
    `.all`.
- **SettingsView**: `connectionSection` (URL + token fields + "Save and reconnect") is
  REPLACED by a "machines" section: per-machine row (dot + name + host) and an
  "add machine" / "manage machines" affordance opening MachinesView. `statusSection` keeps the
  aggregate `ConnectionPill` and adds "N machines · M live" detail.
- **OnboardingView**: unchanged flow (URL + token + Connect) — Connect now creates machine #1
  (name auto-fetched from `/api/v1/network` after first successful connect, else URL label).
  Copy hint: "You can add more machines later in Settings."
- `model.connect()` (legacy single-server entry) is replaced by
  `addMachine`/`updateMachine`; keep a thin `connect()` used by Onboarding that upserts
  machine #1.

## 6. Demo mode

Demo showcases the feature: **two demo machines** stamped onto `DemoData`:
- `HerdrMachine(id: "demo1", name: "rocketbot")` → existing workspaces w1, w2, w3.
- `HerdrMachine(id: "demo2", name: "work mbp")` → two new small workspaces (reuse the
  builder; raw ids `w1`, `w2` **on purpose** — proves namespacing) with 2–3 panes, mixed
  agent statuses.
- `loadDemo()` sets `machines` to the demo pair (not persisted to `herdr.machines`),
  both runtimes' state `.demo`; demo starred defaults include one pane from each machine.
- Demo remains mutually exclusive with real connections (as today).

## 7. Tests (update + new; both platforms' suites must be green)

- `MachineScopedIDTests`: compose/split round-trip, raw ids containing `:` `.` `_` `-`,
  split on first separator only.
- `HerdrMachineMigrationTests`: legacy defaults+keychain → one machine, starred/collapse
  prefixing, idempotence (second init doesn't re-migrate), no-legacy fresh install.
- `SidebarTreeTests`: machine grouping (order, collapse, search force-expand), single-machine
  → no machine groups needed by views (groups still computed but views branch), starred
  combined across machines sorted machine-order-first, `"starred:"` + composite uniqueness.
- `HerdrAppModelStarredChatsTests`: per-machine reconcile — machine A's `starredPaneIds`
  must not touch machine B's subset; missing key leaves subset untouched; toggle routes to
  the right client (spy/fake).
- Aggregate `ConnectionState` derivation table test.
- Existing tests referencing bare ids (`"w1"`, `"w1:p1"`, `"starred:w1"`) updated to stamped
  composites.
- Mac: `DemoScreenshotRenderTests` re-render (baselines change — sidebar now shows machine
  groups in demo); `rendersSidebar` AND `rendersSidebarAtXXLargeTextScale` both seed any new
  state (known gotcha: the XXL test clobbers `02-sidebar.png`).
- UI tests: update any literal accessibility ids to composite form.

## 8. Explicitly out of scope (v1)

- Per-machine enable/disable toggle (delete covers it).
- Harness/backend changes of any kind.
- Cross-machine Live Activity registration (primary machine only).
- Bonjour auto-discovery of machines.
