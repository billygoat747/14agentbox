# 14agentbox Agent Instructions & Architecture Contract

Welcome, agent! You are working on **`14agentbox`**, a centralized, language-agnostic development container harness designed to run AI coding agents (OpenCode, Antigravity CLI) and developers safely across multiple projects.

This repository enforces a **True Zero-Trust Sandbox**. When modifying or extending this codebase, you **MUST** strictly adhere to the security invariants below.

---

## 🔒 The Zero-Trust Security Contract

### 1. The Golden Invariant: Host-Only Secrets
**NEVER pass real API keys into Docker.**
- Do **NOT** pass API keys via `-e OPENROUTER_API_KEY=...` or `-e OPENAI_API_KEY=...`.
- Do **NOT** use `--env-file` pointing to `.env` when launching `docker run`.
- Do **NOT** mount `14agentbox/.env` (or any file containing raw API keys) into `/workspace` or anywhere inside the container.
- Do **NOT** pass API keys via Docker `--build-arg`.

**Rationale**: Any script, build step, tool, or prompt injection executed inside the container in YOLO mode can inspect `env`, `/proc/*/environ`, or the filesystem. If real keys are present in the container, they can be exfiltrated.

### 2. Out-of-Band Auth via `proxy.py`
All authenticated outbound LLM and MCP requests from inside the container **MUST** go through the local host proxy (`proxy.py`), which listens on `127.0.0.1:8040` (accessible from Docker as `host.docker.internal:8040`).
- The host proxy reads the real keys from `14agentbox/.env`.
- Inside the container, tool configurations (e.g. `opencode.json` and MCP configs) point to `http://host.docker.internal:8040/<provider>/...` with a dummy token (e.g. `"14agentbox-sandbox-token"`).
- The proxy intercepts the request and injects the real `Authorization: Bearer <KEY>`, `x-api-key`, or `x-goog-api-key` headers before forwarding over HTTPS to the actual provider.
- Inside the container, the real keys **do not exist** in memory, environment, or disk.

---

## 📋 Checklist: Adding a New Provider or Secret

If you are tasked with adding support for a new provider (e.g. Anthropic, Mistral, Groq, or a new MCP server):

1. **Add the environment variable template**:
   Update `14agentbox/.env.example` with the new variable name (e.g. `ANTHROPIC_API_KEY=`).

2. **Add the forwarder route in `14agentbox/proxy.py`**:
   Add a path handler in `proxy.py` that strips the dummy token and injects the real key from the host `.env`:
   ```python
   # Example in proxy.py:
   if path.startswith("/anthropic/"):
       # Route to https://api.anthropic.com
       forward_target = "https://api.anthropic.com" + path[len("/anthropic"):]
       headers["x-api-key"] = os.getenv("ANTHROPIC_API_KEY", "")
   ```

3. **Configure the Container Tool (`opencode.json` / MCP config)**:
   Point the tool's `baseURL` to `http://host.docker.internal:8040/<provider>` with a dummy API key:
   ```json
   "anthropic": {
     "options": {
       "baseURL": "http://host.docker.internal:8040/anthropic/v1",
       "apiKey": "14agentbox-sandbox-token"
     }
   }
   ```

4. **Run the Guardrail Test**:
   Execute `./tests/verify_zero_trust.sh`. Ensure that **zero secrets** are exposed to `env` or `/proc` inside the container.

---

## 🏗️ Architecture Invariants

1. **Basebox Persistence (`14agentbox:base`)**:
   - The base image `Dockerfile` installs only universal OS tools, OpenCode, and Antigravity CLI.
   - **Never install project-specific language runtimes** (Go, Node, Python pip packages, Java, PostgreSQL) into `14agentbox:base`.
   - Projects add their own runtimes via `14agentbox.Dockerfile` in their own repository.
2. **Deterministic Smart Caching**:
   - The basebox image is tagged `14agentbox:base-${AGENTBOX_COMMIT}`.
   - Project images are tagged `14agentbox-${PROJECT_NAME}:${AGENTBOX_COMMIT}-${DOCKERFILE_HASH}`.
   - When unchanged, the runner reuses existing images instantly (0s build time).
3. **Explicit Project Mappings**:
   - The base runner contains no hardcoded ports or network bridges.
   - Downstream projects declare explicit ports, networks, and forwardings in `14agentbox.json`.
4. **Session Persistence**:
   - Host session cache persists `~/.local` and `~/.gemini` keyed by `(canonical project path + git branch)`.
   - Never write agent state into project git trees.
5. **Ephemeral Teardown**:
   - Containers run with `--rm`. On exit, the container is destroyed immediately.
