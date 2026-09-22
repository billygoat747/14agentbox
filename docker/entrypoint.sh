#!/usr/bin/env bash
set -e

# 1. Ensure ~/.gemini/antigravity-cli/settings.json trusts /workspace by default
if [ ! -f /home/dev/.gemini/antigravity-cli/settings.json ]; then
    mkdir -p /home/dev/.gemini/antigravity-cli
    cat << 'EOF' > /home/dev/.gemini/antigravity-cli/settings.json
{
  "trustedWorkspaces": [
    "/workspace"
  ]
}
EOF
fi

# 2. Configure Exa MCP server via Zero-Trust Proxy
mkdir -p /home/dev/.gemini/config
if [ ! -s /home/dev/.gemini/config/mcp_config.json ]; then
    cat << 'EOF' > /home/dev/.gemini/config/mcp_config.json
{
  "mcpServers": {
    "exa": {
      "disabled": false,
      "serverUrl": "http://host.docker.internal:8040/mcp/exa"
    }
  }
}
EOF
fi

# 3. Explicit Intra-Container Port Forwarding
# Only started if downstream project config explicitly sets AGENTBOX_FORWARD_PORTS
# Format: "SRC_PORT:TARGET_HOST:TARGET_PORT,..." (e.g. "5432:postgres:5432")
if [ -n "${AGENTBOX_FORWARD_PORTS:-}" ]; then
    IFS=',' read -ra FORWARD_RULES <<< "$AGENTBOX_FORWARD_PORTS"
    for rule in "${FORWARD_RULES[@]}"; do
        rule="$(echo "$rule" | xargs)" # trim whitespace
        if [ -n "$rule" ]; then
            IFS=':' read -r src_port target_host target_port <<< "$rule"
            if [ -n "$src_port" ] && [ -n "$target_host" ] && [ -n "$target_port" ]; then
                # Only listen if not already bound
                if ! ss -tuln 2>/dev/null | grep -q ":${src_port} " && ! netstat -tuln 2>/dev/null | grep -q ":${src_port} "; then
                    echo "[14agentbox] Starting explicit port forward: 127.0.0.1:${src_port} -> ${target_host}:${target_port}"
                    socat "TCP-LISTEN:${src_port},fork,reuseaddr,bind=127.0.0.1" "TCP:${target_host}:${target_port}" 2>/dev/null &
                fi
            fi
        fi
    done
fi

exec "$@"
