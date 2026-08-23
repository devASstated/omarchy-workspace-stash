# Workspace Stash — Design Journey

This document records how Workspace Stash's V1 implementation actually came
together: the architecture decisions, the bugs that were found by testing
against a real Hyprland/Quickshell session rather than assumed away, the
dead ends that got walked back, and the reasoning behind the choices that
survived. `docs/FEATURES.md` is the behavioral contract; this document is
the history of how the code came to satisfy it.

## 1. Starting point: inspecting before guessing

Before any code was written, the local Omarchy Quattro installation was
inspected directly rather than assumed from prior knowledge of similar
projects. That inspection covered the shell's plugin discovery model
(`~/.config/omarchy/plugins/<id>/`, manifest schema, `kinds` values), the
existing `service` + `bar-widget` pattern used by first-party plugins like
`omarchy.media`, and a real third-party window-minimize plugin
(`io.github.gardnmi.window-shelf`) already installed on the machine, which
turned out to be close prior art for moving windows to a private special
workspace by exact address.

That inspection produced the initial architecture: `Service.qml` as the
single authoritative owner of stash state, reading `Hyprland.toplevels`
directly so that Hyprland's own compositor state is the source of truth for
which windows are stashed, with `BarWidget.qml` as a presentation-only
consumer reached through `bar.shell.serviceFor(pluginId)`. Gesture and
keyboard bindings were designed from the start as thin adapters — shell
snippets that shell out to the plugin's own `workspace-stash` IPC target
rather than reimplementing stash/restore logic a second time.

## 2. V1 core: stash, restore, toggle

The core service settled quickly: `stash()` snapshots eligible windows on
the focused normal workspace into a plain array *before* issuing any moves
(never iterate a live Hyprland collection while relocating its members),
then dispatches one `hl.dsp.window.move(...)` per window via
`Quickshell.execDetached`. `restore()` does the same in reverse, moving
everything currently parked on `special:workspace-stash` — regardless of
which `stash()` call put it there — onto whichever workspace is focused at
the moment `restore()` runs. `toggle()` is a pure dispatcher: stash when
empty, restore when not.

A deliberate design choice from the beginning: metadata beyond raw
membership — batch id, source workspace, pre-move geometry — is kept in an
auxiliary `meta` map that is pruned to whatever is currently parked and
never consulted to answer "is this window stashed." That question is always
answered by reading `Hyprland.toplevels` fresh. This was framed early as
the load-bearing invariant of the whole plugin: Hyprland's live compositor
state remains authoritative, so no plugin-maintained state is allowed to
compete with it as a second source of truth.

The first validation pass tested this core against real applications —
Ghostty, foot, Nautilus, Brave, FontForge, and a synthetic window with a
deliberately unresolvable app-id — across floating windows, a fullscreen
window, closed-while-stashed clients, and a full Quickshell shell restart
mid-stash. All passed without needing any special-case code: closed clients
simply stop appearing in `Hyprland.toplevels`, so restore silently skips
them; fullscreen and floating state survived the tested move-and-restore
cases without additional plugin logic; and after a shell restart the
service correctly rediscovered the live stash purely by re-reading
Hyprland, with no persistence layer involved because none was needed.

## 3. The external-focus collision

Manual testing surfaced a real interaction bug: stashing several windows
including a music player, then pressing Omarchy's stock `SUPER+SHIFT+M`
Spotify shortcut, made the entire private stash workspace visibly pop open
like a scratchpad — defeating the premise that it is an implementation
detail the user never sees.

