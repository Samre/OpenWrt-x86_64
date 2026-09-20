#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Runs with the repository's working directory set to the OpenWrt tree
# (the workflow does `cd openwrt` before invoking this script).
# Every edit below is validated: a missing target or a no-op substitution
# must fail the build instead of silently shipping an unpatched firmware.

set -euo pipefail

# Preprocessor marker inserted into the shortcut-fe sources; also used to keep
# the insertion idempotent when the script runs more than once.
SFE_SUPPORT_IPV6_MARK="SFE_SUPPORT_IPV6 1"

# --- Default LAN IP ---------------------------------------------------------
# The firmware ships 192.168.216.10 instead of the upstream 192.168.1.1.
# WARNING: config_generate only creates /etc/config/network when no network
# config exists yet. Always confirm the address on a real image before release.
CONFIG_GENERATE="package/base-files/files/bin/config_generate"
[ -f "$CONFIG_GENERATE" ] \
  || { echo "::error::missing $CONFIG_GENERATE — upstream layout changed"; exit 1; }

if grep -qF '192.168.216.10' "$CONFIG_GENERATE"; then
  echo "  default LAN IP: already 192.168.216.10"
else
  before=$(md5sum "$CONFIG_GENERATE" | cut -d' ' -f1)
  sed -i 's/192\.168\.1\.1/192.168.216.10/g' "$CONFIG_GENERATE"
  after=$(md5sum "$CONFIG_GENERATE" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then
    echo "::error::default IP substitution did not change ${CONFIG_GENERATE}"
    exit 1
  fi
  grep -qF '192.168.216.10' "$CONFIG_GENERATE" \
    || { echo "::error::default IP substitution not verifiable in ${CONFIG_GENERATE}"; exit 1; }
  echo "  default LAN IP: 192.168.1.1 -> 192.168.216.10"
fi

# --- Clear the published default root password ------------------------------
# Upstream writes a well-known hash into /etc/shadow. If that hash is ever
# rotated upstream our sed stops matching, and the firmware would ship with a
# publicly known root credential. Hard-fail instead of shipping it.
DEFAULT_SETTINGS="package/lean/default-settings/files/zzz-default-settings"
[ -f "$DEFAULT_SETTINGS" ] \
  || { echo "::error::missing $DEFAULT_SETTINGS — upstream layout changed"; exit 1; }

if grep -qF 'V4UetPzk' "$DEFAULT_SETTINGS"; then
  before=$(md5sum "$DEFAULT_SETTINGS" | cut -d' ' -f1)
  sed -i 's/\$1\$V4UetPzk\$CYXluq4wUazHjmCDBCqXF\.//g' "$DEFAULT_SETTINGS"
  after=$(md5sum "$DEFAULT_SETTINGS" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then
    echo "::error::default password hash still present but the substitution changed nothing in ${DEFAULT_SETTINGS}"
    exit 1
  fi
  if grep -qF 'V4UetPzk' "$DEFAULT_SETTINGS"; then
    echo "::error::default password hash still present in ${DEFAULT_SETTINGS}"
    exit 1
  fi
  echo "  root password hash: cleared (login without password until changed)"
else
  echo "  root password hash: not present, nothing to clear"
fi

# --- shortcut-fe kernel compatibility ---------------------------------------
# The pinned source still uses APIs that Linux 6.18 dropped or renamed:
#   * timer_setup() callbacks use from_timer(), removed in 6.10
#     (timer_container_of() replaced it).
#   * del_timer_sync() was renamed timer_delete_sync().
# Without these rewrites the kmod-shortcut-fe/kmod-shortcut-fe-cm packages in
# .config fail to compile.
SHORTCUT_SRC="${SHORTCUT_SRC:-package/qca/shortcut-fe/shortcut-fe/src}"
if [ ! -d "$SHORTCUT_SRC" ]; then
  echo "::error::${SHORTCUT_SRC} is missing but .config selects kmod-shortcut-fe/kmod-shortcut-fe-cm"
  exit 1
fi

# IPv6 entry points: sfe_cm.h chooses with `#ifdef SFE_SUPPORT_IPV6` between an
# extern declaration and a do-nothing static-inline stub. The package Makefile
# passes EXTRA_CFLAGS+="-DSFE_SUPPORT_IPV6", but the package builds three
# modules (shortcut-fe, shortcut-fe-ipv6, shortcut-fe-cm) from this one source
# tree and the macro does not reach every translation unit. Whichever unit
# reaches sfe_cm.h without it defines stubs whose names collide with the real
# functions in sfe_ipv6.c:
#
#   sfe_ipv6.c:1015: error: redefinition of 'sfe_ipv6_mark_rule'
#   sfe_cm.h:206: note: previous definition of 'sfe_ipv6_destroy_all_rules_for_dev'
#
# Defining the macro once in sfe.h, which every .c file includes before
# sfe_cm.h, makes all units agree. The #ifndef guard keeps it a no-op where the
# command line already provides it.
for src in sfe_ipv4.c sfe_ipv6.c sfe_cm.c; do
  [ -f "$SHORTCUT_SRC/$src" ] || { echo "::error::missing $SHORTCUT_SRC/$src"; exit 1; }
done
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::sfe_ipv4.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::sfe_ipv6.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }
grep -q '^#include "sfe\.h"' "$SHORTCUT_SRC/sfe_cm.c" \
  || { echo "::error::sfe_cm.c no longer includes sfe.h; the SFE_SUPPORT_IPV6 define would not be visible"; exit 1; }

if ! grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h"; then
  # Anchor on the first code line in sfe.h. Anchoring on the license text is
  # unsafe: "OF THIS SOFTWARE" occurs twice in that comment block and sed
  # inserts before the first match, which would bury the define in a comment.
  grep -q '^#define DEBUG_LEVEL' "$SHORTCUT_SRC/sfe.h" \
    || { echo "::error::cannot locate the sfe.h insertion point (no DEBUG_LEVEL define)"; exit 1; }
  sed -i '/^#define DEBUG_LEVEL/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe.h"
  echo "  sfe.h: SFE_SUPPORT_IPV6 defined for every translation unit"
fi
grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h" \
  || { echo "::error::SFE_SUPPORT_IPV6 missing from sfe.h"; exit 1; }
# Exactly one copy, and after the license block so it cannot land inside a
# comment (both would break or silently disable the define).
n=$(grep -c "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h")
[ "$n" -eq 1 ] || { echo "::error::SFE_SUPPORT_IPV6 appears ${n} times in sfe.h"; exit 1; }
define_line=$(grep -n "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe.h" | cut -d: -f1)
license_end=$(grep -n '^[[:space:]]*\*/' "$SHORTCUT_SRC/sfe.h" | head -n1 | cut -d: -f1)
[ -n "$license_end" ] \
  || { echo "::error::could not locate the end of the sfe.h license block"; exit 1; }
[ "$define_line" -gt "$license_end" ] \
  || { echo "::error::SFE_SUPPORT_IPV6 landed inside the sfe.h license comment"; exit 1; }

# from_timer(si, tl, timer) -> container_of(tl, struct sfe_ipvN, timer)
# del_timer_sync(&si->timer) -> timer_delete_sync(&si->timer)
# Only rewrite what is still old, so re-running the script is harmless.
for entry in sfe_ipv4.c:sfe_ipv4 sfe_ipv6.c:sfe_ipv6; do
  file="${entry%%:*}"
  struct_name="${entry##*:}"
  path="$SHORTCUT_SRC/$file"

  if grep -qE '\bfrom_timer[[:space:]]*\(' "$path"; then
    sed -i "s/from_timer(si, tl, timer)/container_of(tl, struct ${struct_name}, timer)/g" "$path"
    echo "  ${file}: from_timer() -> container_of()"
  fi
  if grep -qE '\bdel_timer_sync[[:space:]]*\(' "$path"; then
    sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$path"
    echo "  ${file}: del_timer_sync() -> timer_delete_sync()"
  fi

  if grep -qE '\bfrom_timer[[:space:]]*\(' "$path"; then
    echo "::error::from_timer() still present in ${path} — source pattern changed, update the sed pattern"
    exit 1
  fi
  if grep -qE '\bdel_timer_sync[[:space:]]*\(' "$path"; then
    echo "::error::del_timer_sync() still present in ${path} — source pattern changed, update the sed pattern"
    exit 1
  fi
done

grep -qE '\bcontainer_of\(tl, struct sfe_ipv4, timer\)' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::container_of replacement missing from sfe_ipv4.c"; exit 1; }
grep -qE '\bcontainer_of\(tl, struct sfe_ipv6, timer\)' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::container_of replacement missing from sfe_ipv6.c"; exit 1; }
grep -qE '\btimer_delete_sync[[:space:]]*\(' "$SHORTCUT_SRC/sfe_ipv4.c" \
  || { echo "::error::timer_delete_sync replacement missing from sfe_ipv4.c"; exit 1; }
grep -qE '\btimer_delete_sync[[:space:]]*\(' "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::timer_delete_sync replacement missing from sfe_ipv6.c"; exit 1; }

