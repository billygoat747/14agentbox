
# 14agentbox: restore the terminal after full-screen TUIs (opencode, agy) exit.
# They can leave the alternate screen, mouse tracking, or hidden cursor enabled,
# and late replies to their terminal queries get echoed at the shell prompt.
__14agentbox_tui() {
    command "$@"
    local rc=$?
    printf '\e[?1049l\e[?25h\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
    stty sane 2>/dev/null
    while read -r -s -t 0.05 -n 1024 _; do :; done
    clear
    return $rc
}

opencode() { __14agentbox_tui opencode "$@"; }
agy() { __14agentbox_tui agy "$@"; }
antigravity() { __14agentbox_tui antigravity "$@"; }
