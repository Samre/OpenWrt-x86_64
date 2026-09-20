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

# IPv6 hooks: shortcut-fe/Makefile only passes SFE_SUPPORT_IPV6=y as a make
# variable to kbuild, so it never becomes a C preprocessor macro. Define it in
# the sources to enable the IPv6 hooks. The guard keeps the script idempotent.
for src in sfe_ipv6.c sfe_cm.c; do
  file="$SHORTCUT_SRC/$src"
  [ -f "$file" ] || { echo "::error::missing $file"; exit 1; }
done

if ! grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe_ipv6.c"; then
  sed -i '/^#include "sfe_cm.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_ipv6.c"
  echo "  sfe_ipv6.c: SFE_SUPPORT_IPV6 guard inserted"
fi
if ! grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe_cm.c"; then
  sed -i '/^#include "sfe.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_cm.c"
  echo "  sfe_cm.c: SFE_SUPPORT_IPV6 guard inserted"
fi
grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe_ipv6.c" \
  || { echo "::error::SFE_SUPPORT_IPV6 guard missing from sfe_ipv6.c"; exit 1; }
grep -q "$SFE_SUPPORT_IPV6_MARK" "$SHORTCUT_SRC/sfe_cm.c" \
  || { echo "::error::SFE_SUPPORT_IPV6 guard missing from sfe_cm.c"; exit 1; }

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

# The 5.15-only branch in sfe_cm.c reads the global nf_ct_tcp_no_window_check,
# which Linux 6.18 no longer defines (it moved to the per-netns nf_tcp_net and
# is read through tn->tcp_no_window_check). The pinned source already has the
# version guard in a form sed cannot match reliably, and on a 6.12 fallback
# kernel the #else branch is compiled and would fail to build. Neutralize the
# dead branch explicitly instead of relying on a brittle text substitution.
SFE_CM="$SHORTCUT_SRC/sfe_cm.c"
if grep -qF 'nf_ct_tcp_no_window_check' "$SFE_CM"; then
  before=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  sed -i 's/nf_ct_tcp_no_window_check/0/g' "$SFE_CM"
  after=$(md5sum "$SFE_CM" | cut -d' ' -f1)
  [ "$before" != "$after" ] \
    || { echo "::error::nf_ct_tcp_no_window_check neutralization changed nothing in ${SFE_CM}"; exit 1; }
  echo "  sfe_cm.c: 5.15-only global neutralized (branch is inactive on 6.18)"
fi

# Confirm the resulting source still contains the version-checked 6.18 path.
grep -q 'tn->tcp_no_window_check' "$SFE_CM" \
  || echo "::warning::${SFE_CM} no longer references tn->tcp_no_window_check — recheck the 6.18 path"

echo "All DIY part 2 edits verified."
