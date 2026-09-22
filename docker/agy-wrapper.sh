#!/usr/bin/env bash
# Antigravity CLI wrapper
# Automatically runs agy / antigravity in YOLO mode (--dangerously-skip-permissions)
# inside the developer container unless explicitly overridden.

REAL_AGY="/usr/local/bin/agy-bin"

# Subcommands that use custom flag parsers and do not accept --dangerously-skip-permissions
SUBCOMMANDS=" agent agents changelog help install mcp mic-serve models plugin plugins remote-control update "

is_subcommand() {
    local cmd="$1"
    [[ "$SUBCOMMANDS" =~ " $cmd " ]]
}

args=()
yolo_disabled=false
has_yolo_flag=false

# Allow opting out via environment variable (e.g. ANTIGRAVITY_YOLO=0 or AGY_YOLO=false)
if [ "${ANTIGRAVITY_YOLO:-${AGY_YOLO:-1}}" = "0" ] || [ "${ANTIGRAVITY_YOLO:-${AGY_YOLO:-1}}" = "false" ]; then
    yolo_disabled=true
fi

for arg in "$@"; do
    if [ "$arg" = "--no-yolo" ]; then
        yolo_disabled=true
    elif [ "$arg" = "--dangerously-skip-permissions" ]; then
        has_yolo_flag=true
        args+=("$arg")
    else
        args+=("$arg")
    fi
done

# If YOLO is disabled or flag already provided, run as-is
if [ "$yolo_disabled" = true ] || [ "$has_yolo_flag" = true ]; then
    exec "$REAL_AGY" "${args[@]}"
fi

# If the first argument is a subcommand or help/version, do not inject the flag
if [ ${#args[@]} -gt 0 ]; then
    case "${args[0]}" in
        -h|--help|-v|--version)
            exec "$REAL_AGY" "${args[@]}"
            ;;
        *)
            if is_subcommand "${args[0]}"; then
                exec "$REAL_AGY" "${args[@]}"
            fi
            ;;
    esac
fi

# Run in YOLO mode (auto-approve all tool permission requests)
exec "$REAL_AGY" --dangerously-skip-permissions "${args[@]}"
