"""
Faster-still capture: instead of `j/clients` (fetches every window on the
whole system, filtered client-side -- this is what made D's per-step cost
grow with N, since payload size grows with total open windows, not just
the batch being decomposed), ask Hyprland's own Lua API for only the
windows on ONE workspace (`hl.get_workspace_windows(ws)`), serialized to
a compact string in a single round-trip over the raw socket via `repl`
(confirmed: `repl <code>` returns the Lua return value directly over the
socket, same as the `hyprctl repl` CLI subcommand -- `eval <code>` does
not, it just acks "ok").
"""
from hypr_socket import raw_cmd

_SERIALIZE_LUA = '''local ws = hl.get_workspace_windows("%s")
local parts = {}
for i = 1, #ws do
  local w = ws[i]
  table.insert(parts, w.address .. "\\1" .. w.title .. "\\1" .. w.at.x .. "\\1" .. w.at.y .. "\\1" .. w.size.x .. "\\1" .. w.size.y)
end
return table.concat(parts, "\\2")'''


def capture_rects_scoped(title_to_name, ws_name):
    resp = raw_cmd("repl " + (_SERIALIZE_LUA % ws_name))
    rects = {}
    if not resp.strip():
        return rects
    for rec in resp.split("\x02"):
        if not rec:
            continue
        fields = rec.split("\x01")
        if len(fields) != 6:
            continue
        addr, title, x, y, w, h = fields
        if title in title_to_name:
            rects[title_to_name[title]] = (float(x), float(y), float(w), float(h))
    return rects
