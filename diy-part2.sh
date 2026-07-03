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

# Modify default IP
sed -i 's/192.168.1.1/192.168.216.10/g' package/base-files/files/bin/config_generate

#2. Clear the login password
sed -i 's/$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.//g' package/lean/default-settings/files/zzz-default-settings

# Patch shortcut-fe for Linux 6.18+ compatibility
SHORTCUT_SRC="package/qca/shortcut-fe/shortcut-fe/src"
if [ -d "$SHORTCUT_SRC" ]; then
  # Fix: SFE_SUPPORT_IPV6 not passed to compiler in kernel 6.18
  # Add define before sfe_cm.h include in sfe_ipv6.c
  sed -i '/^#include "sfe_cm.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_ipv6.c"
  # Also need SFE_SUPPORT_IPV6 in sfe_cm.c to avoid unused function error
  sed -i '/^#include "sfe.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_cm.c"
  # Replace from_timer() with container_of()
  sed -i 's/from_timer(si, tl, timer)/container_of(tl, struct sfe_ipv4, timer)/g' "$SHORTCUT_SRC/sfe_ipv4.c"
  sed -i 's/from_timer(si, tl, timer)/container_of(tl, struct sfe_ipv6, timer)/g' "$SHORTCUT_SRC/sfe_ipv6.c"
  # Replace del_timer_sync() with timer_delete_sync()
  sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$SHORTCUT_SRC/sfe_ipv4.c"
  sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$SHORTCUT_SRC/sfe_ipv6.c"
  # Fix: tcp_no_window_check removed from nf_tcp_net in kernel 6.18
  sed -i 's/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0) \&\& LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)/' "$SHORTCUT_SRC/sfe_cm.c"
  # Fix: nf_ct_tcp_no_window_check also removed in 6.18, replace with 0
  sed -i 's/nf_ct_tcp_no_window_check/0/' "$SHORTCUT_SRC/sfe_cm.c"
  echo "shortcut-fe patched for Linux 6.18+"
fi

# ─────────────────────────────────────────────────────
# Patch ai-monitor: CRLF / BOM / nil guards / CPU calc
# ─────────────────────────────────────────────────────
echo "Patching ai-monitor for runtime fixes..."

# Fix CRLF in all ai-monitor scripts + suppress source loop output pollution
for f in $(find package -path "*/ai-monitor/src/*.sh" -o -path "*/ai-monitor/*.init" 2>/dev/null); do
  sed -i 's/\r//g' "$f"
  [ "$(basename "$f")" = "ai-monitor.sh" ] && \
    sed -i 's|. "$lib"|. "$lib" >/dev/null 2>\&1|' "$f"
done

# Fix collector.sh: replace CPU calculation (usr% → 100-idle%)
COLL=$(find package -path "*/ai-monitor/src/collector.sh" 2>/dev/null | head -1)
if [ -f "$COLL" ]; then
  awk 'BEGIN{p=0}
    /^collect_cpu\(\)/ {p=1; print "collect_cpu() {"
      print "local idle=$(top -bn1 2>/dev/null | grep \"^CPU:\" | grep -o \"[0-9]*% idle\" | grep -o \"[0-9]*\")"
      print "local cpu=$((100 - ${idle:-100}))"
      print "echo \"${cpu:-0}\" | tr -d \"\\n\\r\""
      print "}"; next}
    /^[a-z_]+\(\)/ {if(p){p=0}}
    !p' "$COLL" > /tmp/ai_collector_fix && mv /tmp/ai_collector_fix "$COLL"
fi

# Fix LuCI templates: remove BOM + fix CRLF + nil guard
for tmpl in $(find package -path "*/luci-app-ai-monitor/*.htm" -type f 2>/dev/null); do
  tail -c +4 "$tmpl" 2>/dev/null > /tmp/ai_bom_fix && mv /tmp/ai_bom_fix "$tmpl"
  sed -i 's/\r//g' "$tmpl"
  sed -i 's/tonumber(\(snap\.[a-z_]*\))/(tonumber(\1) or 0)/g' "$tmpl"
done

echo "ai-monitor patches applied"