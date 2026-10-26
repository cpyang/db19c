# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# GI 19c + DB 19c + DB 11.2.0.4 — two nodes on VirtualBox, host Ansible.
# Forked from cpyang/db11g (same build model); 19c install know-how ported
# from oracle_dr_on_aws/tests.
#
# BUILD MODEL (unchanged from db11g)
# -----------------------------------
# Nothing installs during `vagrant up`. Vagrant boots the nodes and runs the
# tiny bootstrap/swap scripts; every Oracle phase is an explicit
# ansible-playbook run from the lab host. Re-attachable, re-runnable per
# phase.
#
# SHARED DISK STRATEGY (validated on this host family with VBox 7.x)
# -------------------------------------------------------------------
# VirtualBox only allows one VDI to be mounted by multiple VMs when ALL of:
#   1. The medium was created --variant Fixed AND set --type shareable
#      (VBox 7 REJECTS --mtype shareable for DYNAMIC media).
#   2. Every storageattach call uses --mtype shareable.
#   3. The SAS controller exists before storageattach runs.
# Shared ASM disks get DISTINCT sizes (12/30/10 GB): guests map devices to
# ASM labels by exact sector size, never by /dev/sdX letters — unique sizes
# are the identity (VBox SAS disks expose no serial).
#
# NETWORK NOTE
# ------------
# 192.168.56.0/24 (oracle_dr_on_aws rac labs), 192.168.86.0/24 (db11g lab)
# and 10.10.10.0/24 are taken on this host family — this lab lives on
# 192.168.96.0/24 (public, host-only) and VBox internal network
# 10.96.96.0/24 (interconnect). Do not "align" these ranges.
#
# Vagrant applies private_network IPs only on FIRST boot — if VMs are
# recreated over existing media, check both NICs are addressed after boot.

require 'fileutils'

# Set DB19C_SKIP_DISK_PREP=1 to parse the file without touching host disk
# media (used by `vagrant validate` / lint runs).
SKIP_DISK_PREP = ENV['DB19C_SKIP_DISK_PREP'] == '1'

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
DOMAIN        = 'db19c.lab'
NETWORK       = '192.168.96'   # host-only "public"
PRIV_NETWORK  = '10.96.96'     # VBox internal network (cluster interconnect)
SCAN_IP       = "#{NETWORK}.100"
INTNET_NAME   = 'db19c-priv-net'

VAGRANT_ROOT = File.dirname(File.expand_path(__FILE__))
DISK_DIR     = File.join(VAGRANT_ROOT, '.vagrant', 'shared_disks')
MACHINES_DIR = File.join(VAGRANT_ROOT, '.vagrant', 'machines')
ASM_CTRL     = 'ASM_SCSI'

# Shared ASM disks — sizes MUST stay pairwise distinct (size = identity).
SHARED_DISKS = {
  'db19c_crs'  => 12,   # GB — OCR + voting disks (disk group CRS)
  'db19c_data' => 30,   # GB — database files     (disk group DATA)
  'db19c_fra'  => 10,   # GB — flash recovery area (disk group FRA)
}
SWAP_DISK_GB = 16       # node-exclusive; CVU wants swap ~= RAM (16 GB)

NODES = {
  'db19c-rac1' => {
    fqdn: "db19c-rac1.#{DOMAIN}",
    public_ip: "#{NETWORK}.11",
    private_ip: "#{PRIV_NETWORK}.11",
    vip: "#{NETWORK}.101",
    memory: 16384,
    cpus: 4,
    grid_home: '/u01/app/19.0.0/grid',
    oracle_home: '/u01/app/oracle/product/19.0.0/dbhome_1',
  },
  'db19c-rac2' => {
    fqdn: "db19c-rac2.#{DOMAIN}",
    public_ip: "#{NETWORK}.12",
    private_ip: "#{PRIV_NETWORK}.12",
    vip: "#{NETWORK}.102",
    memory: 16384,
    cpus: 4,
    grid_home: '/u01/app/19.0.0/grid',
    oracle_home: '/u01/app/oracle/product/19.0.0/dbhome_1',
  },
}

