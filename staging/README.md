# Installer media staging

Everything here is gitignored **except this README** — Oracle binaries are
licensed; you place them once, the repo only stores symlinks.

## What this lab needs (and where di already has it)

| File | Role | di location |
|------|------|-------------|
| `LINUX.X64_193000_grid_home.zip` | GI 19.3 base (unzip INTO the GI home) | `~/staging/db19c/` |
| `LINUX.X64_193000_db_home.zip` | RDBMS 19.3 base | `~/staging/db19c/` |
| `p39036936_190000_Linux-x86-64.zip` | **GI RU 19.31** (`gridSetup -applyRU`) | `~/staging/db19c/` |
| `p39034528_190000_Linux-x86-64.zip` | **DB RU 19.31** (`runInstaller -applyRU`) | `~/staging/db19c/` |
| `p6880880_190000_Linux-x86-64.zip` | OPatch (MUST replace the bundled one) | `~/staging/db19c/` |
| `p13390677_112040_Linux-x86-64_1of7.zip` | 11.2.0.4 RDBMS part 1 | `~/staging/db11g/` |
| `p13390677_112040_Linux-x86-64_2of7.zip` | 11.2.0.4 RDBMS part 2 | `~/staging/db11g/` |

> 11g `3of7` is Grid Infrastructure — NOT used here: GI in this lab is 19c.
> GI/DB RU 19.31 (Apr 2026) is deliberate: **19c on OL9 requires RU ≥ 19.19**,
> and OL9U8 ships the UEKR7 kernel that combo needs.

## How to place them (on the VM host — di)

```bash
cd ~/src/db19c
mkdir -p staging
ln -sf ~/staging/db19c/LINUX.X64_193000_grid_home.zip \
       ~/staging/db19c/LINUX.X64_193000_db_home.zip \
       ~/staging/db19c/p39036936_190000_Linux-x86-64.zip \
       ~/staging/db19c/p39034528_190000_Linux-x86-64.zip \
       ~/staging/db19c/p6880880_190000_Linux-x86-64.zip staging/
ln -sf ~/staging/db11g/p13390677_112040_Linux-x86-64_1of7.zip \
       ~/staging/db11g/p13390677_112040_Linux-x86-64_2of7.zip staging/
```

Keep `staging/` itself a real directory; only the files inside may be
symlinks — the VBox shared-folder mount follows them (db11g-proven), so
nothing is ever copied into the repo or into guests.
