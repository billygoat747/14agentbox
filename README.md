# 14agentbox

**`14agentbox`** is a centralized development container harness for running autonomous AI agents (Google Antigravity CLI in YOLO mode, OpenCode) and developers safely across multiple projects without duplicating container configurations or leaking host credentials.

---

## 🚀 Quickstart

### 1. Configure Host Secrets
Clone `14agentbox` and configure your API keys on the host:
```bash
cp .env.example .env
# Add your OPENROUTER_API_KEY, GOOGLEAI_API_KEY, and/or EXA_API_KEY
```

> **🔒 True Zero-Trust Guarantee**: Secrets in `.env` are read **exclusively on the host machine** by `proxy.py`. They are **never** passed into Docker or accessible by tools running inside the container.

### 2. (Optional) Install Globally to Run from Anywhere
To run `14agentbox` from any folder on your Mac without specifying the path:
```bash
ln -s "$(pwd)/14agentbox" ~/.local/bin/14agentbox
# or system-wide:
# sudo ln -s "$(pwd)/14agentbox" /usr/local/bin/14agentbox
```

### 3. Run against Any Project
Pass the target project path to the `14agentbox` runner:

```bash
# From anywhere (if symlinked into PATH):
14agentbox /path/to/my-project
# or simply cd into the project and run:
cd /path/to/my-project && 14agentbox

# Or run directly from this repository:
./14agentbox /path/to/my-project

# Windows PowerShell
.\14agentbox.ps1 -TargetDir "C:\path\to\my-project"
```

Running with no command automatically drops into an interactive `bash` shell inside the project workspace. When you exit, the container is destroyed immediately (`--rm`).

To launch an agent directly:
```bash
./14agentbox /path/to/my-project agy        # Starts Antigravity CLI in YOLO mode
./14agentbox /path/to/my-project opencode   # Starts OpenCode agent
```

---

## 🏗️ The Basebox Hierarchy

1. **Persistent Basebox (`14agentbox:base`)**:
   Built once globally. Contains Ubuntu 24.04, core system utilities, OpenCode, Antigravity CLI with YOLO mode auto-approvals, and user permissions.
   *As long as `14agentbox` does not change, this image is never rebuilt.*
2. **Project Delta Images (`14agentbox-<project>:<hash>`)**:
   Projects that need specific Linux libraries, compilers, or tools add a `14agentbox.Dockerfile` starting with `FROM ${BASE_IMAGE}`.
   Docker builds only the project delta (~15 seconds on first run, 0 seconds on subsequent runs).

---

## 🛠️ Downstream Customization: `14agentbox.Dockerfile`

To add compilers, language runtimes, or Linux libraries to a project, create a `14agentbox.Dockerfile` in that project's root:

### Java & Maven Example
```dockerfile
ARG BASE_IMAGE=14agentbox:base
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk \
    maven \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    PATH="/usr/lib/jvm/java-21-openjdk-amd64/bin:${PATH}"

USER dev
```

### Go & Node.js Example (like 14software)
```dockerfile
ARG BASE_IMAGE=14agentbox:base
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential nodejs npm postgresql-client python3 python3-pip lsof \
    && rm -rf /var/lib/apt/lists/*

ARG GO_VERSION=1.24.1
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz

ENV PATH="/usr/local/go/bin:/home/dev/go/bin:${PATH}" GOTOOLCHAIN="auto"

USER dev
```

---

## 🌐 Explicit Network & Port Mapping: `14agentbox.json`

Downstream projects declare their network attachments, container links, and port bindings in `14agentbox.json`.

You can scaffold a pre-configured template using `--init`:

```bash
# In the current directory:
14agentbox --init

# Or targeting a specific folder:
14agentbox --init /path/to/my-project
# (Windows: .\14agentbox.ps1 -Init -TargetDir "C:\path\to\my-project")
```

Example `14agentbox.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/billygoat747/14agentbox/main/14agentbox.schema.json",
  "ports": [
    "8080-8086:8080-8086"
  ],
  "network": "14software_default",
  "compose_services": [
    "postgres"
  ],
  "links": [
    "14software-postgres:postgres"
  ],
  "forward_ports": [
    "5432:postgres:5432"
  ],
  "env": {
    "DATABASE_HOST": "postgres",
    "PGHOST": "postgres"
  }
}
```

- `"$schema"`: Points to the official JSON schema so IDEs and AI coding agents get immediate autocompletion and type validation.
- `"ports"`: Exposed host ports (`-p`).
- `"network"`: Connects to the project's Docker network (e.g. from `docker compose up -d`).
- `"compose_services"`: Compose services to start before launching the devbox, and stop on exit.
- `"forward_ports"`: Starts explicit intra-container port forwarders (e.g. `127.0.0.1:5432 -> postgres:5432`).

---

## 💾 Host Session Caching

Agent chat memory, transcripts, and history are cached on the host per folder path and Git branch:
- macOS/Linux: `~/.14agentbox/sessions/<name>-<hash>/<branch>/`
- Windows: `%USERPROFILE%\.14agentbox\sessions\<name>-<hash>\<branch>\`

To clean a project's session cache:
```bash
./14agentbox --clean /path/to/project
```
To list all active sessions on disk:
```bash
./14agentbox --sessions
```

---

## 🔒 Security & Guardrails

See [AGENTS.md](AGENTS.md) and [ARCHITECTURE.md](ARCHITECTURE.md) for full security invariants.
To run the automated Zero-Trust leak test:
```bash
./tests/verify_zero_trust.sh
```
