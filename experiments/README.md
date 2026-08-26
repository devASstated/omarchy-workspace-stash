# Reconstruction feasibility harness

Standalone Python scripts used to validate the layout-reconstruction
mechanism (see `docs/D-RECONSTRUCTION.md`) against a real Hyprland
session, before any of it was ported into `Service.qml`. Not part of the
plugin — `manifest.json`'s `entryPoints` never reference this directory,
so none of it ships. Kept as the evidence trail behind
`docs/RECONSTRUCTION-EXPERIMENTS.md`'s methodology and results.

- `harness_common.py`, `partition.py` — shared fixtures and the
  recursive-bipartition parser (Approach A, validated but not shipped —
  see `docs/D-RECONSTRUCTION.md` for why).
- `gate*.py` — the original feasibility gates: representative-leaf
  replay, geometry partitioning, orientation, extreme ratios,
  adversarial/malformed geometry.
- `attack_D_*.py`, `attack_E_*.py` — deliberate campaigns to break the
  destructive-decomposition approach (Approach D, shipped) and a special
  -workspace alternative, across dual-pseudo-tiling, groups, large N,
  injected failures, and stress conditions.
- `seam_integration_test.py`, `run_seam_test.py` — integration tests
  across the seam between the two approaches.
- `hypr_socket*.py`, `measure_settle_time*.py` — raw Hyprland IPC socket
  experiments and settle-time measurements that informed the
  Process/hyprctl-vs-socket transport tradeoff.

Each script talks directly to a live Hyprland compositor via `hyprctl`/
the Hyprland socket — not simulated, and not safe to run against a
session with windows you care about undisturbed.
