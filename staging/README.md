# Installer media — NOT staged here anymore

The repo-`staging/` symlink model worked on EL7 guests but is broken on
EL9: vboxsf resolves absolute symlink targets *inside the guest*
(ENOENT, while a bare `stat` of the link still passes — silent trap,
found 2026-10-26 on di). Oracle binaries are licensed; nothing is ever
copied into the repo or into guests.

## How media reaches guests now

**Direct read-only VBox shared folders** declared in the Vagrantfile:

| Guest mount        | Host source (lab host) |
|--------------------|------------------------|
| `/u01/media/db19c` | `~/staging/db19c/`     |
| `/u01/media/db11g` | `~/staging/db11g/`     |

`vagrant up` must run on a host where those two `~/staging/` dirs exist
(di); Vagrant fails fast on a missing shared-folder source.

## What the lab needs (and where di's library has it)

| File | Role |
|------|------|
| `LINUX.X64_193000_grid_home.zip` | GI 19.3 base (unzip INTO the GI home) |
| `LINUX.X64_193000_db_home.zip`   | RDBMS 19.3 base |
| `p39036936_190000_Linux-x86-64.zip` | **GI RU 19.31** (`gridSetup -applyRU`) |
| `p39034528_190000_Linux-x86-64.zip` | **DB RU 19.31** (per-node `opatch apply -local`) |
| `p6880880_190000_Linux-x86-64.zip`  | OPatch (MUST replace the bundled one) |
| `p13390677_112040_Linux-x86-64_{1,2}of7.zip` | 11.2.0.4 RDBMS (in `~/staging/db11g/`) |

> 11g `3of7` is GI — NOT used here: GI in this lab is 19c.
> GI/DB RU 19.31 (Apr 2026) is deliberate: **19c on OL9 requires RU ≥ 19.19**,
> and OL9U8 ships the UEKR7 kernel that combo needs.
