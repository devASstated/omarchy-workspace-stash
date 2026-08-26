**Workspace Stash** 

## **Feature & Implementation Specification** 

Target: Omarchy Quattro / Hyprland / Quickshell 

Status: V1, V2, and V3 scope locked and implemented 

Scope rule: preserve the agreed user-facing behavior first; prefer the smallest event-driven architecture that implements it correctly. Implementation details may evolve, but V1/V2/V3 semantics in this document are the project contract. 

# **1. Purpose** 

Workspace Stash provides a simple workspace-level minimize/restore workflow for Omarchy. It is intentionally not a Windows-style per-window minimize system. The plugin maintains one global minimized set: a downward gesture hides every eligible window on the current workspace and adds it to that set, while the upward gesture restores the entire accumulated set onto the workspace where restore is triggered. A keyboard toggle provides the same core workflow for keyboard-driven use. 

The design favors predictable behavior, low idle overhead, minimal state, and clean integration with Omarchy Quattro rather than patching the stock bar or introducing a standalone daemon. 

# **2. User-facing behavior** 

### **Default gestures** 

- Three-finger swipe down: stash all eligible windows from the currently focused normal workspace. 

- Three-finger swipe up: restore the current stash onto the currently focused normal workspace. 

- Additional swipe-down gestures continue to work. Windows from the newly focused workspace are added to the existing minimized set. 

- If the stash is empty, swipe-up is a no-op. 

The published default is three fingers because it matches common desktop minimize/restore expectations. The gesture definition must be easy to change to four fingers for users who reserve three-finger gestures for other actions. 

### **Keyboard shortcut** 

SUPER+M is the published keyboard toggle for the same global stash. 

- If the minimized set is empty, SUPER+M stashes all eligible windows from the current workspace. 

- If the minimized set is non-empty, SUPER+M restores the entire set onto the currently focused normal workspace. 

- The shortcut is a toggle, unlike the directional gestures. Users who want to append another workspace while a stash already exists should use the downward gesture. 

The plugin must not overwrite user bindings automatically. Ship the binding as the documented default and keep it easy to rebind. 

### **Bar indicator** 

The plugin adds a small bar widget in the left section by default. It is always visible, dimmed while the stash is empty and at full opacity once it holds anything — it is the plugin's only discoverable entry point on a fresh install, since installing it never adds keybindings automatically. Left-click is state-driven the same way SUPER+M is: it stashes the current workspace when empty, restores the full stash when not. 

- count: show only the number of stashed windows, e.g. “3”. 

Workspace Stash - Feature & Implementation Specification 

- names: show application names, truncated when necessary. 

- icons: show application icons resolved from the user’s installed desktop entries / icon theme. 

Display mode is configurable per widget instance. V1 should include sensible limits for names/icons so the widget cannot consume an excessive amount of bar space. 

# **3. Product rules** 

- One global minimized set. Repeated stash gestures append windows to that set rather than creating separate user-visible slots or queues. 

- The minimized set is restored as a whole. V1 does not provide independent per-window restore semantics. 

- Restoring always targets the workspace that is active when the restore gesture is triggered. 

- Keyboard and gesture inputs must converge on the same service operations; input bindings must not contain a second implementation of stash/restore behavior. 

- SUPER+M is state-driven: empty stash means stash current workspace; non-empty stash means restore all to the current workspace. 

- V1 does not promise exact tiling-layout restoration. 

- V1 still captures geometry needed for future layout reconstruction. 

- No polling loops. 

- No Rust daemon or separate long-running process in V1. 

- Do not modify Omarchy-owned Bar.qml. 

- Do not silently rewrite user Hyprland configuration. Ship a documented bindings snippet / installer-safe setup path instead. 

# **4. Plugin packaging** 

The project should be a normal third-party Omarchy Quattro plugin repository with a root manifest.json. The plugin should use the supported service + bar-widget model so the service owns stash state and the bar widget only renders it. 

```
omarchy-workspace-stash/
├── manifest.json
```

- `├── README.md` 

- `├── LICENSE` 

- `├── Service.qml` 

- `├── BarWidget.qml` 

- `└── examples/ └── bindings.lua` 

#### Recommended plugin kinds: 

```
"kinds": ["service", "bar-widget"]
```

The repository should remain installable through the standard Omarchy plugin command and pass the built-in validator before release. 

```
omarchy plugin validate .
```

