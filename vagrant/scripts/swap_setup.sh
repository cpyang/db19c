#!/bin/bash
# ============================================================
# swap_setup.sh — configure per-node swap on the 16 GB node-exclusive VDI.
# 19c CVU wants swap ~= RAM (16 GB here; PRVF-7573); the box root disk ships
# only a small swap LV. Ported from the sibling 19c lab (same VBox quirks):
#   * disk located by EXACT sector size, never by /dev/sdX letter
#   * minimal guests may lack parted/sgdisk → scripted fdisk over stdin
#     (fdisk's own ioctl re-reads the table; no partprobe needed)
#   * run provisioner "always": idempotent, safe every boot
#   * this disk is OUTSIDE the ASM footprint — asm_setup.sh ignores it (it
#     only keys the 12/30/10 GB shared disks), so ASM can never claim it
# ============================================================
set -u
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

SWAP_SIZE_SECTORS=$((16 * 1024 * 1024 * 1024 / 512))   # 16 GiB → 33554432

wait_dev() { for _ in $(seq 40); do [ -b "$1" ] && return 0; sleep 0.5; done; return 1; }

TARGET=""
for d in /sys/block/sd*; do
  dev=$(basename "$d")
  sz=$(cat "$d/size" 2>/dev/null || echo 0)
  [ "$sz" = "$SWAP_SIZE_SECTORS" ] && TARGET="/dev/$dev"
done

if [ -z "$TARGET" ]; then
  echo "ERROR: no ${SWAP_SIZE_SECTORS}-sector swap disk found — is the node VDI attached?"
  exit 1
fi
PART="${TARGET}1"

if ! wait_dev "$PART" || ! $SUDO blkid "$PART" 2>/dev/null | grep -q 'TYPE="swap"'; then
  echo "Creating swap partition on $TARGET (GPT + one partition)..."
  printf 'g\nn\n\n\n\n\nw\n' | $SUDO fdisk "$TARGET" >/dev/null 2>&1
  if ! wait_dev "$PART"; then
    $SUDO kpartx -a "$TARGET" 2>/dev/null || true
    wait_dev "$PART" || { echo "ERROR: $PART never appeared"; exit 1; }
  fi
  $SUDO mkswap -L labswap "$PART"
fi

UUID=$($SUDO blkid -s UUID -o value "$PART")
if ! grep -q "$UUID" /etc/fstab 2>/dev/null; then
  echo "UUID=$UUID none swap defaults 0 0" | $SUDO tee -a /etc/fstab >/dev/null
fi

if ! $SUDO swapon --show=NAME 2>/dev/null | grep -qx "$PART"; then
  $SUDO swapon "$PART" || echo "WARNING: swapon $PART failed"
fi

echo "--- swap summary ---"
free -g | grep -E '^Mem:|^Swap:'
$SUDO swapon --show