# --------------------------------------------------------------------------
# Host-side disk helpers (run at parse time unless SKIP_DISK_PREP)
# --------------------------------------------------------------------------
def create_shared_disk(name, size_gb, disk_dir)
  disk_path = File.join(disk_dir, "#{name}.vdi")
  unless File.exist?(disk_path)
    puts "  [shared-disk] Creating #{disk_path} (#{size_gb} GB, Fixed+shareable)..."
    ok = system("vboxmanage createmedium disk --filename \"#{disk_path}\" " \
                "--size #{size_gb * 1024} --format VDI --variant Fixed")
    abort "  ERROR: createmedium failed for #{name}" unless ok
    system("vboxmanage modifymedium disk \"#{disk_path}\" --type shareable")
  end

  # Register-by-path may fail if a stale registry entry holds another path.
  info = `vboxmanage showmediuminfo "#{disk_path}" 2>&1`
  if info =~ /with UUID \{(.*?)\} already exists/
    uuid = $1
    puts "  [shared-disk] Fixing stale registry path for #{name} (UUID #{uuid})..."
    system("vboxmanage closemedium disk #{uuid}")
    info = `vboxmanage showmediuminfo "#{disk_path}" 2>&1`
  end
  # VBox 7 rejects --mtype shareable for DYNAMIC media. Fail loudly instead
  # of producing a half-attached cluster (db11g's original disks/*.vdi were).
  abort "  ERROR: #{disk_path} is DYNAMIC media — remove it (must be " \
        "unattached+empty) and let the Vagrantfile recreate it Fixed.\n" \
        "  Check: vboxmanage showmediuminfo \"#{disk_path}\"" if
        info.include?('Format variant: dynamic')
  disk_path
end

def create_node_disk(name, size_gb, disk_dir)
  disk_path = File.join(disk_dir, "#{name}.vdi")
  unless File.exist?(disk_path)
    puts "  [node-disk] Creating #{disk_path} (#{size_gb} GB, dynamic)..."
    ok = system("vboxmanage createmedium disk --filename \"#{disk_path}\" " \
                "--size #{size_gb * 1024} --format VDI")
    abort "  ERROR: createmedium failed for #{name}" unless ok
  end
  disk_path
end

def attach_disk(vb, ctrl, port, disk_path, mtype = 'shareable')
  vb.customize ['storageattach', :id,
                '--storagectl', ctrl,
                '--port', port.to_s,
                '--device', '0',
                '--type', 'hdd',
                '--medium', disk_path,
                '--mtype', mtype]
end

# Remove ASM_SCSI before every up/reload so storagectl --add is idempotent
# (vb.customize re-runs on every boot, not just creation). reload does not
# fire :up triggers, hence both.
def ensure_clean_scsi_ctrl(node, vm_name, ctrl)
  [:up, :reload].each do |trigger_cmd|
    node.trigger.before trigger_cmd do |t|
      t.name = "[#{vm_name}] Remove stale #{ctrl} before #{trigger_cmd}"
      t.ruby do |env, machine|
        id_file = File.join(MACHINES_DIR, vm_name, 'virtualbox', 'id')
        next unless File.exist?(id_file)
        uuid = File.read(id_file).strip
        state = `vboxmanage showvminfo "#{uuid}" --machinereadable 2>/dev/null | grep '^VMState=' | cut -d'"' -f2`.strip
        if !state.empty? && state != 'poweroff'
          puts "  [pre-#{trigger_cmd} #{vm_name}] VM is '#{state}' — powering off for controller cleanup..."
          system("vboxmanage controlvm \"#{uuid}\" poweroff 2>/dev/null || true")
          sleep 2
        end
        if system("vboxmanage showvminfo \"#{uuid}\" 2>/dev/null | grep -q '#{ctrl}'")
          puts "  [pre-#{trigger_cmd} #{vm_name}] Removing stale #{ctrl}..."
          system("vboxmanage storagectl \"#{uuid}\" --name \"#{ctrl}\" --remove 2>/dev/null || true")
        end
      end
    end
  end
end

# --------------------------------------------------------------------------
# Pre-create media before any VM boots
# --------------------------------------------------------------------------
FileUtils.mkdir_p(DISK_DIR)
DISK_VARS = {}
unless SKIP_DISK_PREP
  SHARED_DISKS.each { |name, gb| DISK_VARS[name] = create_shared_disk(name, gb, DISK_DIR) }
  NODES.each_key    { |n|   DISK_VARS["#{n}_swap"] = create_node_disk("#{n}-swap", SWAP_DISK_GB, DISK_DIR) }
end

