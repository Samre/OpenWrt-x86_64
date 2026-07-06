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
  sed -i '/^#include "sfe_cm.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_ipv6.c"
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

# ============================================================
# Patch ai-monitor: BOM / CRLF / nil guards / CPU calc
# ============================================================
echo "Patching ai-monitor for runtime fixes..."

# Step 1: Strip BOM and CRLF from ALL ai-monitor text files
echo "Stripping BOM and CRLF from ai-monitor files..."
for f in $(find package -path "*/ai-monitor/files/*.sh" \
                     -o -path "*/ai-monitor/files/lib/*.sh" \
                     -o -path "*/ai-monitor/files/*.init" \
                     -o -path "*/luci-app-ai-monitor/*" -name "*.htm" \
                     -o -path "*/luci-app-ai-monitor/*" -name "*.lua" \
                     2>/dev/null); do
  # Strip BOM from first line
  if head -c 3 "$f" 2>/dev/null | cmp -s - <(printf '\xef\xbb\xbf') 2>/dev/null; then
    tail -c +4 "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    echo "  BOM removed: $(basename "$f")"
  fi
  # Strip CRLF -> LF
  sed -i 's/\r//g' "$f" 2>/dev/null
  echo "  Fixed: $(basename "$f")"
done


# Step 2.5: Fix ai-monitor Makefile — remove missing hard dependencies
# curl/coreutils/coreutils-stat/sqlite3-cli not in feeds → build fails
AI_MK=$(find package -path "*/ai-monitor/Makefile" -type f 2>/dev/null | head -1)
if [ -f "$AI_MK" ]; then
  sed -i "s/DEPENDS:=+curl +coreutils +coreutils-stat +sqlite3-cli/DEPENDS:=/" "$AI_MK"
  echo "  ai-monitor Makefile: hard deps removed"
fi

# Step 3: Fix collect_cpu - use /proc/stat (no top/nproc dependency)
COLL=$(find package -path "*/ai-monitor/files/lib/collector.sh" 2>/dev/null | head -1)
if [ -f "$COLL" ]; then
  awk 'BEGIN{p=0}
    /^collect_cpu\(\)/ {p=1; print "collect_cpu() {"
      print "  local cpu=$(awk '\''/^cpu /{total=$2+$3+$4+$5+$6+$7+$8;idle=$5;if(total>0)printf \"%.0f\",(total-idle)*100/total;else print \"0\"}'\'' /proc/stat 2>/dev/null)"
      print "  [ -z \"$cpu\" ] && cpu=$(awk '\''{printf \"%.0f\",$1*100}'\'' /proc/loadavg 2>/dev/null)"
      print "  echo \"${cpu:-0}\""
      print "}"; next}
    /^[a-z_]+\(\)/ {if(p){p=0}}
    !p' "$COLL" > /tmp/ai_collector_fix && mv /tmp/ai_collector_fix "$COLL"
  echo "  collect_cpu patched: /proc/stat + loadavg fallback"
fi

# Step 5: Fix LuCI template nil guard
for tmpl in $(find package -path "*/luci-app-ai-monitor/luasrc/view/*.htm" -type f 2>/dev/null); do
  sed -i 's/tonumber(\(snap\.[a-z_]*\))/(tonumber(\1) or 0)/g' "$tmpl"
done

# Step 5: Inject overlay files (dashboard, log, reporter)
OVERLAY="$GITHUB_WORKSPACE/ai-monitor-overlay"
if [ -d "$OVERLAY" ]; then
  DASH=$(find package -path "*/luci-app-ai-monitor/luasrc/view/ai-monitor/dashboard.htm" -type f 2>/dev/null | head -1)
  if [ -f "$DASH" ] && [ -f "$OVERLAY/dashboard.htm" ]; then
    cp "$OVERLAY/dashboard.htm" "$DASH" && echo "ai-monitor: dashboard injected"
  fi
  LOG=$(find package -path "*/luci-app-ai-monitor/luasrc/view/ai-monitor/log.htm" -type f 2>/dev/null | head -1)
  if [ -f "$LOG" ] && [ -f "$OVERLAY/log.htm" ]; then
    cp "$OVERLAY/log.htm" "$LOG" && echo "ai-monitor: log.htm injected"
  fi
  REP=$(find package -path "*/ai-monitor/files/lib/reporter.sh" -type f 2>/dev/null | head -1)
  if [ -f "$REP" ] && [ -f "$OVERLAY/reporter.sh" ]; then
    cp "$OVERLAY/reporter.sh" "$REP" && echo "ai-monitor: enhanced reporter injected"
  fi
fi

# Step 7: Post-injection CRLF cleanup (belt-and-suspenders for overlay files)
echo "Post-injection CRLF cleanup..."
for f in $(find package -path "*/ai-monitor/files/*.sh" \
                     -o -path "*/ai-monitor/files/lib/*.sh" \
                     -o -path "*/ai-monitor/files/*.init" \
                     -o -path "*/luci-app-ai-monitor/*" -name "*.htm" \
                     -o -path "*/luci-app-ai-monitor/*" -name "*.lua" \
                     2>/dev/null); do
  sed -i 's/\r//g' "$f" 2>/dev/null
done

echo "ai-monitor patches applied"
