#!/usr/bin/env bash
#
# fix-sudoers.sh — Enable passwordless sudo for the current user
#
# Run: sudo bash fix-sudoers.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run this script as root (sudo bash $0)"
    exit 1
fi

USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
    echo "Error: could not determine the non-root user"
    exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/${USER_NAME}"

echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

# Validate syntax
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    echo "Passwordless sudo enabled for ${USER_NAME}"
else
    rm -f "$SUDOERS_FILE"
    echo "Error: invalid sudoers syntax — removed file"
    exit 1
fi
