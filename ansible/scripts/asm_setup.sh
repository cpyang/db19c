#!/bin/bash
# ============================================================
# asm_setup.sh — shared-disk identification, partitioning and udev ASM
# symlinks. ansible/scripts/ — run via the storage role (script module),
# self-elevating.
#
# Rules of engagement (learned in the sibling labs):
#   * Disks are located by EXACT full-disk sector size. Letters drift;
#     sizes are the identity, and the three shared sizes are distinct.
#   * node1 zeroes (wipefs) + GPT-partitions the disks ONCE. node2 must
#     NEVER re-zero a disk its peer already provisioned.
#   * udev rules key on ID_PART_ENTRY_SIZE (VBox disks expose no serial),
#     one symlink per label under /dev/oracleasm/disks/.
#   * blockdev --rereadpt BEFORE generating rules on a node that attached
#     the VDI before its peer partitioned it (kernel may hold a stale table).
#   * Script FAILS (exit 1) if any expected symlink is missing — silent
#     ASM failure here costs a whole gridSetup attempt downstream.
# ============================================================
set -u
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

NODE_ROLE=${1:?usage: asm_setup.sh node1|node2}

# label:desired_full_disk_sectors — MUST match Vagrantfile SHARED_DISKS
# (values = GB*2^30/512, computed + verified 2026-10-21; literals because a
# mis-typed $(( )) silently became a subshell here and died on first boot)
declare -A WANT=(
  [CRS]=25165824     # 12 GB
  [DATA]=62914560    # 30 GB
  [FRA]=20971520     # 10 GB
)

log() { echo "[asm_setup] $*"; }

find_dev_by_size() {  # sectors -> /dev/sdX
  local want=$1 d sz
  for d in /sys/block/sd*; do
    sz=$(cat "$d/size" 2>/dev/null || echo 0)
    [ "$sz" = "$want" ] && { echo "/dev/$(basename "$d")"; return 0; }
  done
  return 1
}

# ---- locate all three shared disks; abort on ambiguity/absence ----
declare -A DEV
for label in CRS DATA FRA; do
  dev=$(find_dev_by_size "${WANT[$label]}") || { log "ERROR: no ${WANT[$label]}-sector disk for $label"; exit 1; }
  DEV[$label]=$dev
done
# guard: one disk must not satisfy two labels
if [ "$(printf '%s\n' "${DEV[@]}" | sort -u | wc -l)" != "3" ]; then
  log "ERROR: disk size mapping collided: ${DEV[*]}"; exit 1
fi
log "mapping: CRS=${DEV[CRS]} DATA=${DEV[DATA]} FRA=${DEV[FRA]} (role: $NODE_ROLE)"

# ---- node1: zero + partition (once; ASM_FORCE=1 forces a clean re-do) ----
if [ "$NODE_ROLE" = "node1" ]; then
  for label in CRS DATA FRA; do
    dev=${DEV[$label]}
    if lsblk -n -o NAME "$dev" | grep -qE "^$(basename $dev)[0-9]" && [ "${ASM_FORCE:-0}" != "1" ]; then
      log "$dev already partitioned — skipping zero/partition"
      continue
    fi
    log "zeroing signatures + GPT partition (whole disk) on $dev${ASM_FORCE:+ (forced)}"
    $SUDO wipefs -a "$dev" >/dev/null 2>&1 || true
    printf 'g\nn\n\n\n\n\nw\n' | $SUDO fdisk "$dev" >/dev/null 2>&1
    sleep 2
    udevadm settle 2>/dev/null || true
    # wipefs+GPT do NOT clear the partition's DATA AREA: an old ASM header
    # at the (same-sector-aligned) partition start survives a forced rebuild
    # verbatim and the GI installer then aborts INS-30516 'disk group already
    # exists' on wiped disks (di 2026-10-22 22:19 — two forced re-runs fooled
    # this way). Zero 10 MB past every header location.
    $SUDO dd if=/dev/zero of=${dev}1 bs=1M count=10 conv=notrunc status=none
  done
fi

# ---- refresh kernel view, THEN generate rules from what the kernel sees ----
for label in CRS DATA FRA; do
  $SUDO blockdev --rereadpt "${DEV[$label]}" 2>/dev/null || true
done
sleep 1

RULES=/etc/udev/rules.d/99-oracle-asm.rules
{
  echo "# managed by ansible/scripts/asm_setup.sh"
  for label in CRS DATA FRA; do
    part="${DEV[$label]}1"
    if [ ! -b "$part" ]; then
      log "ERROR: $part did not appear (node2: did node1 partition + boot this disk's peer?)"
      exit 1
    fi
    psz=$($SUDO blockdev --getsz "$part" 2>/dev/null || stat -c %s "$part" 2>/dev/null)
    # blockdev --getsz reports 512-byte sectors == ID_PART_ENTRY_SIZE units
    cat <<RULE
SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_SIZE}=="$psz", \\
  SYMLINK+="oracleasm/disks/$label", OWNER="grid", GROUP="oinstall", MODE="0660"
RULE
  done
} | $SUDO tee "$RULES" >/dev/null

$SUDO mkdir -p /dev/oracleasm/disks
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --type=devices --action=change
sleep 2
udevadm settle 2>/dev/null || true

# ---- hard verification ----
rc=0
for label in CRS DATA FRA; do
  if [ -e "/dev/oracleasm/disks/$label" ]; then
    log "OK   /dev/oracleasm/disks/$label -> $(readlink -f /dev/oracleasm/disks/$label)"
  else
    log "FAIL /dev/oracleasm/disks/$label missing"
    rc=1
  fi
done
exit $rc
