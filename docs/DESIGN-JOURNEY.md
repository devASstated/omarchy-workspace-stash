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

## Status at the end of this document

V1's core stash/restore/toggle behavior, the external-focus collision
lifecycle, and the bar interaction pass (click-to-restore, the display
style menu, and the two overflow limits) are all implemented and verified
against a real Hyprland session. `README.md`, `LICENSE`, and the final
plugin id (still the placeholder `io.github.REPLACE_ME.workspace-stash`)
remain outstanding before this is ready for public release. No V2 work —
layout-preserving restore — has been started.
