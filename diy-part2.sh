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
# Patch ai-monitor: BOM / CRLF / nil guards / CPU calc
# ─────────────────────────────────────────────────────
echo "Patching ai-monitor for runtime fixes..."

# Step 1: Strip BOM (UTF-8 EF BB BF) and CRLF from ALL ai-monitor text files
# Covers: .sh, .init, .htm, .lua in package/lean/ai-monitor and luci-app-ai-monitor
# BOM in .sh causes shebang failure; BOM in .htm causes template parse errors
for f in $(find package -path "*/ai-monitor/files/*.sh" \
                     -o -path "*/ai-monitor/files/lib/*.sh" \
                     -o -path "*/ai-monitor/files/*.init" \
                     -o -path "*/luci-app-ai-monitor/luasrc/*.htm" \
                     -o -path "*/luci-app-ai-monitor/luasrc/*.lua" \
                     -o -path "*/luci-app-ai-monitor/root/*.lua" \
                     2>/dev/null); do
  # Strip BOM only if present (first 3 bytes = EF BB BF)
  if [ "$(head -c 3 "$f" 2>/dev/null)" = "$(printf '\xef\xbb\xbf')" ]; then
    tail -c +4 "$f" > /tmp/ai_fix_tmp && mv /tmp/ai_fix_tmp "$f"
  fi
  # Strip CRLF → LF
  sed -i 's/\r//g' "$f" 2>/dev/null
done

# Step 2: Suppress source loop noise in ai-monitor.sh
AI_SH=$(find package -path "*/ai-monitor/files/ai-monitor.sh" 2>/dev/null | head -1)
if [ -f "$AI_SH" ]; then
  sed -i 's|. "$lib"|. "$lib" >/dev/null 2>\&1|' "$AI_SH"
fi

# Step 3: Fix collector.sh CPU calculation (usr% → 100-idle%)
COLL=$(find package -path "*/ai-monitor/files/lib/collector.sh" 2>/dev/null | head -1)
if [ -f "$COLL" ]; then
  awk 'BEGIN{p=0}
    /^collect_cpu\(\)/ {p=1; print "collect_cpu() {"
      print "local idle=$(top -bn1 2>/dev/null | grep \"^CPU:\" | grep -o \"[0-9]*% idle\" | grep -o \"[0-9]*\")"
      print "local cpu=$((100 - ${idle:-100}))"
      print "echo \"${cpu:-0}\" | tr -d \"\\\\n\\\\r\""
      print "}"; next}
    /^[a-z_]+\(\)/ {if(p){p=0}}
    !p' "$COLL" > /tmp/ai_collector_fix && mv /tmp/ai_collector_fix "$COLL"
fi

# Step 4: Fix LuCI template nil guard (tonumber(nil) → 0)
for tmpl in $(find package -path "*/luci-app-ai-monitor/luasrc/view/*.htm" -type f 2>/dev/null); do
  sed -i 's/tonumber(\(snap\.[a-z_]*\))/(tonumber(\1) or 0)/g' "$tmpl"
done

# Step 5: Inject Netdata-style dashboard and enhanced reporter
OVERLAY="$GITHUB_WORKSPACE/ai-monitor-overlay"
if [ -d "$OVERLAY" ]; then
  # Replace dashboard with Netdata-inspired version
  DASH=$(find package -path "*/luci-app-ai-monitor/luasrc/view/ai-monitor/dashboard.htm" -type f 2>/dev/null | head -1)
  if [ -f "$DASH" ] && [ -f "$OVERLAY/dashboard.htm" ]; then
    cp "$OVERLAY/dashboard.htm" "$DASH" && echo "ai-monitor: Netdata dashboard injected"
  fi
  # Replace reporter with enhanced version (disk/rx/tx chart data)
  REP=$(find package -path "*/ai-monitor/files/lib/reporter.sh" -type f 2>/dev/null | head -1)
  if [ -f "$REP" ] && [ -f "$OVERLAY/reporter.sh" ]; then
    cp "$OVERLAY/reporter.sh" "$REP" && echo "ai-monitor: enhanced reporter injected"
  fi
fi

echo "ai-monitor patches applied"
