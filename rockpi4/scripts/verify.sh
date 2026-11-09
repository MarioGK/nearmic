#!/usr/bin/env bash
# Verify the booted ROCK 4 Plus over SSH.
# Usage: ./verify.sh <board-ip>
set -euo pipefail

HOST="${1:?usage: verify.sh <board-ip>}"
SSH_ARGS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[ -n "${KEY:-}" ] && SSH_ARGS+=(-i "$KEY")
SSH=(ssh "${SSH_ARGS[@]}" "mariogk@$HOST")

echo "== identity =="
"${SSH[@]}" 'id; hostnamectl --static; uname -a'

echo "== sudo (must not prompt) =="
"${SSH[@]}" 'sudo -n true && echo "passwordless sudo OK"'

echo "== ssh service =="
"${SSH[@]}" 'systemctl is-active ssh'

echo "== network =="
"${SSH[@]}" 'ip -4 -brief addr'

echo "== storage =="
"${SSH[@]}" 'findmnt -no SOURCE,SIZE,USED,AVAIL /; df -h /'
