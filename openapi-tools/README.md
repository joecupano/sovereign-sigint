# SIGINT OpenAPI Tool Server

> **Status: SUPERSEDED / disabled by default.** The working path for querying
> SIGINT data from the local LLM is now the **native in-process Open WebUI
> tools** in `../openwebui-tools/` (occupancy, Kismet, SigID) — local Ollama
> models would not reliably *invoke* external OpenAPI tools, whereas native
> in-process tools fire reliably (see `docs/db-to-ai-query-path.md`). This
> OpenAPI server still works and is kept as an alternative — useful for
> non-Open-WebUI clients, or if a future Open WebUI version improves external
> tool-calling — but it is **not** installed/enabled by default on the
> reference box. Everything below describes how to run it if you want it.

Read-only SIGINT tools exposed to Open WebUI as an **OpenAPI** tool server:
`query_occupancy`, `lookup_signal_candidate`, `radiod_status`. These let a
client query the occupancy database (populated continuously by the radiod
producer) and check radiod status, in natural language.

## Why OpenAPI and not MCP

The identical tools also exist as an MCP server (`mcp/` on the `broken-mcp`
branch), but Open WebUI's native MCP client is currently broken (it omits the
`text/event-stream` Accept header → HTTP 406 → tools never load; documented
in open-webui Discussion #19568 and Issue #19525). Open WebUI's OpenAPI path
works fine, so this server exposes the same tools that way — **one process,
no MCPO proxy needed**. See `docs/openapi-to-mcp-migration.md` for the switch
back to MCP once Open WebUI fixes its client.

## Tools (all read-only)

| Endpoint | What it does |
|----------|--------------|
| `GET /query_occupancy` | Query logged occupancy by frequency window / mode / recency. |
| `GET /lookup_signal_candidate` | Candidate SigID for logged signals in a frequency window. |
| `GET /radiod_status` | radiod service state + configured channels. |

Interactive docs (Swagger UI) at `/docs` once running.

## Install

```
python3 -m venv /opt/sovereign-sigint/venvs/openapi
/opt/sovereign-sigint/venvs/openapi/bin/pip install -r requirements.txt
```

## Run

```
# Loopback (default) — safest; reach via SSH tunnel or same-host container:
/opt/sovereign-sigint/venvs/openapi/bin/python sigint_openapi_server.py

# If Open WebUI's container reaches the host at its LAN IP (as on the
# reference box), bind 0.0.0.0 and rely on ufw default-deny (Ollama posture):
SIGINT_OPENAPI_HOST=0.0.0.0 /opt/sovereign-sigint/venvs/openapi/bin/python \
    sigint_openapi_server.py
```

Environment:
- `SIGINT_OPENAPI_HOST` (default `127.0.0.1`), `SIGINT_OPENAPI_PORT` (`8130`)
- `SIGINT_OCCUPANCY_DB` (default `<repo>/db/occupancy.db`) — same var the
  producer and MCP server use.

## Register in Open WebUI

Admin Panel → Settings → External Tools → **+ Add Server** →
Type **OpenAPI**, URL `http://host.containers.internal:8130` (the container
reaches the host there on the reference box). Open WebUI reads
`/openapi.json` and the three tools appear. Enable them in a chat and set the
model's Function Calling to Native.

## Security

Same posture as the MCP server (governed by
`docs/mcp-server-security-requirements.md`):
- **Read-only** (SQLite `mode=ro`); no endpoint writes.
- **Validated params** — modes allowlisted, frequencies/lookback
  range-checked, results capped; all SQL parameterized.
- **Loopback default**; bind `0.0.0.0` only behind ufw default-deny.
- **No side effects** — worst case if reached is reading occupancy data.

Optionally run behind an API key / reverse proxy if you want auth; for a
read-only, ufw-protected, single-box tool this is usually unnecessary.
