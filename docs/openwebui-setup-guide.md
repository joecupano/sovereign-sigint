# Setting Up Open WebUI — The Sovereign AI Front End

Open WebUI is the chat interface for this build's local AI: it talks to the
local Ollama models and hosts the **native tools** that let the model query
your own SIGINT data (occupancy, Kismet, SigID). Every other AI guide in this
repo assumes Open WebUI is up and a tool is installed the way this guide
describes. Start here.

This guide has two parts:
1. **Foundational setup** — first run, models, orientation (do once).
2. **Installing a native tool** (the section starting at *"## Installing a
   Native Tool"*) — the repeatable procedure the occupancy, Kismet, and SigID
   guides link to. If you already have Open WebUI running and just need to add
   a tool, jump there.

---

## What's already running (this build's layout)

By the time you reach this guide, the earlier phases have Open WebUI running as
a rootless Podman container (a systemd **quadlet**), bound to loopback
`127.0.0.1:8080`, with **Caddy** as the LAN/TLS-facing entry point in front of
it. The container reaches the host's **Ollama** (the model runtime) via
`host.containers.internal:11434`. You don't manage these by hand per session —
they start on boot. To reach the UI, browse to the Caddy address for the box
(see `docs/openwebrx-sdr-quickstart.md` / your Caddyfile for the exact
hostname); on the box itself `http://localhost:8080` also works.

If the UI doesn't load: `systemctl --user status open-webui` and
`systemctl --user status caddy`.

## Step 1 — First-run: create the admin account

The **first** account created on a fresh Open WebUI becomes the administrator.
On a sovereign single-operator box this is you.

1. Browse to the UI. You'll get a sign-up screen (not a login).
2. Create your account — name, email (any address; it's a local identifier,
   not verified against anything external), password.
3. That account now has admin rights (**Admin Panel** in the user menu).

Because this is local-first, there's no cloud account and no external
verification — the "email" is just your local login. Keep the password in your
password manager; there's no reset-by-email here.

## Step 2 — Confirm Ollama is connected and pull the models

Open WebUI needs to see Ollama and have the models this build uses:

- **`qwen3:14b`** — general reasoning **and tool calling** (a newer, capable
  model that can drive the native SIGINT tools).
- **`llama3-groq-tool-use:8b`** — a smaller (~4.7GB) model fine-tuned
  specifically for reliable **tool/function calling**. The SIGINT native tools
  were proven reliable against this in the working build. It's older (Llama 3,
  Jul 2024) but purpose-built for tools — try it and `qwen3:14b` for the
  tool-driving role and keep whichever invokes the tools more reliably in your
  setup.
- **`gemma3:12b`** — **vision** (reads waterfall images; see the vision guide).
  Note: it does **not** support tool calling — this is why the vision workflow
  switches models between the image step and the tool-lookup step.
- **`nomic-embed-text`** — embeddings (for the RAG/Knowledge feature).

**Which tool model? (measured on this build).** Both `qwen3:14b` and
`llama3-groq-tool-use:8b` were tested against all three SIGINT tools
(occupancy, Kismet, SigID — every function) on the fresh build. **Both fire the
tools reliably** once the tool is enabled for the conversation (see step E
below — an earlier apparent groq failure was just a disabled integration, not
the model). The only consistent difference is style and speed:

| | `llama3-groq-tool-use:8b` | `qwen3:14b` |
|---|---|---|
| Fires all tools | yes | yes |
| Speed | faster | slower |
| Size | 4.7 GB | 9.3 GB |
| Response style | terse, gets to the result | verbose, reasons about the result and suggests next steps |

Neither is "better" — pick per preference. `groq-tool-use` suits fast
operational queries; `qwen3:14b` suits interpretation/teaching (it explains an
empty result and what to check). Both are kept in this build (`TOOL_MODEL=skip`
in phase 3 omits the groq model if you only want qwen3). Note `groq-tool-use`
is older (Llama 3, Jul 2024) and occasionally needs more explicit phrasing
(e.g. "use the tool now with no arguments") where qwen3 fires on a plain
request.

Check the connection: **Admin Panel → Settings → Connections** should list the
Ollama endpoint (`http://host.containers.internal:11434`) as reachable. If it
isn't, the container can't see host Ollama — verify Ollama is running on the
host and the quadlet's `OLLAMA_BASE_URL` / `--add-host` are intact.

Pull the models (either from the UI or on the host). On the host it's simplest:

```
ollama pull qwen3:14b
ollama pull llama3-groq-tool-use:8b
ollama pull gemma3:12b
ollama pull nomic-embed-text
```

