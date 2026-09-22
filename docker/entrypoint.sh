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

# 4. Provider availability & LiteLLM model discovery (OpenCode)
# The host proxy reports which providers have a key in the host .env (booleans
# only). Providers without a key are disabled, and LiteLLM's chat models are
# listed from its /model/info endpoint so new models appear without a rebuild.
# If the proxy is unreachable (e.g. --direct-env), the baked-in config is used.
PROXY_URL="${AGENTBOX_PROXY_URL:-http://host.docker.internal:8040}"
BASE_CONFIG=/home/dev/.config/opencode/opencode.json
GEN_CONFIG=/home/dev/.config/opencode/generated.json
# Responses go through temp files: /model/info can be hundreds of KB, which
# exceeds Linux's 128 KB limit for a single command-line argument.
DISCOVERY_DIR=$(mktemp -d)
if curl -fsS -m 3 -o "$DISCOVERY_DIR/providers.json" "$PROXY_URL/providers" 2>/dev/null; then
    if [ "$(jq -r '.providers.litellm' "$DISCOVERY_DIR/providers.json")" != "true" ] \
        || ! curl -fsS -m 10 -o "$DISCOVERY_DIR/model_info.json" "$PROXY_URL/litellm/model/info" 2>/dev/null; then
        echo '{"data":[]}' > "$DISCOVERY_DIR/model_info.json"
    fi
    if jq -n --slurpfile p "$DISCOVERY_DIR/providers.json" --slurpfile info "$DISCOVERY_DIR/model_info.json" --slurpfile base "$BASE_CONFIG" '
        $p[0].providers as $keys
        | [($info[0].data // [])[] | select(.model_info.mode == "chat")] as $chat
        | ([$keys | to_entries[] | select(.key != "exa" and .value != true) | .key]
           + ["opencode"]
           + (if ($chat | length) == 0 then ["litellm"] else [] end) | unique) as $disabled
        | {
            disabled_providers: $disabled,
            provider: { litellm: { models: ($chat | map({
                key: .model_name,
                value: {
                    name: .model_name,
                    tool_call: (.model_info.supports_function_calling // false),
                    reasoning: (.model_info.supports_reasoning // false),
                    attachment: (.model_info.supports_vision // false),
                    limit: {
                        context: (.model_info.max_input_tokens // 128000),
                        output: (.model_info.max_output_tokens // 4096)
                    }
                }
            }) | from_entries) } },
            mcp: { exa: { enabled: ($keys.exa == true) } }
          }
        | (($base[0].model // "") | split("/")[0]) as $default_provider
        | if ($disabled | index($default_provider)) and ($chat | length) > 0 then
              .model = "litellm/" + ((first($chat[] | select(.model_name | test("sonnet"))) // $chat[0]).model_name)
          else . end
    ' > "$GEN_CONFIG" 2>/dev/null; then
        export OPENCODE_CONFIG="$GEN_CONFIG"
    else
        rm -f "$GEN_CONFIG"
    fi
fi
rm -rf "$DISCOVERY_DIR"

exec "$@"