# **5. V1 implementation guidelines** 

### **5.1 State ownership** 

Service.qml is the single owner of stash state. BarWidget.qml must not maintain a second copy of the window list. 

Workspace Stash - Feature & Implementation Specification 

The service should expose the minimal behavioral surface needed by all inputs: stash(), restore(), and toggle(). toggle() must delegate to stash()/restore() based only on whether the global minimized set is empty. Keep input handling separate from core state transitions. 

The state model can remain small: 

```
minimized = {
    nextBatchId,
    windows: [
```

```
        { address, batchId, sourceWorkspace, x, y, width, height, floating, appId, title
}
    ]
}
```

Only values that are useful for UI, safe restoration, or the V2 geometry work should be retained. Do not introduce persistence in V1 unless testing proves shell restarts make the feature unusable. 

### **5.2 Stash operation** 

1. Resolve the currently focused normal workspace. 

2. Collect eligible top-level windows belonging to that workspace. 

3. Allocate a batch identifier for this swipe-down operation, then snapshot each window before moving it: address, source workspace, batch identifier, position, size, floating state, application/class identifier, and title if available. 

4. Move those windows to a private special workspace reserved by the plugin, e.g. special:workspacestash. 

5. Append the newly stashed clients to the existing minimized model and publish the updated count/model so the bar updates reactively. 

Moving should target exact Hyprland window addresses. Application names/classes are display metadata, not identity. 

### **5.3 Restore operation** 

6. Reject the operation if no stash exists. 

7. Resolve the currently focused normal workspace at the time of restore. 

8. Move every still-valid stashed window to that workspace. 

9. Allow Hyprland to tile the windows normally in V1. 

10. Clear stash state only after the restore operation has been issued for the group. 

11. Update/hide the bar indicator reactively. 

If a stashed client was closed while hidden, restoration should skip it cleanly. A stale address must never block the remaining group. 

### **5.4 Special workspace** 

Use a plugin-specific special workspace name such as: 

```
special:workspace-stash
```

The special workspace is an implementation detail, not the user-facing state model. The logical state is simply an empty or non-empty global minimized set. Batch/source metadata exists only to support bookkeeping and future layout reconstruction; it must not turn into user-visible stash slots. 

### **5.5 Input integration** 

Gesture and keyboard bindings should remain thin adapters. The downward gesture invokes stash(), the upward gesture invokes restore(), and SUPER+M invokes toggle(). No binding should inspect or mutate the minimized-window model directly. 

Published default: 

Workspace Stash - Feature & Implementation Specification 

```
3-finger down -> stash
3-finger up   -> restore
SUPER+M       -> toggle
```

Documentation must show how to change both gesture bindings to four fingers and how to rebind SUPER+M if it conflicts with the user’s setup. Finger count and key choice are user preferences; the core stash/restore behavior is not. 

### **5.6 Bar widget settings** 

- V1 should expose a compact settings surface through the bar-widget manifest/schema. Proposed settings: 

```
displayMode: "count" | "names" | "icons"
maxNames: integer
maxIcons: integer
```

Recommended default: count. It is the most stable option across icon themes, long application names, and narrow displays. 

For names mode, use the application/class name where possible rather than full window titles. For icons mode, resolve from installed desktop entries/icon theme; do not bundle a private icon set for common applications. 

V3 adds two more independent settings governing the overflow indicator shown when names/icons are truncated (see §8.2): `overflowStyle` (`badge` → `+N`, `ellipsis` → `..N`) and `overflowCountMode` (`leftover` → how many are hidden, `total` → the full stashed count). Both settings always combine into a single indicator that shows a number; neither setting is ever shown bare. Both are irrelevant, and hidden from the settings menu, while `displayMode` is `count`, since count mode never truncates. V3 also adds a "restore defaults" action resetting every bar-widget setting to its manifest default in one step. 

### **5.7 Performance rules** 

- React to Hyprland/Quickshell state changes; do not poll hyprctl on an interval. 

- Keep the bar component presentation-only. 

- Avoid spawning processes for routine rendering/update work. 

- Use exact client addresses for window operations. 

- Keep the in-memory model bounded by the number of currently minimized windows; do not retain historical entries after restore or client closure. 

- Prefer Omarchy shell IPC for calls into the already-running plugin instead of implementing a parallel IPC stack. 

