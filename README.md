# my-panel

Container image for free PaaS platforms that only offer **"deploy from GitHub"**
and no terminal. It runs three things behind the single public HTTPS port that
these platforms hand you:

| Path | Service | Purpose |
|---|---|---|
| `/j/` | JupyterLab | your terminal + notebook |
| `/vless` | xray-core | VLESS over WebSocket |
| `/panel` | *stage 2* | the custom admin panel |

There is **no secret in this repository**. The UUID, the short ID and the Jupyter
token are generated on first boot into `/app/state`.

---

## Why one port matters

These platforms publish a single HTTPS port. You cannot give Jupyter, the panel
and the VPN traffic a port each. So `caddy` listens on `$PORT` and routes by
path. Everything behind it (`xray` on 10000, `jupyter` on 8888, the panel) binds
to `127.0.0.1` only and is unreachable from the internet directly.

## Deploy

1. Create an app on the platform, connect **this** repository.
2. Build command: leave empty.
3. Start command: `/entrypoint.sh` (or leave empty — it is the image `CMD`).
4. Port: the platform injects `$PORT`; nothing to set unless it asks.
5. **Mount a volume at `/app/state`** — otherwise a cold start generates a new
   UUID and Jupyter token every time.
6. Optional env: `PUBLIC_HOST=your.domain` (used only for the log banner).

The build is plain `Dockerfile`, no build args, nothing platform-specific.

## First run

The startup log prints the Jupyter URL **with the token in it**, the health URL,
and a ready-to-paste `vless://` link. Copy them from the platform's log view.

- `https://<domain>/j/?token=…` — the terminal
- `https://<domain>/healthz` — returns `ok`

## What works here and what does not

| | |
|---|---|
| VLESS + WebSocket + TLS | ✅ this is the one |
| VLESS-Reality | ❌ the platform edge terminates TLS; Reality needs you to own the TLS handshake |
| Hysteria2 / TUIC | ❌ no UDP |
| Custom ports | ❌ one port only |
| Traffic quality | ⚠️ shared egress IP, no speed guarantee |

## Stage 2 — the custom panel

`xray` is already exposing its gRPC management API on `127.0.0.1:10085`
(`service=HandlerService`). The panel is a small service that calls that API to
add/remove users, read traffic counters, and generate subscription links. It
will sit behind Caddy at `/panel` and bind to localhost like everything else.