They'll then appear in Open WebUI's model selector. (In the UI you can also
pull via **Admin Panel → Settings → Models**.) When you register a Workspace
model for tool use (Step D under "Installing a Native Tool"), base it on
whichever of `qwen3:14b` or `llama3-groq-tool-use:8b` invokes your tools more
reliably.

## Step 3 — Orientation: where things live

Two menus matter for this build:

- **Workspace** (left sidebar) → **Models**, **Tools**, **Knowledge**. This is
  where you register a model for tool use, install native tools, and manage
  RAG collections.
- **Admin Panel** (user menu) → **Settings** → **Connections / Models / Tools**
  — server-wide configuration.

The chat view has a **model selector** (top) and, once a tool is enabled, a
**tools/wrench icon** near the message box.

---

## Installing a Native Tool

*(This is the reusable procedure the occupancy, Kismet, and SigID guides point
to. It captures the setup that was learned the hard way — follow it exactly and
tools will fire; skip a step and they silently won't.)*

A "native tool" here is one of this repo's Python files in `openwebui-tools/`
that runs **in-process inside Open WebUI** and reads your data directly. Native
in-process tools are the reliable path for local models — external HTTP/OpenAPI
tools proved unreliable to invoke (see `docs/db-to-ai-query-path.md`).

### A. Make sure the tool can see its data (the mount)

Open WebUI tools run **inside the container**, so whatever file the tool reads
must be mounted into the container via a `Volume=` entry in the quadlet
(`~/.config/containers/systemd/open-webui.container`). The three tools' mounts:

```
# occupancy — NOTE: plain read-write mount, NOT :ro. The occupancy DB is a
# live WAL database; a :ro mount can't touch the required -wal/-shm sidecars.
# The tool enforces read-only at the query level (PRAGMA query_only=ON) instead.
Volume=%h/sovereign-sigint/db:/data/sigint

# Kismet — ALSO read-write (NOT :ro), same reason: a .kismet file is a live
# SQLite/WAL database and needs the dir writable for its -wal/-shm sidecars.
# The tool is read-only at the query level. Path must match where the
# kismet-refresh timer writes (scripts/kismet-refresh.sh, installed by
# scripts/phase7-kismet-refresh.sh). Do NOT use ~/kismet-captures — that
# was an earlier scratch path that never got wired to the refresh producer;
# using it here leaves the container mounting an empty file and every
# kismet_summary call reports 0 devices, silently.
Volume=%h/sovereign-sigint/kismet-data:/data/kismet

# SigID reference — :ro IS correct here. Unlike the two above, this is a static
# directory of JSON files (the mirror), read-only to the tool; the mirror timer
# writes it on the host side, the tool only reads.
# NOTE: the mirror lives under /data, which setup-data-dirs.sh locks to o-rwx.
# The tool runs in the container as a NON-owner UID, so this path must be
# world-readable or the tool gets permission-denied. setup-data-dirs.sh opens
# it automatically (SigID is public reference data); if you built the tree by
# hand: sudo chmod o+x /data /data/reference && chmod -R o+rX /data/reference/sigid
Volume=/data/reference/sigid:/data/sigid-ref:ro
```

After editing, reload and restart:

```
systemctl --user daemon-reload
systemctl --user restart open-webui
```

Confirm from inside the container, e.g.:
`podman exec open-webui ls -la /data/sigint/`. If the path isn't
visible there, the tool cannot work no matter how it's configured.

**Early-install note (before Phase 6):** the occupancy DB and the SigID mirror
are populated by later phases, but you can install and test the *tools* before
that. `scripts/setup-data-dirs.sh` pre-creates an empty, schema-valid
`occupancy.db`, so the occupancy tool opens it cleanly and returns "no signals
recorded" rather than a file error — a clean way to verify tool *invocation*
before real data exists. The SigID and Kismet tools will return empty until
their sources are synced/captured; that's expected at this stage and still
confirms the tool fires.

### B. Install the tool file

1. Get the tool's code: `cat openwebui-tools/<tool>.py` (or open it on GitHub).
2. In the UI: **Workspace → Tools → "+" (Create New Tool)**.
3. Paste the entire file. The name/description auto-fill from the file header.
4. **Save**.

### C. Set the tool's valve (its data path)

Each tool exposes a **Valve** — the path to its data *as seen inside the
container*. Open the tool's valve settings and confirm it matches the mount
(e.g. occupancy → `/data/sigint/occupancy.db`, Kismet →
`/data/kismet/latest.kismet`, SigID → `/data/sigid-ref/metadata`). The
defaults are set to match this build's mounts, so usually there's nothing to
change — just confirm.

### D. Register a tool-capable Workspace model

A raw Ollama model selected straight from the dropdown has **no tool
configuration surface** — so create a Workspace model entry for tool use:

1. **Workspace → Models → "+"** (or edit an existing entry). Base it on
   **`qwen3:14b`** (a tool-capable model — **not** `gemma3:12b`, which can't
   call tools).
2. In that model entry, **untick the built-in capabilities** (the default
   notes/calendar/etc. tool features). Left on, they can crowd out your custom
   tool.
3. Set **Function Calling = Native**. This is the setting that makes local
   models reliably invoke tools.
4. **Optional — attach the tool here** (check your installed SIGINT tool[s]).
   Attaching at the model level makes the tool available **by default in every
   chat** with this model. This is a convenience, **not** required: you can
   instead (or additionally) enable the tool per-conversation via Integrations
   (step E). Either path works — attaching here just saves you toggling it in
   each new chat.
5. **Save**.

### E. Enable the tool IN THE CHAT (Integrations) — required unless attached in D

If you did **not** attach the tool at the model level (D step 4), enabling it
here is **required** — Open WebUI gates tools per-conversation. In the chat,
open the **Integrations** control (a toggle/menu near the message box — some
versions show a wrench/tools icon) and turn **on** your SIGINT tool for that
conversation. If no tool is active for the chat (neither attached in D nor
toggled on here), the model genuinely has no access and will say so — *"I don't
have access to functions like query_occupancy…"* — which looks exactly like a
model that can't call tools but is really just a tool that isn't enabled for the
conversation. Turn it on and the same model fires the tool immediately. (If you
DID attach it in D, it's already on by default here — but you can confirm via
the same control.)

### F. Verify it fires

Start a new chat, select your Workspace model, **enable the tool via
Integrations** (step E), and give a **direct, explicit** instruction — this
phrasing triggers tool calls far more reliably than a terse question:

> Call radiod_status and report the totals.

When it works you'll see **"View Result from radiod_status"** (or the relevant
tool) appear, followed by the model answering from real data. If instead it
describes what it *would* do, or says it lacks the capability:

