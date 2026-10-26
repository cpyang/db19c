# GI 19c + DB 19c + DB 11g — one RAC on Oracle Linux 9 (Vagrant + VirtualBox + Ansible)

> Two Oracle DB versions, one Grid Infrastructure 19.31 cluster, two OL9
> nodes on workstation `di`: the db11g build model (host-driven Ansible
> phases) meets the oracle_dr_on_aws 19c install know-how.
> Forked from [cpyang/db11g](https://github.com/cpyang/db11g); lineage
> matters — most comments cite which lab a lesson came from.

## Overview

- **Vagrant + VirtualBox** — VM lifecycle, host-only networking, shared
  Fixed+shareable VDIs (identical mechanics to db11g)
- **Ansible (host-driven)** — OS prep, ASM disks, silent GI/DB installs, dbca
- **staging/ symlinks → `~/staging/{db19c,db11g}`** — the sole install
  source, mounted read-only; nothing is copied per guest
- **Nothing installs during `vagrant up`** — every Oracle phase is an
  explicit `ansible-playbook` run (re-attachable, re-runnable per phase)

## Architecture

```
 db19c-rac1.db19c.lab                   db19c-rac2.db19c.lab
 192.168.96.11 / 10.96.96.11            192.168.96.12 / 10.96.96.12
 vip 192.168.96.101                     vip 192.168.96.102
        \                                        /
     ASM_SCSI shared VDIs (Fixed + shareable)   /
   db19c_crs.vdi 12G | db19c_data.vdi 30G | db19c_fra.vdi 10G
                SCAN: db19c-scan = 192.168.96.100
```

| Component | Node 1 | Node 2 |
|-----------|--------|--------|
| Hostname (FQDN) | db19c-rac1.db19c.lab | db19c-rac2.db19c.lab |
| Public IP | 192.168.96.11 | 192.168.96.12 |
| Private IP (interconnect) | 10.96.96.11 | 10.96.96.12 |
| Virtual IP | 192.168.96.101 | 192.168.96.102 |
| SCAN | 192.168.96.100 (`db19c-scan`, single) | shared |
| RAM / vCPU | 16 GB / 4 | 16 GB / 4 |

> **Why 192.168.96.0/24?** 56.0/24 and 86.0/24 are already owned by the
> oracle_dr_on_aws and db11g labs on this host family. Never align ranges.

### What runs where (the whole point of the lab)

| Piece | Version | Home |
|-------|---------|------|
| Grid Infrastructure + ASM | 19.31.0.0.0 RU (`+19.3 base`) | `/u01/app/19.0.0/grid` (grid) |
| RAC CDB `db19c` (2 inst., 1 PDB) | 19.31.0.0.0 RU | `/u01/app/oracle/product/19.0.0/dbhome_1` (oracle) |
| Single-instance `db11` | **11.2.0.4** | `/u01/app/oracle/product/11.2.0/dbhome_1` (oracle) |

The 11g DB is managed BY the 19c GI (srvctl/resources) — documented
pairing: the 19c Installation Guide says "You can use … Oracle Database
11g release 2 (11.2.0.3 or later) with Oracle Grid Infrastructure 19c".
ASMFD is deliberately NOT used: 11.2 homes cannot live on ASMFD
(MOS Doc 2341119.1); plain udev symlinks instead.

### Support posture (read this before quoting versions to anyone)

- **GI 19c / DB 19c on OL9: certified**, with RU ≥ 19.19 (we run 19.31)
  on UEKR7 (OL9U8 box ships it).
- **11.2.0.4 on OL9: NO MOS certification note exists.** The certified
  modern-OS recipe is OL8 (MOS Doc 2988626.1 + one-off p33991024).
  This lab runs 11g on OL9 using the **Phase-0 spike-verified recipe**
  below — explicitly lab-only, same class of shortcut as the sibling
  labs' NFS/overlay home experiments. Never reproduce a finding from
  this config onto a supported stack without re-validating.

### Phase-0 spike findings (OL9U8, 2026-10-26, throwaway `ol9spike` VM)

`11.2.0.4` **installs, links, and STARTS (nomount) on OL9** once three
environment items are in place — none is an Oracle binary limitation:

| # | Fix | Why (measured) |
|---|-----|----------------|
| 1 | stub `/usr/lib64/libpthread_nonshared.a` | glibc ≥ 2.34 folded pthread into libc and deleted that archive; 11g link lines still name it → genclntsh died on it (the `.dynsym local symbol` lines from EL9 binutils are WARNINGS, not the failure) |
| 2 | `libxcrypt-compat` | the home's bundled perl wants `libcrypt.so.1`; `relink`/dbca scripts shell out to it |
| 3 | EL7 `compat-libstdc++-33` rpm (grafted from the OL7 repo) | no EL8/EL9 build was ever published; 11g wants `libstdc++.so.5` |
| 4 | relink repair (`scripts/ol9_11g_fixup.sh post`) | the installer Make phase aborts before `rdbms/lib/config.o` is written (0-byte artifact); `config.c` itself compiles fine with EL9 gcc → `cc -c config.c` + `make ioracle` yields a REAL 239 MB setuid binary. Do NOT run `relink all` — it fails ~18 harmless targets (emagent, ctx, precomp) for nothing. |

If a future EL9 update breaks #1–#4, the documented fallback is switching
the box to `oraclelinux/8` (all pieces certified there; deltas are
`oracle_packages` in `all.yml` + the fixups' `rpm -q` guards no-op).

## Storage layout

| VDI | Size | ASM label → disk group | Contents |
|-----|------|------------------------|----------|
| `db19c_crs.vdi` | **12 GB** | `/dev/oracleasm/disks/CRS` → **CRS** | OCR + voting (installer-placed, EXTERNAL) |
| `db19c_data.vdi` | **30 GB** | `/dev/oracleasm/disks/DATA` → **DATA** | database files (BOTH DBs live here) |
| `db19c_fra.vdi` | **10 GB** | `/dev/oracleasm/disks/FRA` → **FRA** | recovery area |
| `db19c-racN-swap.vdi` | 16 GB | (not ASM) | swap ≈ RAM — CVU PRVF-7573 wants it |

Shared sizes stay **pairwise distinct**: guests key disks by exact sector
count (VBox exposes no serial; letters drift). Created Fixed + shareable
(VBox 7 rejects shareable-dynamic). 60 GB root disks: GI home + TWO DB
homes + /u01/media.

## Prerequisites (lab host = di)

| Software | Version | Notes |
|----------|---------|-------|
| VirtualBox | ≥ 7.0 | fixed+shareable VDIs, internal net |
| Vagrant | ≥ 2.4 | box `oraclelinux/9` via Oracle's metadata JSON (`box_url` — the HashiCorp registry is gone): `vagrant box add oraclelinux/9 --provider virtualbox` works via the URL in `Vagrantfile` on first `up` |
| Ansible | ansible-core ≥ 2.16 | di's system 2.16.3 is fine — EL9 guests ship python 3.9, no venv pin needed (db11g's 2.16 pin was an EL7/py3.6 constraint) |
| `unzip` on the host | any | VBox shared folders + guest provisioning assume it; the OL9 box itself does NOT ship unzip (it's in `oracle_packages`) |

## Quick start

```bash
cd ~/src/db19c
vagrant up db19c-rac1          # node1 FIRST (owns cluster formation)
vagrant up db19c-rac2
# staging/ symlinks must exist on di — see staging/README.md

cd ansible
ansible-playbook playbooks/01-configure-os.yml        # OS/users/DNS/NTP (EL9)
ansible-playbook playbooks/02-configure-cluster.yml   # ASM disks, probes
ansible-playbook playbooks/03-install-grid.yml        # GI 19.31 + root.sh + DGs  (~60-90 min)
ansible-playbook playbooks/04-install-db.yml          # 19c DB software + root.sh  (~40 min)
ansible-playbook playbooks/04b-install-db11g.yml      # 11.2.0.4 software + relink (~40 min)
ansible-playbook playbooks/05-create-db.yml           # dbca db19c + db11  (~1-2 h)
```

Phases are idempotent and stage-guarded (`crsctl` presence, `olr.loc`,
`bin/oracle` SIZE, `crsctl stat res -t` text). root.sh phases always run
node1 before node2 — do not remove the play ordering.

## What gets configured

### OS (`01` / roles/common)
- `grid` + `oracle` users, fixed GIDs (oracle is ALSO in `asmadmin` — OS
  SYSASM for dbca, the db11g playbook-05 lesson), NOPASSWD sudo
- limits drop-ins, sysctl (mirror into `/etc/sysctl.conf` — CVU greps
  ONLY that file), THP off via systemd unit, `vm.overcommit_memory=1`
- `/etc/hosts` full set + **dnsmasq**; EL9 keeps **NetworkManager** (no
  network-scripts there): DNS is pinned via `nmcli con mod` on both
  connections (`ipv4.ignore-auto-dns`) instead of EL7's PEERDNS, and
  `myhostname` is dropped from nsswitch (fe80:: → PRKC-1168 lesson)
- classic-**PEM** ssh keys for oracle+grid, every hop incl. self — both
  installers' Java ssh cannot read OpenSSH-format keys
- **chrony** replaces EL7 ntpd; one explicit server on both nodes
  (PRVF-5408 lesson)

### Cluster (`02`)
- `scripts/asm_setup.sh` (size-keyed partitioning + udev rules, db11g
  proven) with DATA at 30 GB; wipe guard (`ASM_FORCE=1` to re-zero)
- per-hop BatchMode ssh probes + SCAN resolution probe

### Grid (`03`)
- unzip `grid_home.zip` INTO the home; **replace bundled OPatch** (19.3's
  is too old for `-applyRU` — tests 2026-10-15); `gridSetup.sh -silent
  -applyRU 39036936 -ignorePrereqFailure` node1-only (stages peers);
  **rc 254 = silent abort, never success** — verified against the
  GridSetupActions log
- root.sh node1 → node2 (plain systemd root.sh on EL9: NO ohasd/inittab
  dance — that was EL7-only); DATA+FRA via `asmca`, guarded by
  `crsctl stat res -t` GREP (rc-based existence checks lie)

### Database 19c (`04`)
- **per-node local install** (`CLUSTER_NODES=<self>`): the
  node1-propagates model dies on base-19.3 CVU remote checks
  (INS-06006/PRVF-5311, tests 2026-10-16 postmortem); `runInstaller
  -applyRU 39034528` + `CV_ASSUME_DISTID=OEL7.8`; detach-sweep guard for
  re-runs (INS-32826); verify = bin/oracle size + setuid + `lspatches`

### Database 11g (`04b`)
- per-node software-only install, **no CLUSTER_NODES** (local image;
  cluster registration happens in `05` via 19c srvctl, so 11.2's remote
  propagation/CVU never runs)
- `scripts/ol9_11g_fixup.sh pre` (spike fixes 1–3) → runInstaller
  `-ignorePrereq -waitforcompletion` → `post` (repair 4, size-guarded)
- rsp rendered from the **media's own template** (11.2's XSD is a strict
  ordered sequence — a hand-trimmed rsp dies INS-10105; spike-verified)

### Databases (`05`)
- `db19c`: dbca create CDB+PDB on node1, `-addInstance` node2 (the tests
  grammar), `ORA_DISABLED_CVU_CHECKS=SCAN` (phantom check, DNS verified
  manually in 01); assert 2 running instances via srvctl status
- `db11`: dbca from the 11g home with `-initParams cluster_database=false`
  (flag confirmed in this home's `dbca -help`), then `srvctl add database
  -r SINGLE` from the 19c GI (spfile path discovered via `asmcmd ls`,
  never a placeholder); instances beyond node1 removed

## Verify

```bash
vagrant ssh db19c-rac1
sudo -u grid /u01/app/19.0.0/grid/bin/crsctl check cluster -all
sudo -u grid asmcmd lsdg                       # CRS DATA FRA mounted
sudo -u grid srvctl status database -d db19c   # db191 + db192 RUNNING
sudo -u grid srvctl status database -d db11    # db111 on node1
# 19c:  . /home/oracle/.bash_profile;    sqlplus sys/oracle@db19c-scan:1521/pdb0.db19c.lab
# 11g:  . /home/oracle/db11g.env;        sqlplus sys/oracle@db19c-scan:1521/db11.db19c.lab
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| gridSetup rc 254 | silent config ABORT — read GridSetupActions log for INS-xxxx |
| gridSetup "home is not clean, failed OPatch execution" | wipe `{{ grid_home }}` on both nodes, rerun `03` |
| db home install INS-32826 | stale inventory entry → 04's detach-sweep runs; if it persists, check `$OH/inventory` marker |
| 11g `genclntsh: Failed to link libclntsh.so.11.1` | stub missing → rerun `04b` (fixup pre creates it); log line `.dynsym` alone is a WARNING |
| 11g install "completed" but bin/oracle is 0 bytes | Make-phase race → fixup post relinks; `relink all` NOT needed |
| 11g dbca "invalid command line argument" | 11.2 dbca grammar ≠ 19c; check `dbca -help` on the VM (see playbook 05 header) |
| SCAN ORA-00141 / "support no services" | dnsmasq bound wrong NIC — 01 asserts resolution; check `nmcli con show` DNS pins survived |
| CVU PRVF-11826/PRVG DNS set mismatch | resolv must list host-only IPs (01 task asserts); /etc/hosts entries are the fallback, dnsmasq the authority |
| CRS broken after host reboot | node1 up → wait CRS online → node2 (shared VDI lock order) |

Logs: oraInventory `logs/`, `$GI/cfgtoollogs/`, `$OH/cfgtoollogs/dbca/`,
`/tmp/ol9-fixup-*` from 04b.

## Cleanup

```bash
vagrant destroy -f                     # VMs; shared VDIs KEPT (deliberate)
rm -f .vagrant/shared_disks/*.vdi      # only for a true cold start
```

After `destroy && up`, re-run `01` **before** `02` (trust probes need the
regenerated ssh state), same rule as db11g.

## Security notes

Lab only: shared `oracle` passwords everywhere, no firewalld, no TLS.
Never expose these ports beyond the host.

## References
- 19c GI "Restrictions for Grid Infrastructure Upgrades" — "You can use
  … Database 11g release 2 (11.2.0.3 or later) with GI 19c"
- MOS 2988626.1 (11.2.0.4 on OL8 — the certified sibling of our EL9 recipe)
- MOS 2905644.1 / RU ≥ 19.19 for OL9; Doc 2341119.1 (no 11.2 on ASMFD)
- siblings: cpyang/db11g (build model), oracle_dr_on_aws/tests §6 (19c flow)