# --------------------------------------------------------------------------
Vagrant.configure('2') do |config|
  # Oracle distributes its boxes from its own registry since the HashiCorp
  # one was retired; the vagrantcloud name does not resolve, so point
  # box_url at Oracle's metadata JSON (virtualbox entry: OL9U8 = 9.8.712,
  # ships UEKR7 — the OL9 build 19c certification requires).
  config.vm.box              = 'oraclelinux/9'
  config.vm.box_url          = 'https://oracle.github.io/vagrant-projects/boxes/oraclelinux/9.json'
  config.vm.box_check_update = false

  # 60 GB root disk: /u01 (GI home + TWO DB homes 19c/11g + media) lives on it.
  config.vm.disk :disk, size: '60GB', primary: true

  # The repo folder must NOT rsync GB-scale zips/VDIs into every guest.
  config.vm.synced_folder '.', '/vagrant', disabled: true

  # Installation media: DIRECT read-only VBox shares of the host media
  # library (~/staging/{db19c,db11g} on the lab host). The previous
  # repo-staging-symlink model worked on EL7 guests, but EL9 vboxsf
  # resolves absolute symlink targets INSIDE the guest -> ENOENT while a
  # bare stat of the link still passes — a silent trap (di 2026-10-26).
  config.vm.synced_folder File.expand_path('~/staging/db19c'), '/u01/media/db19c',
    type: 'virtualbox', mount_options: %w[ro fmode=644 dmode=755 uid=0 gid=0]
  config.vm.synced_folder File.expand_path('~/staging/db11g'), '/u01/media/db11g',
    type: 'virtualbox', mount_options: %w[ro fmode=644 dmode=755 uid=0 gid=0]

  NODES.each do |node_name, node|
    # primary: plain `vagrant ssh`/status targets node1. Node DEFINITION
    # order stays rac1→rac2: serial `vagrant up` boots node1 first, which
    # owns cluster formation.
    config.vm.define node_name, primary: (node_name == NODES.keys.first) do |cfg|
      cfg.vm.hostname = node_name   # SHORT (== CRS nodename) — dbca ssh
      # equality check requires uname==CRS name (db11g pattern); FQDN
      # here breaks RAC create with INS-06006<->DBT-14101 ping-pong
      # (di 2026-10-26).

      cfg.vm.network 'private_network', ip: node[:public_ip]
      cfg.vm.network 'private_network', ip: node[:private_ip],
                     virtualbox__intnet: INTNET_NAME

      ensure_clean_scsi_ctrl(cfg, node_name, ASM_CTRL)

      cfg.vm.provider 'virtualbox' do |vb|
        vb.name   = node_name
        vb.memory = node[:memory]
        vb.cpus   = node[:cpus]
        vb.customize ['modifyvm', :id, '--audio', 'none']
        vb.customize ['storagectl', :id, '--name', ASM_CTRL, '--add', 'sas',
                      '--portcount', '16', '--hostiocache', 'off']
        unless SKIP_DISK_PREP
          # Ports 0-2: shared ASM disks in identical order on both nodes.
          # Port 3: node-exclusive swap (mtype normal — VB7 forbids
          # shareable on dynamic media).
          attach_disk(vb, ASM_CTRL, 0, DISK_VARS['db19c_crs'])
          attach_disk(vb, ASM_CTRL, 1, DISK_VARS['db19c_data'])
          attach_disk(vb, ASM_CTRL, 2, DISK_VARS['db19c_fra'])
          attach_disk(vb, ASM_CTRL, 3, DISK_VARS["#{node_name}_swap"], 'normal')
        end
      end

      # Minimal guest prep so host-side Ansible can run. EL9 has no
      # network-scripts — NetworkManager STAYS ON (db11g/EL7 turned it off);
      # see bootstrap.sh and the NM-safe DNS handling in roles/common.
      cfg.vm.provision :shell,
        path: 'vagrant/scripts/bootstrap.sh',
        args: [node[:fqdn], node[:public_ip], node[:private_ip], node[:vip], SCAN_IP]

      # Swap disk re-armed every boot (idempotent, self-elevating).
      cfg.vm.provision :shell, path: 'vagrant/scripts/swap_setup.sh', run: 'always'
    end
  end

  config.vm.post_up_message = <<~MSG
    == db19c node up ==
    Oracle install is driven from the HOST, not by vagrant provision:
      cd ansible
      ansible-playbook playbooks/01-configure-os.yml        # OS prep, both nodes
      ansible-playbook playbooks/02-configure-cluster.yml   # ASM disks/trust
      ansible-playbook playbooks/03-install-grid.yml        # GI 19.31 + root.sh + DGs
      ansible-playbook playbooks/04-install-db.yml          # 19c DB software + root.sh
      ansible-playbook playbooks/04b-install-db11g.yml      # 11.2.0.4 DB software
      ansible-playbook playbooks/05-create-db.yml           # dbca 19c + register 11g
    Order matters. See README.md for details and idempotency notes.
  MSG
end
