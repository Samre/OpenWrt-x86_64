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
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

sed -i 's/192.168.1.1/192.168.216.10/g' package/base-files/files/bin/config_generate

#2. Clear the login password
sed -i 's/$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.//g' package/lean/default-settings/files/zzz-default-settings

#3. Fix ddnsto download URL (upstream repo restructured)
sed -i 's|PKG_SOURCE_URL:=https://github.com/linkease/ddnsto-openwrt-package/raw/refs/heads/main/|PKG_SOURCE_URL:=https://github.com/linkease/ddnsto-binary/raw/refs/heads/main/$(PKG_SOURCE_DATE)/|' feeds/kenzo/ddnsto/Makefile

#4. Disable haproxy (SSL variant fails to compile on Ubuntu 24.04 with OpenSSL 3.x)
sed -i 's/^CONFIG_PACKAGE_haproxy=y/# CONFIG_PACKAGE_haproxy is not set/' .config
sed -i 's/^CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy=y/# CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy is not set/' .config
sed -i 's/^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy is not set/' .config

#5. Fix shortcut-fe kernel module for Linux 6.18+
#    Linux 6.18 removed transitive includes of <linux/timer.h>,
#    causing implicit declaration errors for from_timer() and del_timer_sync().
#    Ref: sfe_ipv4.c:2868 / sfe_ipv6.c:2876 (from_timer)
#         sfe_ipv4.c:3588 / sfe_ipv6.c:3596 (del_timer_sync)
SHORTCUT_FE_SRC="package/qca/shortcut-fe/shortcut-fe/src"
if [ -d "$SHORTCUT_FE_SRC" ]; then
  echo "=== Fixing shortcut-fe for Linux 6.18+ ==="

  # Add missing <linux/timer.h> include (from_timer, del_timer_sync)
  for f in "$SHORTCUT_FE_SRC/sfe_ipv4.c" "$SHORTCUT_FE_SRC/sfe_ipv6.c"; do
    if [ -f "$f" ] && ! grep -q '<linux/timer.h>' "$f"; then
      sed -i '/#include <linux\/version.h>/a #include <linux/timer.h>' "$f"
      echo "  Added #include <linux/timer.h> to $f"
    fi
  done

  # Remove -Werror to avoid deprecation warnings becoming errors
  sed -i 's/-Werror//g' "$SHORTCUT_FE_SRC/Makefile"
  echo "  Removed -Werror from shortcut-fe src/Makefile"
fi