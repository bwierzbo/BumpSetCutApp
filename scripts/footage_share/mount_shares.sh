#!/bin/bash
# Mounts the desktop's two RallyLab shares over the LAN with no password on any command line,
# in any file or in any output: the password is read from the login Keychain into this shell's
# memory, handed to a child `expect` through its environment, and typed into mount_smbfs's own
# "Password for" prompt (mount_prompt.exp). docs/workflow/FOOTAGE_SHARE.md, "Mounting, corrected".
#
#   scripts/footage_share/mount_shares.sh           # mount both: footage read-only, staging writable
#   scripts/footage_share/mount_shares.sh --check   # only report what is mounted
#
# Needs the Keychain item (account rallylab-share, server 10.0.0.123, protocol smb) and an
# unlocked screen: the login Keychain refuses a terminal's read while the screen is locked.
set -euo pipefail
SERVER=${RALLYLAB_SMB_SERVER:-10.0.0.123}
ACCOUNT=rallylab-share
MNT=${RALLYLAB_MNT:-$HOME/mnt}
HERE=$(cd "$(dirname "$0")" && pwd)

status() { mount | grep -E "//$ACCOUNT@$SERVER/RallyLab(Footage|Staging) " | sed 's/, mounted by.*//' || true; }

if [[ "${1:-}" == "--check" ]]; then status; exit 0; fi

mount_one() {   # share, mount point, mount options ("" for none)
    if mount | grep -q "//$ACCOUNT@$SERVER/$1 on $2 "; then echo "$1: already mounted at $2"; return 0; fi
    mkdir -p "$2"
    /usr/bin/expect "$HERE/mount_prompt.exp" "$ACCOUNT" "$SERVER" "$1" "$2" "$3"
}

# The password exists in this process's memory and in the expect children's environment only.
if ! PW=$(security find-internet-password -a "$ACCOUNT" -s "$SERVER" -r 'smb ' -w 2>/dev/null); then
    echo "Keychain read failed: screen locked, or no item for $ACCOUNT at $SERVER (protocol smb)" >&2
    exit 1
fi
export PW
rc=0
mount_one RallyLabFootage "$MNT/RallyLabFootage" rdonly || rc=$?
mount_one RallyLabStaging "$MNT/RallyLabStaging" "" || rc=$?
unset PW
status
exit $rc