- Keep the architecture lightweight: one authoritative service state, reactive shell integration, and thin input/UI adapters. Do not add a daemon, persistence layer, polling loop, or extra IPC mechanism unless a required feature cannot be implemented correctly without it. 

### **5.8 V1 non-goals** 

- Exact restoration of the original Dwindle split tree. 

- Per-window restore from the bar. 

- User-visible stash slots, workspace-specific restore queues, or FIFO/LIFO behavior. 

- Persistent stash history across reboots. 

- Cross-session recovery guarantees. 

- Replacing or patching the Omarchy bar. 

# **6. V1 acceptance criteria** 

- On an occupied workspace, the default down gesture stashes all eligible windows and leaves the workspace usable/empty. 

- Repeated down gestures from additional workspaces append their eligible windows to the same minimized set without disturbing windows already stashed. 

- The up gesture restores the entire surviving stash onto the workspace where the gesture is triggered. 

- Closed/stale clients do not break restore. 

- Bar widget is always visible, dimmed while the stash is empty; left-click stashes when empty and restores when not, the same state-driven behavior as SUPER+M. 

- count, names, and icons modes work without changing the stash logic. 

- Default three-finger bindings are documented; four-finger customization is documented. 

Workspace Stash - Feature & Implementation Specification 

- SUPER+M is documented as the default keyboard toggle and can be rebound without changing core logic. 

- With an empty stash, SUPER+M stashes the current workspace; with a non-empty stash, SUPER+M restores the full stash onto the current workspace. 

- No background polling loop is introduced. 

- Plugin passes omarchy plugin validate. 

- README documents install, enable, gesture setup, settings, limitations, and uninstall. 

### **V3 additions to acceptance criteria** 

- `moveTo <workspaceId>` moves every eligible window on the current workspace to the target, leaves the invoking user's focus untouched, and never reads or writes the stash. 

- Moving two or more windows onto an occupied target does not collapse the target's existing window(s). 

- Neither restore nor bulk workspace-move leaves the mouse cursor anywhere other than where the user left it. 

- `overflowStyle` and `overflowCountMode` combine independently; every combination shows a number, never a bare prefix; the Overflow section is hidden whenever `displayMode` is `count`. 

- Restore-defaults resets every bar-widget setting to its manifest default in one confirmed action. 

- The keybindings panel's copy affordance and config-file-open affordance work without the plugin ever writing to the user's Hyprland configuration itself. 

# **7. V2: layout-preserving restore** 

V2 keeps the same user-facing stash/restore model. The change is confined to how restore uses captured geometry when rebuilding tiled windows. Repeated V1 stash operations may have contributed windows from multiple source workspaces, so V2 tracks geometry per stash batch rather than pretending the accumulated set has one original global layout. 

### **7.1 Objective** 

When possible, restore windows from each stash batch with the same logical tiling structure they had immediately before that batch was minimized. If the minimized set contains several batches from different source workspaces, preserve each batch internally where practical and merge the batches into the destination workspace on a best-effort basis. There is no single original combined layout to reproduce in that case. 

### **7.2 Geometry already captured by V1** 

V1 deliberately records each window rectangle before moving it: x, y, width, and height, plus floating state, source workspace, and stash batch identifier. V2 should group windows by batch and treat each batch’s geometry as the input for layout inference rather than relying on window area or size sorting alone. 

### **7.3 Why size sorting is insufficient** 

Two different tiling trees can produce windows with the same dimensions. Window geometry must therefore be considered spatially: edges, containment, adjacency, split orientation, and relative proportions. Sorting by area alone is not a reliable reconstruction algorithm. 

### **7.4 Proposed reconstruction path** 

12. Group minimized windows by stash batch/source workspace. 

13. Normalize each batch’s captured rectangles to that source workspace usable area. 

14. Separate floating windows from tiled windows. 

15. Infer a binary split tree from tiled rectangles by finding full-span horizontal or vertical partition boundaries. 

16. Recursively split the remaining rectangle set until leaf nodes map to individual windows. 

17. Derive insertion order, split direction, and approximate split ratios from that tree. 

18. Restore tiled windows using controlled Hyprland Dwindle operations such as preselection/split direction and ratio adjustment where practical. 

19. Restore floating windows separately, using their captured geometry relative to the destination workspace where feasible. 

20. Fall back to normal Hyprland tiling if the captured geometry is ambiguous or reconstruction fails validation. 

