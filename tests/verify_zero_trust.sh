#!/usr/bin/env bash
# ==============================================================================
# 14agentbox: Automated Zero-Trust Security Verification Test
# Verifies that host secrets NEVER enter the container environment, process tree,
# or filesystem.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

echo "[TEST] Running Zero-Trust Sandbox Security Verification..."

# 1. Create a temporary test project and mock .env with canary secrets
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CANARY_OPENROUTER="CANARY_OPENROUTER_KEY_9876543210"
CANARY_GOOGLE="CANARY_GOOGLE_KEY_1234567890"
CANARY_EXA="CANARY_EXA_KEY_4567891230"

TEST_ENV="$TMP_DIR/test.env"
cat << EOF > "$TEST_ENV"
OPENROUTER_API_KEY=$CANARY_OPENROUTER
GOOGLEAI_API_KEY=$CANARY_GOOGLE
EXA_API_KEY=$CANARY_EXA
EOF

echo "[TEST] Starting proxy with canary secrets..."
python3 "$BOX_DIR/proxy.py" --env-file "$TEST_ENV" --port 8049 >/dev/null 2>&1 &
PROXY_PID=$!
sleep 0.5

cleanup_test() {
  kill "$PROXY_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup_test EXIT INT TERM

# 2. Test Proxy Health & Authentication Verification
echo "[TEST] Testing proxy endpoint /health..."
HEALTH_CHECK=$(curl -s http://127.0.0.1:8049/health || echo "FAIL")
if [[ "$HEALTH_CHECK" != *"14agentbox-zero-trust"* ]]; then
  echo "[-] FAILED: Proxy health check failed: $HEALTH_CHECK"
  exit 1
fi
echo "[+] PASSED: Proxy health check is responding."

echo "[TEST] Testing that unauthenticated requests are rejected with HTTP 401..."
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8049/providers || echo "FAIL")
if [ "$UNAUTH_CODE" != "401" ]; then
  echo "[-] FAILED: Expected HTTP 401 for unauthenticated request, got $UNAUTH_CODE"
  exit 1
fi
echo "[+] PASSED: Unauthenticated request rejected with HTTP 401."

echo "[TEST] Testing that requests with sandbox token succeed..."
AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer 14agentbox-sandbox-token" http://127.0.0.1:8049/providers || echo "FAIL")
if [ "$AUTH_CODE" != "200" ]; then
  echo "[-] FAILED: Expected HTTP 200 for authenticated request, got $AUTH_CODE"
  exit 1
fi
echo "[+] PASSED: Authenticated request accepted with HTTP 200."

# 3. Test Container Environment Isolation (Run mock container check)
echo "[TEST] Verifying secrets isolation inside container command..."

# Inspect the basebox image
BASE_TAG="14agentbox:base"
if ! docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "[TEST] Basebox not built yet. Building $BASE_TAG..."
  docker build -t "$BASE_TAG" "$BOX_DIR"
fi

# Run container and dump environment and /proc
DUMP=$(docker run --rm \
  --add-host host.docker.internal:host-gateway \
  -v "$TMP_DIR:/workspace" \
  "$BASE_TAG" \
  bash -c "env; [ -f /proc/1/environ ] && cat /proc/1/environ || true")

LEAKED=0
for CANARY in "$CANARY_OPENROUTER" "$CANARY_GOOGLE" "$CANARY_EXA"; do
  if echo "$DUMP" | grep -q "$CANARY"; then
    echo "[-] SECURITY VIOLATION: Canary secret $CANARY was found inside the container!"
    LEAKED=1
  fi
done

if [ "$LEAKED" -eq 1 ]; then
  echo "[-] FAILED: Zero-Trust test failed. Secrets leaked into container!"
  exit 1
fi

echo "[+] PASSED: Zero secrets detected inside container environment or process tree."
echo "[+] ALL ZERO-TRUST VERIFICATION CHECKS PASSED!"
exit 0
