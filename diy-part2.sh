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

REPO_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"

# Modify default IP
sed -i 's/192.168.1.1/192.168.216.10/g' package/base-files/files/bin/config_generate

# Clear the login password
sed -i 's/$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.//g' package/lean/default-settings/files/zzz-default-settings

# Patch shortcut-fe for Linux 6.18+ compatibility
SHORTCUT_SRC="package/qca/shortcut-fe/shortcut-fe/src"
if [ -d "$SHORTCUT_SRC" ]; then
  if ! grep -q "SFE_SUPPORT_IPV6 1" "$SHORTCUT_SRC/sfe_ipv6.c" 2>/dev/null; then
    sed -i '/^#include "sfe_cm.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_ipv6.c"
  fi
  if ! grep -q "SFE_SUPPORT_IPV6 1" "$SHORTCUT_SRC/sfe_cm.c" 2>/dev/null; then
    sed -i '/^#include "sfe.h"/i #ifndef SFE_SUPPORT_IPV6\n#define SFE_SUPPORT_IPV6 1\n#endif' "$SHORTCUT_SRC/sfe_cm.c"
  fi
  sed -i 's/from_timer(si, tl, timer)/container_of(tl, struct sfe_ipv4, timer)/g' "$SHORTCUT_SRC/sfe_ipv4.c"
  sed -i 's/from_timer(si, tl, timer)/container_of(tl, struct sfe_ipv6, timer)/g' "$SHORTCUT_SRC/sfe_ipv6.c"
  sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$SHORTCUT_SRC/sfe_ipv4.c"
  sed -i 's/del_timer_sync(\&si->timer)/timer_delete_sync(\&si->timer)/g' "$SHORTCUT_SRC/sfe_ipv6.c"
  sed -i 's/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0) \&\& LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)/' "$SHORTCUT_SRC/sfe_cm.c"
  sed -i 's/nf_ct_tcp_no_window_check/0/' "$SHORTCUT_SRC/sfe_cm.c"
  echo "shortcut-fe patched for Linux 6.18+"
fi

# Add tgpt - AI chatbot in terminal (Go binary, zero deps)
echo "Installing tgpt AI chatbot..."
mkdir -p files/usr/bin
TGPT_URL=$(curl -s https://api.github.com/repos/aandrew-me/tgpt/releases/latest | grep "browser_download_url.*linux-amd64" | head -1 | cut -d'"' -f4)
if [ -n "$TGPT_URL" ]; then
  curl -sL "$TGPT_URL" -o files/usr/bin/tgpt && chmod +x files/usr/bin/tgpt
  echo "  tgpt installed ($(du -h files/usr/bin/tgpt | cut -f1))"
else
  echo "  WARNING: tgpt download failed"
fi