Workspace Stash - Feature & Implementation Specification 

### **7.5 V2 safety rule** 

Layout reconstruction must be best-effort, never destructive. If the inferred tree is invalid, incomplete, or incompatible with the active layout, the plugin should restore all windows normally rather than refusing to restore the stash. Concretely: for a batch reconstruction genuinely can't resolve, the plugin must not force captured sizes onto whatever fallback placement it picks, since that reliably collapses them; those windows fall back to Hyprland's own tiling instead. This rule applies equally to bulk workspace-move (§8.1), which reuses the same ordering and geometry logic.

(Historical note: §7.3-7.4 describe the originally-proposed static-geometry reconstruction path. What actually shipped — destructive decomposition during stash, not a single-snapshot parse — resolves genuine multi-branch layouts, real Hyprland groups, and pseudo-tiled windows that the originally-proposed path structurally could not. This safety rule's *fallback* behavior is unchanged either way. See `docs/D-RECONSTRUCTION.md` for the mechanism that actually ships.) 

### **7.6 V2 compatibility** 

Do not redesign the public API for V2. The directional gestures, SUPER+M toggle semantics, global minimized-set behavior, bar modes, and plugin packaging should remain compatible with V1. Layout preservation is an internal restore enhancement. 

# **8. V3: bulk workspace-move, advanced settings, and discoverability** 

V3 adds one new stateless operation and a richer bar-widget settings surface. It does not change the V1/V2 stash/restore contract; everything here is either orthogonal to the stash or an additive settings-menu feature. 

### **8.1 Bulk workspace-move** 

A separate, stateless operation: move every eligible window on the currently focused workspace to a target workspace, without following the view there and without touching the stash in any way — it never reads or writes the minimized set, `root.meta`, or the stash's special workspace. 

- Published default binding: `SUPER + CTRL + SHIFT + 1` through `9`, plus `0` for workspace 10, mirroring Hyprland/Omarchy's own upstream convention of key `0` mapping to workspace 10. 
- Exposed as one parameterized IPC method (`moveTo <workspaceId>`), not nine separate ones. 
- Best-effort merge on an occupied target: existing windows on the destination are left undisturbed; Hyprland's own tiling absorbs the arriving windows the same way restore does today. Moving two or more windows onto an already-occupied destination must not collapse the destination's existing window(s) to a sliver — captured tiled geometry is not reapplied when the destination already holds windows, since the captured size assumes the window's original, now-invalid, tree position. 
- Reuses V2's layout-preserving ordering logic (batch-then-position ordering, split-structure/geometry dispatch) against the target workspace as the destination, with the same best-effort/non-destructive guarantee as restore. 
- The invoking user's own focus never moves to the target workspace, and the moved windows must not warp the mouse cursor away from wherever it currently is — Hyprland's default cursor-follows-focus behavior during the move must be explicitly compensated for. 
- No bar-widget changes; this is a stateless, one-shot action with nothing to persist or display. 

### **8.2 Advanced overflow settings** 

Two settings govern the overflow indicator shown once the `names`/`icons` display mode truncates the shown set (see §5.6): `overflowStyle` chooses the prefix (`badge` → `+N`, `ellipsis` → `..N`); `overflowCountMode` chooses what `N` means (`leftover` → count of hidden items, `total` → the full stashed count). The two settings are fully independent — every combination is valid, and the indicator always shows a number, never a bare prefix. Both settings, and the section containing them, are hidden from the settings menu whenever `displayMode` is `count`, since count mode never truncates anything and the settings would have no effect. 

### **8.3 Restore defaults** 

The settings menu includes a single confirmed action that resets every bar-widget setting back to its manifest default, so users can freely tune display/overflow settings knowing they can always return to a known-good baseline without hunting down each setting individually. 

### **8.4 Keybindings reference panel** 

The settings menu includes a drill-down page listing the plugin's documented keyboard and gesture bindings, each with a copy-to-clipboard affordance, plus a button that opens the relevant Hyprland config file (`bindings.lua` for keyboard shortcuts, `input.lua` for gestures) directly in the user's editor, jumped to the relevant line where possible. This never writes to the user's configuration itself — it only opens it for the user to edit, consistent with §3's rule against silently modifying user configuration. 

### **8.5 Discoverability fix (correction to the V1 bar-indicator contract)** 

V1 originally hid the bar widget entirely while the stash was empty (see the superseded first paragraph of §2, now corrected). Combined with the project's rule against auto-modifying user keybindings, a fresh install had no discoverable entry point at all beyond the CLI. §2's bar-indicator behavior — always visible, dimmed while empty, left-click reusing `toggle()`'s state-driven stash/restore semantics regardless of stash state, right-click always opening settings, discoverability carried by the hover tooltip rather than a forced-open menu — is the fix, and is a correction to the V1 contract rather than new V3-only scope. The V1 acceptance criteria in §6 reflect the corrected behavior. 

### **8.6 V3 compatibility** 

Bulk workspace-move, the settings additions, and the discoverability fix do not change the public stash/restore API, gesture bindings, or SUPER+M toggle semantics. Bulk workspace-move is additive and fully orthogonal; the settings additions are backward-compatible schema extensions with sensible defaults; the discoverability fix only changes what was an unintentional gap in the original V1 contract. 

# **9. Configuration defaults** 

|keyboard toggle|SUPER+M|Empty stash: stash current<br>workspace. Non-empty stash:<br>restore all to current workspace.|
|---|---|---|
|Setting|Default|Notes|
|gesture fingers|3|Documentation includes 4-finger<br>alternative.|
|bulk workspace-move|SUPER+CTRL+SHIFT+1-9,0|0 maps to workspace 10. Orthogonal<br>to the stash; never touches it.|
|displayMode|count|Allowed: count, names, icons.|
|maxNames|2|Overflow collapses into the<br>configured overflow indicator.|
|maxIcons|3|Overflow collapses into the<br>configured overflow indicator.|
|overflowStyle|badge|Allowed: badge (+N), ellipsis (..N).|
|overflowCountMode|leftover|Allowed: leftover, total. Independent<br>of overflowStyle.|
|stash workspace|special:workspace-stash|Private implementation workspace.|
|minimized set|global|Repeated swipe-downs append<br>windows; swipe-up restores all.|



# **10. Release discipline** 

### **V1** 

- Keep the implementation small and reviewable. 

- Ship only after testing multi-window tiled workspaces, repeated stash operations, restore into occupied workspaces, floating windows, closed clients, workspace switching, shell reloads, both gesture directions, SUPER+M toggle behavior, and each bar display mode. 

- Document the limitation that tiling may change after restore. 

- Tag the limitation as planned V2 work rather than hiding it. 

### **V2** 

- Add layout reconstruction behind the existing restore path. 

- Include tests/fixtures for common Dwindle trees: two-way split, nested split, asymmetric split ratios, and mixed tiled/floating groups. 

- Retain a safe fallback to ordinary restore. 

### **V3** 

- Ship bulk workspace-move as its own tested operation, including an occupied-destination merge case with two or more incoming windows (the collapse regression named in §8.1). 

- Ship the overflow-setting and reset-defaults additions with `omarchy plugin validate` and `qmllint` passing on every change. 

- Verify the discoverability fix (§8.5) against a simulated fresh install: no bar-widget interaction and no keybindings configured beforehand. 

# **11. Publishing checklist** 

- Public GitHub repository. 

- Valid root manifest.json. 

- README with screenshots or short demo if available. 

- Open-source license. 

- No install hooks requiring sudo. 

Workspace Stash - Feature & Implementation Specification 

- Safe removal: uninstalling the plugin must not leave permanent changes in Omarchy-owned files. 

- omarchy plugin validate passes on the release commit. 

- Submit the repository to omarchyplugins.com after validation. 

# **12. Reference notes** 

This specification is based on the current Omarchy Quattro plugin contract and Hyprland/Quickshell integration model. Verify these contracts again before release if Omarchy or Hyprland changes materially. 

- **Omarchy Quattro shell/plugin documentation:** 

https://github.com/basecamp/omarchy/blob/quattro/docs/omarchy-shell.md 

- **Omarchy shell plugin manual:** https://github.com/basecamp/omarchy/blob/quattro/manual/32-shellplugins.md 

- **Omarchy bar plugin documentation:** 

   - https://github.com/basecamp/omarchy/blob/quattro/shell/plugins/bar/README.md 

- **Omarchy Plugins publishing guide:** https://omarchyplugins.com/publish.html 

- **Hyprland documentation:** https://wiki.hypr.land/ 

Workspace Stash - Feature & Implementation Specification 

