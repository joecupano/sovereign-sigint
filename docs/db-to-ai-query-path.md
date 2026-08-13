# The DB→AI Query Path — How the Local LLM Queries Occupancy

**Status: WORKING.** The local LLM (via Open WebUI) can query the occupancy
database in natural language and answers from real data the RX-888 captured.
This document records the working solution and why it is the way it is, since
getting here involved three approaches and several dead ends worth not
repeating.

## The working solution: a native Open WebUI Python tool

The path that works is a **native in-process Open WebUI tool**:
`openwebui-tools/sovereign_sigint_occupancy_tool.py`. It defines a `Tools`
class with `query_occupancy` and `radiod_status`, type-hinted with Sphinx
docstrings the model reads, and queries the occupancy SQLite directly.

### Deploying it (the two things that matter)

1. **Mount the occupancy DB dir into the Open WebUI container.** The tool runs
   inside the container, so the DB must be visible there. In the Quadlet
   (`~/.config/containers/systemd/open-webui.container`), add a **plain
   read-write** bind mount of the whole `db/` directory:
   ```
   Volume=/home/<user>/sovereign-sigint/db:/data/sigint
   ```
   Then `systemctl --user daemon-reload && systemctl --user restart open-webui`.

   - Mount the **whole directory**, not just `occupancy.db` — WAL mode uses
     `-wal`/`-shm` sidecar files that must come along.
   - Use a **plain read-write** mount: NOT `:ro` (SQLite in WAL mode must
     touch the sidecars even to read, so `:ro` fails), and NOT `:U` (that
     would chown the host dir to the container's user and break the radiod
     producer's writes). The tool stays safe via a query-level guard (below).

2. **Install the tool in Open WebUI** — full step-by-step (including the
   model-registration step tools silently fail without) is in
   `docs/openwebui-setup-guide.md` ("Installing a Native Tool"). In brief:
   Workspace → Tools → create new → paste
   the file → Save. Confirm the `DB_PATH` valve is `/data/sigint/occupancy.db`
   (the default, matching the mount). Attach it to your model (Workspace →
   Models → model → Tools) and/or enable it per-chat via the tools icon.

### Why it's safe even with a read-write mount

The tool opens a normal SQLite connection (needed for WAL) but sets
`PRAGMA query_only=ON`, which makes SQLite reject any write on that
connection — verified: reads succeed, writes fail with "readonly database".
So it reads the live, continuously-written DB correctly without being able to
modify it. `busy_timeout` lets a read wait briefly if the producer holds the
write lock.

### Model note

Tool *calling* reliability depends on the model. In testing, the call fired
from a tool-capable local model with the tool attached and Function Calling =
Native; an explicit instruction ("Call query_occupancy now with low_hz … and
high_hz … and report the results") reliably triggered execution. Smaller
models may need the explicit phrasing; see Open WebUI's guidance that native
in-process tools are the most reliable tool path for local models.

## Why NOT the other two approaches (recorded so we don't relitigate)

We built all three. Only the native tool reliably works with local Ollama
models in Open WebUI.

### MCP server (parked, on the `broken-mcp` branch)
Correct and works with other MCP clients (Claude, Goose), but Open WebUI's
**native MCP client is broken**: it sends `Accept: application/json` without
the spec-required `text/event-stream`, so spec-compliant MCP servers return
HTTP 406 and the tools never load (open-webui Discussion #19568, Issue
#19525). Revisit if/when Open WebUI fixes its MCP client — see
`openapi-to-mcp-migration.md`.

### OpenAPI tool server (built, works, but local models won't invoke it)
`openapi-tools/sigint_openapi_server.py` sidesteps the MCP 406 (Open WebUI's
OpenAPI path is unaffected) and is reachable and correct — `curl` returns real
data, the connection tests green (after adding CORS middleware for Open
WebUI's browser-side preflight). BUT local Ollama models would not reliably
**invoke** the external OpenAPI tools: they described calls, denied
capability, or asked clarifying questions without ever executing — no request
reached the server. This matches Open WebUI's own docs (native in-process
tools are the most reliable; external OpenAPI the least with local models) and
community reports (Discussion #25737). The OpenAPI server is kept because it's
useful for OTHER clients and needs no per-model tool-calling finesse, but it
is **not** the Open-WebUI-with-local-models path.

## Summary

| Approach | Status | Use when |
|----------|--------|----------|
| **Native Open WebUI tool** | **WORKING — the answer for Open WebUI + local models** | Local LLM in Open WebUI querying occupancy (the primary case). |
| OpenAPI tool server | Works, reachable; local models won't reliably invoke | Non-Open-WebUI clients, or future Open WebUI versions with better external-tool calling. |
| MCP server | Parked (Open WebUI MCP client bug) | Other MCP clients (Claude/Goose) now; Open WebUI once its MCP client is fixed. |

The capture→DB→AI loop is closed: RF → RX-888 → radiod → occupancy producer →
occupancy DB → native tool → local LLM answering in natural language, entirely
on local hardware.
