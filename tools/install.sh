#!/usr/bin/env bash
# =============================================================================
# install.sh — SCP the jffs scripts to an Asuswrt-Merlin node
#
# Usage:
#   ./tools/install.sh main      <host>   [ssh-user]
#   ./tools/install.sh secondary <host>   [ssh-user]
#
# Examples:
#   ./tools/install.sh main      192.168.1.1
#   ./tools/install.sh secondary 192.168.1.2  admin
#
# Defaults to ssh user 'admin' (Merlin's default). Make sure SSH key auth is
# set up; password auth via scp is painful and not supported here.
#
# After install you must:
#   1. ssh in and run `chmod +x /jffs/scripts/*`
#   2. Verify /jffs/scripts has 'enable jffs partition' AND 'execute scripts'
#      turned on in the Merlin UI (System > Administration).
#   3. Reboot the node OR run the setup script manually to pick up changes.
# =============================================================================

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 {main|secondary} <host> [ssh-user]"
    exit 1
fi

ROLE="$1"
HOST="$2"
SSH_USER="${3:-admin}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/${ROLE}/jffs/scripts"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: source directory not found: $SRC_DIR"
    echo "Role must be 'main' or 'secondary'."
    exit 1
fi

echo "Installing ${ROLE} scripts from ${SRC_DIR} to ${SSH_USER}@${HOST}:/jffs/scripts/"
echo

# Copy each file. Some routers' scp is busybox and refuses recursive copies,
# so we list explicitly.
#
# -O forces the legacy SCP protocol. OpenSSH 9.0+ defaults to SFTP, but
# dropbear (Asuswrt-Merlin's SSH server) ships without an sftp-server, so
# the default transport fails with "sh: /opt/libexec/sftp-server: not found".
for f in "$SRC_DIR"/*; do
    name=$(basename "$f")
    echo "  -> $name"
    scp -qO "$f" "${SSH_USER}@${HOST}:/jffs/scripts/$name"
done

echo
echo "Setting executable bit on /jffs/scripts/*"
ssh "${SSH_USER}@${HOST}" "chmod +x /jffs/scripts/*"

echo
echo "Done. Next steps:"
echo "  1. Confirm /jffs is enabled and script execution is on in the Merlin UI"
echo "     (System > Administration > Persistent JFFS / Enable scripts)."
echo "  2. Reboot the node, or run the setup script manually:"
echo "       ssh ${SSH_USER}@${HOST} /jffs/scripts/vlan-bridge-setup"
echo "  3. Tail /tmp/vlan-bridge-setup.log to verify success."
