# 14agentbox Architecture & Design Specification

## Overview

**`14agentbox`** is a centralized development container harness for running AI coding agents (OpenCode, Google Antigravity CLI) and developers safely across multiple projects without duplicating container configurations or leaking host credentials.

---

## 1. System Layers

```
+-----------------------------------------------------------------------------------+
| Host Machine (macOS / Windows / Linux)                                            |
|                                                                                   |
|  [ 14agentbox Runner CLI (bash / ps1) ]                                           |
|       |                                                                           |
|       +--> [ proxy.py (127.0.0.1:8040) ] <--- Reads 14agentbox/.env (HOST ONLY)   |
|       |                                                                           |
|       +--> [ Session Cache ] (~/.14agentbox/sessions/<slug>-<path-hash>/<branch>/)|
|                 |--> opencode/      (bind-mounted to /home/dev/.local)            |
|                 |--> antigravity/   (bind-mounted to /home/dev/.gemini)           |
|                 +--> bash_history   (bind-mounted to /home/dev/.bash_history)     |
+-----------------------------------------------------------------------------------+
                                         |
               (Docker run -v /workspace -p ... --network ...)
                                         v
+-----------------------------------------------------------------------------------+
| Docker Engine                                                                     |
|                                                                                   |
|   Level 0: Basebox Image (14agentbox:base-<commit>)                               |
|   Ubuntu 24.04 + curl, git, jq, sudo + OpenCode + Antigravity CLI (YOLO)          |
|   Built once globally. Cached permanently.                                        |
|                                                                                   |
|   Level 1: Project-Derived Image (14agentbox-<project>:<commit>-<dockerfile-hash>)|
|   FROM 14agentbox:base-<commit>                                                   |
|   Adds only project-specific runtimes (e.g. Go, Node, psql for 14software).        |
|   Cached by Dockerfile SHA-256. Delta build takes ~15-30s on first run, 0s after. |
|                                                                                   |
|   Level 2: Ephemeral Running Container (devbox-<project>-<branch>-<pid>)          |
|   - Workspace: Mounts target project directory to /workspace                      |
|   - Zero-Trust: Real API keys NEVER enter the container                          |
|   - Networking: Explicit ports, docker networks, and forwardings from             |
|                 project-level 14agentbox.json                                     |
|   - On exit: Automatically destroyed (--rm)                                       |
+-----------------------------------------------------------------------------------+
```

---

## 2. Image Hashing & Caching Algorithm

1. **Basebox Tag**:
   `BASE_TAG="14agentbox:base-${AGENTBOX_COMMIT}"`
   Where `AGENTBOX_COMMIT` is:
   - Git short commit hash of `14agentbox`: `git -C "$AGENTBOX_DIR" rev-parse --short HEAD`
   - Or fallback hash of `14agentbox/Dockerfile` if not inside a git repo.
   - If `docker image inspect "$BASE_TAG"` returns 0, basebox build is skipped.

2. **Project Derived Tag**:
   If `$PROJECT_DIR/14agentbox.Dockerfile` exists:
   - `DOCKERFILE_HASH=$(shasum -a 256 "$PROJECT_DIR/14agentbox.Dockerfile" | head -c 10)`
   - `IMAGE_TAG="14agentbox-${PROJECT_NAME}:${AGENTBOX_COMMIT}-${DOCKERFILE_HASH}"`
   - If `docker image inspect "$IMAGE_TAG"` returns 0:
     - Reuses image **instantly** (0s build time).
   - If not found:
     - Invokes `docker build --build-arg BASE_IMAGE="$BASE_TAG" -f "$PROJECT_DIR/14agentbox.Dockerfile" -t "$IMAGE_TAG" "$PROJECT_DIR"`.
   If no `14agentbox.Dockerfile` exists:
   - Uses `IMAGE_TAG="$BASE_TAG"`.

---

## 3. Session Caching (Folder + Git Branch)

To avoid polluting project git repositories with agent state files (`.opencode-state/`, `.antigravity-state/`), all state is stored on the host:

- **macOS / Linux**:
  `~/.14agentbox/sessions/${PROJECT_NAME}-${PATH_HASH}/${SAFE_BRANCH}/`
- **Windows**:
  `%USERPROFILE%\.14agentbox\sessions\${PROJECT_NAME}-${PATH_HASH}\${SAFE_BRANCH}\`

Where:
- `PATH_HASH` is a 10-character SHA-256 of the lowercased canonical absolute path.
- `SAFE_BRANCH` is the sanitized git branch name (alphanumeric, `_`, `.`, `-`).
- Mounts:
  - `<session>/opencode` -> `/home/dev/.local`
  - `<session>/antigravity` -> `/home/dev/.gemini`
  - `<session>/bash_history` -> `/home/dev/.bash_history`

---

## 4. Zero-Trust Credential Proxy (`proxy.py`)

The proxy runs on the host during container execution:
- Listens on `127.0.0.1:8040` (accessible to Docker via `host.docker.internal:8040`).
- Translates endpoints:
  - `/openrouter/*` -> `https://openrouter.ai/*` + `Authorization: Bearer <OPENROUTER_API_KEY>`
  - `/openai/*` -> `https://api.openai.com/*` + `Authorization: Bearer <OPENAI_API_KEY>`
  - `/litellm/*` -> `<LITELLM_BASE_URL>/*` + `Authorization: Bearer <LITELLM_API_KEY>` (the base URL is set in the host `.env`, so deployment-specific URLs stay out of git)
  - `/google/*` -> `https://generativelanguage.googleapis.com/*` + `x-goog-api-key: <GOOGLEAI_API_KEY>`
  - `/mcp/exa/*` -> `https://mcp.exa.ai/*` + `x-api-key: <EXA_API_KEY>`
- `/providers` reports which providers have a key in the host `.env` (booleans only, never key values).
- Supports streaming Server-Sent Events (SSE) for real-time LLM token delivery.

At container start, `docker/entrypoint.sh` queries `/providers` and LiteLLM's `/model/info`, then writes
`~/.config/opencode/generated.json` (exported as `OPENCODE_CONFIG`):
- Providers without a key are added to `disabled_providers`; the Exa MCP server is disabled without `EXA_API_KEY`.
- LiteLLM chat models (with context/output limits) are listed automatically, so new models appear without a rebuild.
- If the default model's provider is disabled, the default switches to LiteLLM, OpenAI (e.g. GPT-6 Luna), or Google based on which keys are configured.
- If the proxy is unreachable (e.g. `--direct-env`), the baked-in `opencode.json` is used unchanged.
- Shuts down when container execution terminates.

---

## 5. Explicit Project Network Mapping (`14agentbox.json`)

Projects specify their networking explicitly in `14agentbox.json`:
- `ports`: Array of `-p` host port bindings.
- `network`: Docker network name (`--network`).
- `links`: Array of `--link` bindings.
- `extra_hosts`: Array of `--add-host` bindings.
- `forward_ports`: Local intra-container port forwardings via `socat` (e.g. `5432:postgres:5432`).
- `env`: Key-value pairs passed as `-e`.