The investigation traced this to `omarchy-launch-spotify` (and the general
`omarchy-launch-or-focus` pattern it's built on): the script searches
*every* window on the system by class/title regex, with no awareness of
which workspace a match lives on, and dispatches a plain
`hl.dsp.focus({ window = "address:..." })`. When the match happens to be
parked on the plugin's private special workspace, Hyprland reveals that
workspace to satisfy the focus request. Confirmed directly with
`hyprctl monitors -j`: the monitor's `activeWorkspace` stayed on the real
underlying workspace throughout — only `specialWorkspace` flipped to
`special:workspace-stash`. This ruled out watching
`Hyprland.focusedWorkspace` as a detection strategy before any code was
written around it; that property simply never changes during the incident.

### First design considered and rejected: silently re-hide

The first fix considered was to detect the reveal and immediately toggle
the special workspace back closed — leaving the stash exactly as it was.
This was rejected on UX grounds: from the user's perspective, pressing a
keyboard shortcut that's supposed to do something and having nothing
visibly happen reads as "the shortcut is broken," not as "the plugin
correctly kept a secret."

### Second design: release the whole stash

The alternative — treat the reveal as an implicit restore request, so the
externally-requested app (and everything stashed alongside it) lands on the
user's current workspace — was adopted instead, with one explicit
constraint locked in during design discussion: **stashing may be
cumulative, but restoration is always atomic across the complete stash.**
Any code path that means "give the stash back" has to go through the one
existing `restore()` function; per-window release was explicitly rejected,
both because `docs/FEATURES.md` already rules out per-window restore as a
V1 non-goal, and because a partial release was shown to be strictly riskier
in practice — the *entire* special workspace gets revealed to satisfy any
single focus request into it, so releasing only one window would still
momentarily expose every other stashed window before a second corrective
step could re-hide them.

## 4. Finding a detection signal that actually works

The first implementation of the collision guard watched
`HyprlandMonitor.lastIpcObjectChanged` and `HyprlandWorkspace.activeChanged`
— Quickshell's higher-level convenience properties for exactly this kind of
state. It never fired. Reproducing the collision repeatedly and checking a
synchronous, on-demand read of those same properties at the exact instant
of a confirmed reveal showed they read back "not active" even then — not
merely a missing change notification, but a genuinely stale cached value in
this Quickshell version. Both a manual toggle and a plain workspace-switch
control were tried as sanity checks; neither property reflected reality for
this event class.

The eventual fix went one layer lower: `Hyprland.rawEvent`, the raw
Hyprland IPC event stream that Quickshell's own higher-level models are
themselves built on. Watching it directly during a real reproduction
surfaced the actual event — `activespecial>>special:workspace-stash,eDP-1`
on reveal, `activespecial>>,eDP-1` on hide — reliable and immediate. This
became the sole detection mechanism: filter `Hyprland.rawEvent` for
`activespecial` events naming the plugin's own workspace, and treat that as
the trigger for a full `restore()`.

## 5. The focus-recovery dead end

Once detection worked, the natural next question was whether the
originally-requested application could be handed real input focus after
restoring the stash, so the external shortcut felt like it "just worked."
Capturing `Hyprland.activeToplevel` at the moment of collision looked
promising in a single-window reproduction, but failed in a three-window
reproduction: the captured address consistently pointed at whichever window
the plugin's *own* `stash()` had moved *last*, not the window the external
script had actually asked for.

Switching to the raw `activewindowv2` event (which fires immediately before
`activespecial` in the same transaction) ruled out a caching problem —
the raw event itself reported the wrong window. A fully isolated
reproduction, using nothing but a bare `hyprctl dispatch` with no plugin
code involved at all, confirmed this is genuine Hyprland behavior, not a
Quickshell or plugin bug: requesting focus on one specific window inside an
already-populated, currently-hidden special workspace does not necessarily
focus that window — Hyprland substitutes whatever it internally considers
the workspace's own top-of-stack window instead, and that substitution
is not recoverable from anywhere in the IPC/event stream (`activeToplevel`,
`activewindowv2`, and per-client `focusHistoryID` were all checked and all
only ever reflected Hyprland's substituted choice).

Given that the *correct* answer often isn't discoverable at all, the
decision was made not to force focus onto the substituted window either —
doing so would misrepresent an arbitrary window as fulfilling the user's
actual request. V1 restores the whole stash and lets Hyprland's own natural
focus resolution settle wherever it settles. A single-window stash still
behaves as expected, simply because there's only one candidate for Hyprland
to land on — no separate code path was added for that case; it falls out
of the general one for free.

## 6. The second collision bug: the workspace stays logically active

Manual testing after the first collision fix landed found a second, subtler
problem: restoring every stashed window was necessary but not sufficient.
The compositor could remain logically parked in `special:workspace-stash`
even once it held nothing, so an application launched immediately
afterward would open *into* the now-empty special workspace and get
correctly — but undesirably — counted as freshly stashed, since Hyprland
membership is still the plugin's sole source of truth.

The fix needed a reliable way to check, once the stash was empty, whether
the special workspace was still active — and here the earlier
lesson about Quickshell's cached properties applied a second time, joined
by a new one: tracking the *deactivation* half of the `activespecial` event
stream turned out to be unsafe too, because Hyprland does not reliably emit
a clean "deactivated" event when a special workspace simply empties out on
its own. A flag maintained purely from that event stream could race and
wrongly conclude "already hidden" for exactly the case the fix exists to
catch.

The eventual mechanism queries `hyprctl -j monitors` directly — a fresh
read straight from Hyprland's own IPC, bypassing Quickshell's cache
entirely — at the moment the stash count reaches zero, and only issues the
deactivation dispatch if that query confirms the workspace is still active.
This mirrors a pattern already present in `io.github.gardnmi.window-shelf`,
which independently arrived at the same technique for its own
special-workspace visibility check, for the same underlying reason
(documented in that plugin's own `AGENTS.md`).

The dispatcher itself — `hl.dsp.workspace.toggle_special(...)` — was
confirmed by reading the complete `HL.DspWorkspaceNamespace` field list
in the installed Hyprland Lua stubs rather than assumed: it is genuinely
the only dispatcher exposed for this, so it is inherently toggle-based, and
calling it unconditionally would risk *opening* an already-hidden
workspace. That's why the fresh `hyprctl -j monitors` check exists at all
— to make the toggle call conditional on a confirmed-active state, and
scoped specifically to the collision-recovery path so that ordinary
`stash()`/`restore()` calls — swipe gestures, `SUPER+M`, `SUPER+ALT+M` —
can never trigger it themselves.

The full collision lifecycle, as implemented:

```
external focus request
        │
        ▼
activespecial for special:workspace-stash   (Hyprland.rawEvent, verified)
        │
        ▼
collision restore marked in-flight           (reentrancy guard)
        │
        ▼
root.restore()                               (same authoritative path)
        │
        ▼
wait for stashedToplevels.length === 0       (reactive, no sleep)
        │
        ▼
fresh `hyprctl -j monitors` check
        │
        ├── still active → toggle_special() to deactivate
        │
        ▼
clear in-flight flag
        │
        ▼
user remains on the underlying normal workspace
```

## 7. The bar interaction pass

With the collision lifecycle stable, the same investigate-before-building
approach was applied to adding mouse interaction to the bar widget. Before
writing any interaction code, the installed shell's `qs.Ui` component
library was read directly to find the actual native primitives rather than
inventing custom ones: `PopupCard` turned out to be the exact
bar-anchored-popover pattern already used by `omarchy.media` and the audio/
network/tailscale panels (`open` boolean the caller controls, automatic
outside-click dismissal via `HyprlandFocusGrab`, automatic positioning
relative to the bar edge), and `NumberField`/`PanelSlider` turned out to be
fully themed, ready-made numeric controls — meaning the later decision to
expose `maxNames`/`maxIcons` as spinners in the same menu cost only a few
lines rather than any new UI infrastructure.

The persistence question mattered too: right-clicking to change the
display style needed to write to the *same* setting the
`omarchy bar set <id> displayMode <mode>` CLI command already writes, with
no second settings store. Tracing `omarchy bar set` through
`omarchy-bar` → `omarchy-shell shell setBarWidget` → `shell.qml`'s
`setBarWidget` → `PluginRegistry.setBarWidget` found that the real
implementation is reachable directly from QML as
`bar.shell.pluginRegistry.setBarWidget(id, key, value, selector)` — an
ordinary in-process method call, not something that requires going out
through IPC and back in. Left-click restore and the right-click menu's
writes were both built on primitives that already existed in the shell,
rather than new ones.

Two bugs surfaced once this was tested against a real hover, not just
lint-checked:

- **The tooltip never appeared at all**, initially. Reading `Bar.qml`
  directly showed that `showTooltip(target, text)` independently
  re-verifies `target.tooltipHovered === true` on the widget itself before
  displaying anything — it does not simply trust that `onEntered` fired.
  The widget had never declared that property. The fix mirrors the
  convention already used by `qs.Ui.WidgetButton`: a plain
  `readonly property bool tooltipHovered: visible && mouseArea.containsMouse`.

- **The tooltip's stashed count went stale and inconsistent** during rapid
  repeated stash/restore cycles while the cursor stayed still over the
  widget — reported by manual testing as the number appearing to cycle
  unpredictably between values that didn't match the bar's own (always
  correct) live count. The cause: `showTooltip()` only ever snapshots its
  `text` argument once, at the moment it's called, and never re-reads it.
  Because Hyprland applies each window's move as a separate asynchronous
  event rather than atomically, the stash count advances in visible steps
  during a multi-window operation, and the widget's own `visible`/width
  changing in step with that count could retrigger `onEntered` under a
  stationary cursor and snapshot whatever transient, not-yet-settled count
  happened to exist at that instant. The bar's own rendering was never
  wrong — it's a live binding — only the frozen tooltip snapshot was. The
  fix re-issues `showTooltip` from an `onTooltipTextChanged` handler
  whenever the widget is still genuinely hovered, so the displayed text can
  no longer go stale.

## 8. Overflow indicator: three iterations

The `+N` overflow badge itself went through a real design evolution rather
than landing correctly on the first attempt:

1. **First version**: the badge was baked directly into the same string
   that got pixel-width-elided (`"name, name, name +3"`, all one `Text`
   with `elide: Text.ElideRight`). This meant a sufficiently long name list
   could have its own `+N` suffix silently eaten by Qt's ellipsis, leaving
   only `"…"` — exactly the bug reported from manual testing.

2. **Fix**: the shown-names text and the overflow badge were split into two
   independent elements. The names portion elides on its own if it doesn't
   fit; the badge is a separate, fixed `Text` that is never subject to
   eliding, so it can no longer be swallowed. Icons mode already worked
   this way by construction (icons and their overflow count were always
   separate elements) and never needed the fix; the change brought names
   mode in line with it.

3. **Final refinement**, requested after the fix landed: rather than
   showing *some* count indicator whenever anything was truncated versus a
   bare total when nothing was, the simpler rule was adopted — show nothing
   in the trailing position when everything fits, show `+N` only when items
   are genuinely hidden by the `maxNames`/`maxIcons` limit. This was judged
   more intuitive than the richer alternative first proposed, and is
   simpler to implement: `nameOverflow`/`iconOverflow` are computed purely
   from the count-based slice against the configured limit, independently
   of whatever the `Text` element's own elide happens to do to the
   already-decided-to-show portion. A styling choice between `…`-style and
   `+`-style overflow indicators, and between showing a running total
   versus only a leftover count, was noted as a plausible V2 "advanced
   display" setting rather than built now.

## 9. Expanding the settings surface

`maxNames` and `maxIcons` were initially left CLI-only, gated on an
explicit rule: only add them to the right-click menu if the shell's native
UI framework made numeric controls "effectively free," and report the
limitation rather than build custom settings infrastructure otherwise.
Reading `NumberField.qml` confirmed that condition was met — it is a
complete, already-themed integer spinner used elsewhere in the shell — so
both limits were added as menu rows with no new component work. No other
settings were added; the deliberately compact three-value surface
(`displayMode`, `maxNames`, `maxIcons`) that `docs/FEATURES.md` calls for
was judged to already cover everything that meaningfully varies user to
user for a presentation-only widget.

A late wording pass replaced "mode" with "style" in every user-facing
string (the tooltip hint and the menu section header) after manual testing
feedback that "style" reads more naturally to an end user. The underlying
persisted setting key, `displayMode`, was deliberately left unchanged —
renaming it would have broken the documented `omarchy bar set ... displayMode
...` CLI usage and any already-persisted `shell.json` entries for a
wording-only concern.

## 10. Testing methodology and its limits

Every behavioral claim in this document was checked against the real
compositor, not inferred from reading code alone — spawning disposable
windows with deliberately synthetic app-ids, moving them through
`hyprctl dispatch` with the same Lua dispatcher syntax the plugin itself
uses, and inspecting ground truth with `hyprctl clients -j` /
`hyprctl monitors -j` rather than trusting the plugin's own view of itself.
Two limits of that approach are worth recording:

- Automation issued through a terminal running inside the same Hyprland
  session competes for real compositor focus with whatever else is
  happening on the desktop. Several early test runs that appeared to fail
  turned out to be this artifact — a workspace-focus dispatch and the
  subsequent action separated across two tool calls left enough of a gap
  for the terminal to reclaim focus in between. Issuing the focus change
  and the triggering action atomically, in a single command, eliminated the
  false negatives; genuine user input (a physical gesture or keypress) does
  not have this problem, since there is no competing automated process.

- No mouse-click simulation tool (`ydotool`, `wlrctl`) was available on the
  system, and installing one was left to the user's discretion rather than
  done unilaterally. Left-click, right-click, and the resulting menu
  interactions were validated through a combination of automated
  verification of the underlying calls (`restore()`, `setBarWidget`, direct
  `hyprctl` equivalents of every UI action) and manual click-testing
  performed against a written procedure, rather than end-to-end automated
  UI clicking.

## 11. V2: choosing the smallest reconstruction that could work

`docs/FEATURES.md` §7.4 describes the full target for layout-preserving
restore: group captured rectangles by batch, infer an actual binary split
tree from their edges/containment/adjacency, and drive restore through
controlled Dwindle preselect and ratio-adjustment dispatches. The same
section already names why that's hard — two different trees can produce
windows with identical dimensions, so geometry alone can't be inverted
back into a tree reliably.

Before writing any V2 code, a deliberately smaller alternative was
proposed and agreed on instead of the full algorithm: restore tiled
windows in an order approximating their original position (Dwindle splits
whichever window is currently active, so *order* alone gets a real-world
layout materially closer without inferring a tree at all), and restore
floating windows from their captured geometry directly, since they sit
outside the tiling tree entirely and don't need any inference. This was a
scope decision made and approved before implementation began, not a
shortcut discovered after the fact — and, as later sections show, its
edges turned out to be exactly where the rejected full algorithm would
have been needed.

## 12. Building a test harness, and the tooling problems that came before the real ones

V1 was validated mostly by hand — disposable windows and a written
click-testing procedure, because no click-simulation tool was available.
V2's behavior is almost entirely inspectable through `hyprctl`/`omarchy-shell`
directly, so a Python harness was built to drive stash/restore through the
same commands a gesture or keybinding would, snapshot window geometry
before and after with `hyprctl -j clients`, and assert on the result — far
faster than re-running a manual procedure after every change, and just as
grounded in the real compositor.

Three tooling problems surfaced before any real product bug did, each
worth recording because each one produced misleading results that looked
like product bugs at first:

- **`pkill` is blocked by the execution sandbox.** A cleanup helper that
  killed disposable test windows by process name failed silently — the
  command exited with a signal-like code but the *test script* kept
  running as if cleanup had succeeded, silently accumulating leftover
  windows across test runs and corrupting later results in ways that
  looked exactly like ordering bugs. Fixed by closing windows through
  `hyprctl` by address (`hl.dsp.window.close`) instead of `pkill` — the
  same address-based approach the plugin itself uses, which sidesteps the
  sandbox restriction entirely.

- **A shell-quoting bug in the test harness itself.** Every dispatch call
  built as `hyprctl dispatch "hl.dsp....(window = \"address:...\")"` and
  run through a shell silently had its *inner* quotes stripped by the
  shell before Lua ever saw them, turning a valid Lua string literal into
  a syntax error that the harness didn't check for. Every dispatch in an
  early test run silently failed this way — spawning windows worked
  (that path didn't use this pattern), but every subsequent float/resize/
  move/focus/close call did nothing, producing results that looked
  exactly like the plugin was scrambling window state, when the plugin
  had not actually been exercised at all. Fixed by passing the Lua
  expression as a single argv element (`["hyprctl", "dispatch", request]`,
  no shell), matching the exact pattern `Service.qml` itself already uses
  via `Quickshell.execDetached`.

- **Legacy dispatcher syntax, rediscovered.** `hyprctl dispatch <name>
  <args>` (and even `hyprctl output create headless`'s workspace-focus
  helper) fails under Quattro's Lua-based dispatch bridge, the same lesson
  V1 already learned for the plugin's own code (§3) — this time hitting
  the *test harness*, which had reintroduced the legacy form. Every
  `hl.dsp.*` call had to be verified as a full Lua expression string
  first.

With all three fixed, the harness became trustworthy enough to actually
find the real bugs below — each confirmed with before/after `hyprctl`
snapshots, not inferred from test output alone.

## 13. Bug: `pruneMeta()` deleting a stash mid-flight

The first real product bug: restoring a 3-window stash reliably lost 2 of
the 3 windows' captured order/geometry data. A temporary debug IPC method
was added to `Service.qml` to inspect `root.meta` directly after `stash()`
— not guessed at — and it showed only one entry surviving out of three,
immediately after a `stash()` call that should have produced three.

The cause: `stash()`'s window-move dispatches land in Hyprland one at a
time, asynchronously. `pruneMeta()` ran on every partial update of
`stashedToplevels` (the reactive "what's currently parked" view) and, keyed
on that same property, treated "hasn't landed in the stash yet" as "no
longer needs tracking" — deleting a freshly-written meta entry the instant
a *different* window in the same batch happened to land first. Fixed by
re-keying the prune condition on "does this window still exist as a
toplevel anywhere" (only true once a window is closed) instead of
"is it currently parked" — a window moving between workspaces was never a
reason to forget its metadata; only closing it is.

## 14. Bug: geometry read from a cache that wasn't populated yet

Fixing the prune race didn't fix restored floating windows landing at the
wrong position — the same debug method showed *why*: for a window that had
just been created or resized, Quickshell's cached `lastIpcObject` was
missing its `at`/`size`/`floating` fields entirely, not merely behind.
`eligibleWindowsOn()`'s existing fallback (`ipc && Array.isArray(ipc.at) ?
... : 0`) silently captured zeroed, garbage geometry for exactly the
windows a repeated stash/restore cycle touches most — the ones that were
just moved a moment earlier.

The fix mirrors a pattern V1 already established for a different reason
(§6): bypass Quickshell's cache with a fresh, direct `hyprctl -j clients`
query. Here it was applied more broadly than before — not just to confirm
special-workspace deactivation, but to decide *both* which windows are
eligible to stash *and* their geometry, from one ground-truth snapshot,
rather than trusting `Hyprland.toplevels` for either. A first attempt kept
eligibility on the Quickshell-cached path and only moved geometry capture
to the fresh query; that still occasionally grabbed the wrong subset of
windows under fast repeated cycling, so eligibility was moved to the same
fresh query too.

## 15. Bug: cross-window dispatch ordering

With capture fixed, a 2-window restore still occasionally swapped which
window ended up in which position — but only under fast repeated cycling,
and the *set* of window sizes was always correct, only the identity-to-slot
assignment was wrong. A raw `hyprctl` reproduction outside the plugin,
issuing the exact same per-window `--batch` dispatch sequence restore()
already used, never reproduced the bug — pointing at something specific to
how the plugin issued the sequence, not the dispatches themselves.

The cause: each window's `[move, focus]` (or `[move, resize, position]`)
pair was already atomic as one `--batch` call, but *different* windows'
batches were still separate `Quickshell.execDetached` processes with no
guarantee about the order they'd reach Hyprland relative to each other —
ordinary OS process-scheduling variance, not something the plugin
controlled. Under fast repeated restores, a later window's move could
occasionally land before an earlier one's focus-for-ordering call, quietly
reassigning which window ended up in which split. Fixed by combining the
*entire* restore sequence — every window's placement and follow-up — into
one `hyprctl --batch` call, removing the inter-process ordering gap
entirely rather than trying to narrow it.

## 16. A user-taught reproduction finds the row-tolerance bug

Testing whether Hyprland window groups (tabbed windows) survive stash/
restore required first learning how to create one — Omarchy's own
`SUPER+G`/`SUPER+ALT+LEFT-RIGHT-UP-DOWN` group bindings, confirmed active
via `hyprctl binds` before use. A 2-tile layout (one group, one plain
window) restored perfectly; adding a third, unrelated window changed the
layout on restore.

Isolating the cause showed the group itself was never the problem — the
same failure reproduced identically with three plain, ungrouped windows in
a true 2×2 grid, and separately with a grouped one. The real cause: a
grouped window's tab bar pushes its captured `y` down by a small,
consistent offset (confirmed empirically at ~28px for a 2-tab group)
compared to an ungrouped window at the same visual row. `restoreOrder()`'s
sort treated any `y` difference as "a different row," so it occasionally
ranked a window before a group that was actually beside it, swapping their
left/right placement even though the group itself stayed correctly
intact throughout. Fixed with a small tolerance (40px) on the row
comparison — wide enough to absorb chrome offsets like tab bars, gaps, and
borders, not wide enough to blur two genuinely stacked windows together.

## 17. Ratio preservation, and where "smallest lightweight" hits its wall

Order-only restore never touched window *size* for tiled windows — a
deliberately asymmetric split (one window resized far larger than its
sibling) reliably came back as an even 50/50 split on restore, even though
position and order were both correct by this point. Confirmed cheap to fix
once tested directly: Hyprland's absolute resize dispatch
(`hl.dsp.window.resize({ x = width, y = height, ... })`) works identically
on a tiled window as on a floating one, adjusting its sibling to
compensate — the same mechanism already used for floating geometry could
restore tiled ratios too, using width/height V1 already captured.

Getting the sequencing right required splitting `restore()`'s dispatch
building into two phases within the same combined batch: phase 1 places
every window and builds the tree topology (unchanged from §15); phase 2,
run only *after* the whole tree exists, resizes every window to its
captured size. Interleaving the two — resizing a window immediately after
placing it, before the next window is inserted — doesn't work, because
Dwindle re-splits evenly whenever a new window arrives, silently resetting
an already-restored ratio the moment its sibling shows up.

That fix, tested and confirmed working for straightforward splits,
surfaced a deeper and uglier failure one layer down: a window inserted
into an already-split pair (for example, a third window added inside the
larger half of an asymmetric two-way split, or any true 2×2 grid — two
independently-split columns) doesn't just lose its ratio, it can scramble
into a different topology entirely. Root cause traced precisely:
`restoreOrder()`'s sort produces a flat sequence, and phase 1 always
places each window by splitting whichever single window is currently
active — a *linear chain* of splits. It has no way to express "insert this
window as a sibling of an already-built pair," which is exactly what a
branching layout like a 2×2 grid requires. Reconstructing that correctly
is precisely the full split-tree inference `FEATURES.md` §7.4 describes
and §11 above deliberately chose not to build. Given a choice between
attempting a partial, order-dependent patch for this specific shape (risking
exactly the kind of brittle special-casing this project has avoided
throughout) and accepting the boundary, the boundary was accepted, and
documented directly in `restoreOrder()`'s and `structureClauses()`'s code
comments rather than papered over.

## 18. Correcting a keybind decision against upstream, not just the local install

Switching the cumulative-stash binding from `SUPER+ALT+M` to `SUPER+CTRL+M`
(for a cleaner mnemonic pairing with `SUPER+M`, once digit-key testing
for a planned V3 feature revealed `SUPER+ALT+<digit>` was already claimed)
was first checked only against the live `hyprctl binds` output on the
development machine — which also reflects local customizations and
installed third-party plugins, not just Omarchy's own defaults. Asked
directly whether upstream had been checked, not just the local config, the
claim was verified a second way: fetching Omarchy's actual default
keybinding files from `basecamp/omarchy` (the `quattro` branch) on GitHub
and searching all six of them directly. That check also caught a factual
error in the first pass — `SUPER+ALT+M` had been described as an existing
Omarchy default (confused with `SUPER+SHIFT+ALT+M`, its actual Music-TUI
binding); the correction was written into both `examples/bindings.lua` and
the local test binding's comment once confirmed.

## 19. V3 candidates surfaced, deliberately not built here

Several ideas came up during V2 testing and design discussion that were
judged worth pursuing, but out of scope for this pass — kept as a clean
backlog rather than folded into a commit whose stated scope is
layout-preserving restore:

- **Bulk workspace-move** (proposed keybinding: `SUPER+CTRL+SHIFT+1-9`,
  confirmed free against both the live install and upstream Omarchy
  defaults): move everything on the current workspace to workspace N,
  preserving layout best-effort, without following the view there and
  without touching the stash at all — a distinct, stateless operation
  reusing most of V2's restore machinery, not an extension of stash/
  restore semantics. Nothing in Hyprland or Omarchy provides this today;
  confirmed by checking Omarchy's own command list and Hyprland's
  dispatcher set directly rather than assuming.
- **Advanced overflow display settings**: a choice between `…`-style and
  `+N`-style overflow indicators, and between a running total and a
  leftover-only count — noted as a plausible V2 setting back in §8 and
  explicitly deferred again here.
- **A keybindings reference panel** in the bar widget's right-click menu:
  the documented keyboard/gesture snippets shown directly in the settings
  popover with a copy affordance, plus a button to open the relevant
  Hyprland config file (`bindings.lua` for keyboard shortcuts,
  `input.lua` for gestures — two different files, so likely two separate
  open targets). Modeled on a real precedent found in another installed
  plugin (`ilyazar.btop`), which opens the user's `bindings.lua` directly
  from its own settings row rather than auto-writing to it — the same
  "never modify user config automatically" principle this project has
  followed throughout, just with less friction for the user who chooses
  to do it themselves.

## Status at the end of this document

V1's full scope and V2's layout-preserving restore — batch-ordered tiled
reconstruction, exact floating-geometry restore including cross-monitor
clamping, and split-ratio preservation — are implemented and verified
against a real Hyprland session, including edge cases (Hyprland groups,
shell restarts, rapid repeated cycling, external-focus collisions) beyond
what either `FEATURES.md` release-discipline checklist enumerates by name.
One limitation is accepted and documented rather than fixed: layouts where
a window is inserted beside an already-built group of windows, not the
single most-recently-placed one — a 2×2 grid is the clearest example —
aren't reliably reconstructed, because that requires the full split-tree
inference `FEATURES.md` §7.4 already named as hard and this project chose
not to build. `LICENSE` and this document are current; `README.md` was
written alongside this update. The plugin id remains the placeholder
`io.github.REPLACE_ME.workspace-stash`, pending a real GitHub namespace
before publishing. Three ideas raised during V2 — bulk workspace-move,
advanced overflow settings, and a keybindings reference panel — are
captured in §19 as V3 candidates, not started.