# sfe_cm.c reads the "no window check" conntrack setting. Linux 6.18 removed it
# from struct nf_tcp_net entirely, while the source still guards the read with
# `>= 5.15` and so takes that branch:
#     sfe_cm.c:514: error: 'struct nf_tcp_net' has no member named 'tcp_no_window_check'
# Drop the removed member and leave the equivalent tcp_be_liberal test, which
# still determines SFE_CREATE_FLAG_NO_SEQ_CHECK on every supported kernel.
SFE_CM="$SHORTCUT_SRC/sfe_cm.c"
if grep -qF 'tcp_no_window_check' "$SFE_CM"; then
  before=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  sed -i \
    -e '/^[[:space:]]*struct net \*net=NULL;$/d' \
    -e '/^[[:space:]]*struct nf_tcp_net \*tn=NULL;$/d' \
    -e '\|^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)$|,\|^#endif$|c\
if ((ct->proto.tcp.seen[0].flags \& IP_CT_TCP_FLAG_BE_LIBERAL)' \
    "$SFE_CM"
  after=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  [ "$before" != "$after" ] \
    || { echo "::error::6.18 nf_tcp_net patch changed nothing in ${SFE_CM}"; exit 1; }
  echo "  sfe_cm.c: dropped the nf_tcp_net->tcp_no_window_check read (removed in 6.18)"
fi

# Assert the result compiles on the 6.18 header: no reference to the removed
# member may survive in either branch, and the remaining condition must still
# decide SFE_CREATE_FLAG_NO_SEQ_CHECK.
if grep -qF 'tcp_no_window_check' "$SFE_CM"; then
  echo "::error::${SFE_CM} still references tcp_no_window_check, which Linux 6.18 does not provide"
  exit 1
fi
grep -qF 'if ((ct->proto.tcp.seen[0].flags & IP_CT_TCP_FLAG_BE_LIBERAL)' "$SFE_CM" \
  || { echo "::error::liberal-flag condition missing from ${SFE_CM}"; exit 1; }

echo "All DIY part 2 edits verified."
