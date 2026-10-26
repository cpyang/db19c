#!/bin/bash
# ============================================================
# ol9_11g_fixup.sh — make 11.2.0.4 software install & link on OL9.
# Run: ol9_11g_fixup.sh pre|post <ORACLE_HOME>
#
# All three fixes were proven on the Phase-0 spike VM (ol9spike,
# 2026-10-26): 11g installed, linked and STARTED nomount on OL9U8 with
# exactly this recipe — there is no MOS cert note for 11g on EL9
# (OL8's is Doc 2988626.1 + patch 33991024); this is the lab-grade
# equivalent, and every piece is idempotent.
#
#   pre  (before runInstaller):
#     1. libpthread_nonshared.a STUB. EL9 glibc (>=2.34) folded pthread
#        into libc and deleted this archive; 11g's link lines still name
#        it -> 'cannot find /usr/lib64/libpthread_nonshared.a' was the
#        ONLY fatal genclntsh error (.dynsym 'local symbol' lines are
#        warnings on EL9's binutils).
#     2. libxcrypt-compat: the home's bundled perl wants libcrypt.so.1.
#     3. EL7 compat-libstdc++-33 rpm (grafted; no EL8/EL9 build exists).
#   post (after runInstaller, if bin/oracle is still the 0-byte zip
#     placeholder — the install's Make phase aborts on genclntsh before
#     building config.o, leaving a RACE ARTIFACT, not an incompatibility):
#     4. genclntsh, then compile rdbms/lib/config.c DIRECTLY (its 0-byte
#        config.o from the aborted run defines nothing -> 'undefined
#        reference to ss_dba_grp'), then make ioracle.
# ============================================================
set -u
PHASE=${1:?usage: $0 pre|post ORACLE_HOME}
OH=${2:-${ORACLE_HOME:-}}
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"
[ -n "$OH" ] || { echo "ORACLE_HOME required for post"; exit 1; }

if [ "$PHASE" = "pre" ]; then
  if [ ! -e /usr/lib64/libpthread_nonshared.a ]; then
    printf 'int __oracle_compat_stub(void){return 0;}\n' > /tmp/pstub.c
    $SUDO cc -c /tmp/pstub.c -o /tmp/pstub.o
    $SUDO ar rcs /tmp/libpthread_nonshared.a /tmp/pstub.o
    $SUDO cp /tmp/libpthread_nonshared.a /usr/lib64/libpthread_nonshared.a
    echo "STUB: /usr/lib64/libpthread_nonshared.a created"
  else
    echo "STUB: already present"
  fi
  rpm -q libxcrypt-compat >/dev/null 2>&1 || $SUDO dnf install -y libxcrypt-compat
  rpm -q compat-libstdc++-33 >/dev/null 2>&1 || {
    $SUDO curl -so /tmp/clsc.rpm https://yum.oracle.com/repo/OracleLinux/OL7/latest/x86_64/getPackage/compat-libstdc++-33-3.2.3-72.el7.x86_64.rpm \
      && $SUDO rpm -ivh --nodeps --replacefiles /tmp/clsc.rpm
  }
  exit 0
fi

# ---------------- post: repair the aborted Make phase ----------------
export ORACLE_HOME=$OH LD_LIBRARY_PATH=$OH/lib
if [ -s "$OH/bin/oracle" ]; then
  echo "oracle binary OK ($(stat -c %s $OH/bin/oracle) bytes) - no fixup needed"
  exit 0
fi
echo "bin/oracle is the 0-byte placeholder; replaying the failed link steps..."
$OH/bin/genclntsh >/tmp/genclntsh.out 2>&1 || { tail -5 /tmp/genclntsh.out; exit 1; }
cd "$OH/rdbms/lib" || exit 1
if [ ! -s config.o ]; then
  # 0-byte .o from the aborted install race: compile config.c directly.
  cc -c config.c -o config.o || { echo "config.c compile failed"; exit 1; }
fi
make -f ins_rdbms.mk ioracle >/tmp/ioracle.out 2>&1 || { tail -10 /tmp/ioracle.out; exit 1; }
if [ -s "$OH/bin/oracle" ]; then
  chmod 6751 "$OH/bin/oracle" 2>/dev/null || $SUDO chmod 6751 "$OH/bin/oracle"
  echo "RELINK OK: $(stat -c %s $OH/bin/oracle) bytes"
  # The bundled (2013) sqlplus binary RUNS on EL9 unmodified - do NOT
  # 'relink all': it fails ~18 EL9-era targets for nothing (spike lesson).
else
  echo "RELINK FAILED"; exit 1
fi
