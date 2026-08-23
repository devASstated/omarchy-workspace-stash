# Workspace Stash development rules

Read `docs/FEATURES.md` before making architectural or behavioral changes.
Read `docs/DESIGN-JOURNEY.md` before touching `stash()`/`restore()`/anything
in `Service.qml` that decides ordering, captures geometry, or batches
dispatches — several non-obvious bugs were already found and fixed there
(a metadata-pruning race, stale-cache geometry capture, cross-process
dispatch ordering); re-reading the relevant section first is faster than
rediscovering the same failure mode from scratch.

Current development target: V1 and V2 (layout-preserving restore) are both
implemented and tested. V3 — bulk workspace-move, advanced overflow display
settings, and a keybindings reference panel in the bar widget's settings
menu — is scoped in `docs/DESIGN-JOURNEY.md` §19 but not started.

Do not implement V3 features unless explicitly requested.

Do not try to fix the known, deliberately-accepted layout-reconstruction
limitation (`docs/DESIGN-JOURNEY.md` §17): a window that needs to be
inserted beside an already-built group of windows, not the single
most-recently-placed one (a 2x2 grid is the clearest example), isn't
reliably reconstructed today. This was found, investigated, and explicitly
accepted rather than fixed — twice reconfirmed by the project owner, not an
oversight. Raise it in conversation before changing
`restoreOrder()`/`structureClauses()`/`geometryClauses()` to address it.

Priorities:

1. Preserve the behavior defined in FEATURES.md.
2. Prefer native Quattro/Quickshell/Hyprland facilities.
3. Keep runtime architecture event-driven and minimal.
4. No polling loops.
5. No daemon or persistent state unless the project specification is deliberately revised.
6. Gesture bindings and keyboard bindings are input adapters only.
7. Core stash/restore behavior must have one authoritative implementation.
8. Do not silently overwrite user configuration.
9. Keep the project suitable for public distribution as an Omarchy plugin.
10. When a value needs to be correct at the instant it's read, not just
    eventually consistent, prefer a fresh `hyprctl -j <query>` over
    Quickshell's cached Hyprland models — this codebase has hit real,
    hard-to-diagnose bugs from trusting that cache more than once.
11. All git actions should be requested and never be performed without user review - present the git message along with summary of what was implemented before requesting for a git commit action 