- **First check the chat's Integrations toggle (E)** — a tool not enabled for
  the conversation is the most common cause of "I don't have access to that
  function." The tool must be either attached at the model level (D) OR toggled
  on in the chat (E) — if neither, the model can't see it.
- Re-check **D** — is the model a Workspace entry, built-ins unticked, Function
  Calling = Native?
- Ask *"What tools do you have available?"* — if it lists nothing, the tool
  isn't reaching the chat (not enabled in E and not attached in D). If it lists
  the tool but won't call it, use the explicit "Call X …" phrasing.
- If the tool **fires but errors** about opening its data, it's the **mount**
  (A) or the **valve** (C), not the tool.

### Common gotchas (learned building this)

- **`gemma3:12b` can't call tools at all** — a real Ollama limitation, not a
  misconfiguration. Use `qwen3:14b` for anything with tools; use `gemma3:12b`
  only for image turns (see the vision guide's two-model workflow).
- **Built-in capabilities left ticked** silently suppress custom tools — untick
  them.
- **Terse questions don't trigger tools reliably** — "Call `<tool>` and report
  …" does.
- **A tool that never worked after install** is almost always not enabled for
  the conversation — either attach it to the Workspace model (D) or toggle it on
  in the chat's Integrations (E). It's rarely the tool code.

---

## The tools this build installs

Install each via the procedure above; each linked doc gives its mount line and
example queries.

- **Occupancy** — `sovereign_sigint_occupancy_tool.py`. What's active on the RF
  bands, from your SDRs. See `docs/db-to-ai-query-path.md`.
- **Kismet** — `sovereign_sigint_kismet_tool.py`. WiFi devices seen. See
  `docs/kismet-to-ai-bridge.md`.
- **SigID reference** — `sovereign_sigid_reference_tool.py`. What a signal *is*,
  from the mirrored catalog. See the vision guide for the identification
  workflow that ties it together.

## Optional: the Knowledge (RAG) feature

Separate from native tools, Open WebUI's **Knowledge** feature does
retrieval-augmented generation over uploaded documents (using
`nomic-embed-text`). That has its own walkthrough in
`docs/rag-knowledge-base-guide.md`; the native tools above are the live-query
path and are generally preferable for this build's own data.
