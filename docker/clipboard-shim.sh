#!/usr/bin/env bash
# 14agentbox clipboard bridge (installed as 14agentbox-copy, xclip, xsel, wl-copy, wl-paste).
# Copies stdin to the HOST clipboard via the host proxy's /clipboard route.
# Write-only by design: reading the host clipboard would let the sandbox
# exfiltrate whatever the user copies on the host (e.g. passwords).

name="$(basename "$0")"

deny_read() {
    echo "[14agentbox] $name: host clipboard read is disabled (write-only bridge)" >&2
    exit 1
}

[ "$name" = "wl-paste" ] && deny_read
for arg in "$@"; do
    case "$arg" in
        -o|-out|-output|--output) deny_read ;;
    esac
done

if [ -z "${AGENTBOX_CLIPBOARD_TOKEN:-}" ]; then
    echo "[14agentbox] $name: clipboard bridge unavailable (no host proxy for this session)" >&2
    cat >/dev/null
    exit 1
fi

PROXY_URL="${AGENTBOX_PROXY_URL:-http://host.docker.internal:8040}"
if ! curl -fsS -m 5 -o /dev/null -X POST \
    -H "X-Clipboard-Token: $AGENTBOX_CLIPBOARD_TOKEN" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary @- "$PROXY_URL/clipboard"; then
    echo "[14agentbox] $name: failed to copy to host clipboard" >&2
    exit 1
fi
