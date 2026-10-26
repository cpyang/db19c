#!/bin/bash
# ============================================================
# bootstrap.sh — minimal EL9 guest prep so host-side Ansible works.
# Deliberately tiny: everything Oracle-related lives in ansible/
# so the playbooks are the single source of truth.
# (Ported from db11g's EL7 version. EL9 differences:
#   * NetworkManager STAYS ON — EL9 has no network-scripts; Vagrant
#     2.4.x + the tests lab both drive addressing through NM.
#   * python3 ships with the base box (3.9); the guard is only for
#     stripped rebuilds.
# ============================================================
set -eux

FQDN=${1:-}
PUBLIC_IP=${2:-}
PRIVATE_IP=${3:-}
VIP=${4:-}
SCAN_IP=${5:-}

echo "=== bootstrap: ${FQDN:-?} pub=${PUBLIC_IP:-?} priv=${PRIVATE_IP:-?} vip=${VIP:-?} scan=${SCAN_IP:-?} ==="

# SELinux: fully disable at runtime + persistently (the installers are far
# happier without it; the playbook re-verifies and reboots once if the box
# came up enforcing).
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# Firewalld off (lab network).
systemctl disable --now firewalld 2>/dev/null || true

# python3 is the Ansible target interpreter (EL9 base box: 3.9 present).
if ! command -v python3 >/dev/null 2>&1; then
  dnf install -y python3
fi

# NetworkManager ON (EL9 has no initscripts/network-scripts fallback).
systemctl enable --now NetworkManager 2>/dev/null || true

echo "=== bootstrap complete (ansible playbooks do the rest) ==="
