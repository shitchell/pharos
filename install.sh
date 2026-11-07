#!/usr/bin/env bash
#
# Install or remove pharos for the current user.
#
#   ./install.sh                 install, set disableAutoMode, enable and start
#   ./install.sh --no-start      install and enable, but don't start now
#   ./install.sh --uninstall     stop (which cleanses), disable, remove the files
#
# Installs:
#   ~/.local/bin/claude-rc-service
#   ~/.config/systemd/user/claude-rc.service
# and sets permissions.disableAutoMode = "disable" in ~/.claude/settings.json.

set -euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "${0}")")" && pwd)
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
SETTINGS="${HOME}/.claude/settings.json"
UNIT=claude-rc.service

function say() { echo "pharos: ${*}"; }
function die() { echo "pharos: error: ${*}" >&2; exit 1; }

function require() {
    local missing=() tool
    for tool in bash jq curl systemctl flock; do
        command -v "${tool}" >/dev/null || missing+=("${tool}")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "missing: ${missing[*]}"
    command -v claude >/dev/null || ls "${HOME}"/.nvm/versions/node/*/bin/claude >/dev/null 2>&1 \
        || die 'claude (Claude Code) is not installed'
    systemctl --user show-environment >/dev/null 2>&1 \
        || die 'no systemd user manager here (systemctl --user does not work)'
    [[ -f "${HOME}/.claude/.credentials.json" ]] \
        || die 'no claude.ai login found (~/.claude/.credentials.json); run `claude` and /login first'
}

function set-disable-auto-mode() {
    local tmp
    mkdir -p "$(dirname "${SETTINGS}")"
    [[ -f "${SETTINGS}" ]] || echo '{}' >"${SETTINGS}"
    if [[ "$(jq -r '.permissions.disableAutoMode // empty' "${SETTINGS}")" == disable ]]; then
        say "disableAutoMode already set in ${SETTINGS}"
        return
    fi
    # Write through a temp file in the same directory, so a symlinked settings file is
    # followed and its other keys are kept.
    tmp=$(mktemp "$(dirname "$(readlink -f "${SETTINGS}")")/.settings.XXXXXX")
    jq '.permissions.disableAutoMode = "disable"' "${SETTINGS}" >"${tmp}"
    chmod --reference="$(readlink -f "${SETTINGS}")" "${tmp}"
    mv "${tmp}" "$(readlink -f "${SETTINGS}")"
    say "set permissions.disableAutoMode = \"disable\" in ${SETTINGS}"
}

function warn-conflicts() {
    local pid args
    for pid in $(pgrep -u "$(id -u)" -f 'claude' || true); do
        args=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null) || continue
        if [[ "${args}" =~ (^|/)claude(\.exe)?\ (.*\ )?(rc|remote-control)(\ |$) ]] \
            && [[ "${args}" != *--sdk-url* ]] \
            && [[ "$(readlink "/proc/${pid}/cwd")" == "${HOME}" ]] \
            && [[ "$(systemctl --user show -p MainPID --value "${UNIT}" 2>/dev/null)" != "$(ps -o ppid= -p "${pid}" | tr -d ' ')" ]]; then
            say "warning: a manual \`claude rc\` (pid ${pid}) is already serving ~; the service"
            say "         can't register ~ until you stop it (Remote Control allows one per folder)"
        fi
    done
}

function do-install() {
    local start="${1}"
    require
    mkdir -p "${BIN_DIR}" "${UNIT_DIR}"
    install -m 755 "${REPO}/bin/claude-rc-service" "${BIN_DIR}/claude-rc-service"
    install -m 644 "${REPO}/systemd/${UNIT}" "${UNIT_DIR}/${UNIT}"
    say "installed ${BIN_DIR}/claude-rc-service and ${UNIT_DIR}/${UNIT}"
    set-disable-auto-mode
    systemctl --user daemon-reload
    warn-conflicts
    if [[ "${start}" == true ]]; then
        systemctl --user enable "${UNIT}" >/dev/null 2>&1
        # restart, not start: an already-running copy must pick up the new files
        systemctl --user restart "${UNIT}"
        say 'enabled and (re)started; check it with: systemctl --user status claude-rc'
    else
        systemctl --user enable "${UNIT}" >/dev/null 2>&1
        say 'enabled; start it with: systemctl --user start claude-rc'
    fi
    if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]]; then
        say 'note: it starts when you log in. To start it at boot without a login:'
        say '      loginctl enable-linger'
    fi
}

function uninstall() {
    if systemctl --user is-active --quiet "${UNIT}" 2>/dev/null; then
        systemctl --user stop "${UNIT}"
        say 'stopped (its registrations were cleansed)'
    fi
    systemctl --user disable "${UNIT}" >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/${UNIT}" "${BIN_DIR}/claude-rc-service"
    systemctl --user daemon-reload
    say 'removed the unit and the wrapper'
    say "left permissions.disableAutoMode in ${SETTINGS}; remove it by hand if you want Auto back"
}

case "${1:-}" in
    '') do-install true ;;
    --no-start) do-install false ;;
    --uninstall) uninstall ;;
    -h|--help) sed -n '3,12p' "${0}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown option: ${1} (try --help)" ;;
esac
