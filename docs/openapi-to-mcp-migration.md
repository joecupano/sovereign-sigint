# Migrating from the OpenAPI tool server back to MCP

## Why we're on OpenAPI right now

The SIGINT tools (`query_occupancy`, `lookup_signal_candidate`,
`radiod_status`) exist in two functionally-identical implementations:

- **`openapi-tools/sigint_openapi_server.py`** — the ACTIVE one. A FastAPI
  server exposing the tools as OpenAPI endpoints.
- **`mcp/sigint_mcp_server.py`** (on the **`broken-mcp`** branch) — the MCP
  version. Correct and working, but currently unreachable by Open WebUI.

We run the OpenAPI version because Open WebUI's **native MCP client is
broken**: during tool validation it sends `Accept: application/json` and
omits the spec-required `text/event-stream`, so any spec-compliant MCP
server returns HTTP 406 and the tools never load. This is a documented,
client-side Open WebUI bug (the same MCP server works with Claude and
Goose):

- open-webui/open-webui **Discussion #19568** — "MCP Tool Validation Fails
  Due to Missing 'text/event-stream' Accept Header (Strict Spec Compliance)"
- open-webui/open-webui **Issue #19525 / Discussion #19530** — same root
  cause, MCP Streamable HTTP client can't inject the required Accept header

Open WebUI's **OpenAPI** tool path is unaffected, so the OpenAPI server
works today with a single process and no proxy. (We deliberately did NOT
use the MCPO proxy — that would mean running the MCP server *plus* MCPO,
two processes, purely to dodge the broken MCP client.)

## When to switch back to MCP

Switch back once Open WebUI has fixed its MCP client — i.e. Discussion
#19568 / Issue #19525 are resolved and you're on a release that includes
the fix. Reasons you might want to:

- **MCP portability** — the same MCP server is reachable by other MCP
  clients (Claude Desktop, Goose, etc.), not just Open WebUI. If you ever
  want these tools available outside Open WebUI, MCP is the portable
  contract; OpenAPI is Open-WebUI-shaped.
- **One consistent protocol** if the rest of your tooling moves to MCP.

There is **no functional urgency** — the OpenAPI server does everything the
MCP server does for Open WebUI. This is a portability/consistency choice,
not a capability one.

## How to check whether the bug is fixed

1. Confirm your Open WebUI version and check the two issues above for a
   "fixed in vX.Y.Z" note (or test directly — step 2).
2. On the box, with the MCP server running (see below), register it in
   Open WebUI as **MCP (Streamable HTTP)** and watch the MCP server's log:
   - **Fixed:** you'll see a `POST /mcp` initialize + `tools/list`, and the
     tools appear.
   - **Still broken:** you'll see `GET /mcp → 406` and/or
     `GET /mcp/openapi.json → 404`, and no tools load (the current
     behavior).

## The switch itself (transport change, not a rewrite)

The tool *logic* is identical between the two servers, so switching is
purely a transport/registration change:

1. **Bring up the MCP server** (from the `broken-mcp` branch):
   ```
   git checkout broken-mcp -- mcp/          # or merge mcp/ to main
   python3 -m venv /opt/sovereign-sigint/venvs/mcp
   /opt/sovereign-sigint/venvs/mcp/bin/pip install -r mcp/requirements.txt
   SIGINT_MCP_HOST=0.0.0.0 /opt/sovereign-sigint/venvs/mcp/bin/python \
       mcp/sigint_mcp_server.py
   ```
   (Same DB path env var, `SIGINT_OCCUPANCY_DB`, applies to both servers.)

2. **Register in Open WebUI** as **MCP (Streamable HTTP)**, URL
   `http://host.containers.internal:8130/mcp`, Auth None. Confirm the 3
   tools load (per the check above).

3. **Retire the OpenAPI server:** stop its service, remove its Open WebUI
   OpenAPI tool-server registration. Both bind :8130 by default, so you
   can't run both at once on the same port — stop one before starting the
   other, or give them different ports during a transition.

4. **Optional:** fold `mcp/` back into `main` and update
   `docs/mcp-server-security-requirements.md`'s status banner (it currently
   says "parked").

## Keeping the two in sync meanwhile

If you change tool logic (add a tool, change validation), update BOTH
implementations so the eventual switch stays a no-op on behavior. The
files are structured to make this easy — same helpers, same validation,
same queries; only the framework decorators and the transport differ.
