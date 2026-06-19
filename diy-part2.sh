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

#3. Fix ddnsto download URL (upstream repo restructured)
sed -i 's|PKG_SOURCE_URL:=https://github.com/linkease/ddnsto-openwrt-package/raw/refs/heads/main/|PKG_SOURCE_URL:=https://github.com/linkease/ddnsto-binary/raw/refs/heads/main/$(PKG_SOURCE_DATE)/|' feeds/kenzo/ddnsto/Makefile

#4. Disable haproxy (SSL variant fails to compile on Ubuntu 24.04 with OpenSSL 3.x)
sed -i 's/^CONFIG_PACKAGE_haproxy=y/# CONFIG_PACKAGE_haproxy is not set/' .config
sed -i 's/^CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy=y/# CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy is not set/' .config
sed -i 's/^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy is not set/' .config

#5. Fix shortcut-fe kernel module for Linux 6.18+
#    Linux 6.18 removed transitive includes of <linux/timer.h>,
#    causing implicit declaration errors for from_timer() and del_timer_sync().
#    Using OpenWrt patch mechanism so it applies during prepare phase.
SHORTCUT_FE_DIR="package/qca/shortcut-fe/shortcut-fe"
if [ -d "$SHORTCUT_FE_DIR" ]; then
  echo "=== Creating shortcut-fe patches for Linux 6.18+ ==="
  mkdir -p "$SHORTCUT_FE_DIR/patches"

  # Patch 1: Add missing <linux/timer.h> to sfe_ipv4.c
  cat > "$SHORTCUT_FE_DIR/patches/001-add-timer-include-ipv4.patch" << 'PATCH_EOF'
--- a/src/sfe_ipv4.c
+++ b/src/sfe_ipv4.c
@@ -22,6 +22,7 @@
 #include <linux/icmp.h>
 #include <net/tcp.h>
 #include <linux/etherdevice.h>
+#include <linux/timer.h>
 #include <linux/version.h>
 
 #include "sfe.h"
PATCH_EOF

  # Patch 2: Add missing <linux/timer.h> to sfe_ipv6.c
  cat > "$SHORTCUT_FE_DIR/patches/002-add-timer-include-ipv6.patch" << 'PATCH_EOF'
--- a/src/sfe_ipv6.c
+++ b/src/sfe_ipv6.c
@@ -22,6 +22,7 @@
 #include <linux/icmp.h>
 #include <net/tcp.h>
 #include <linux/etherdevice.h>
+#include <linux/timer.h>
 #include <linux/version.h>
 
 #include "sfe.h"
PATCH_EOF

  # Patch 3: Remove -Werror from src/Makefile
  cat > "$SHORTCUT_FE_DIR/patches/003-remove-werror.patch" << 'PATCH_EOF'
--- a/src/Makefile
+++ b/src/Makefile
@@ -20,4 +20,4 @@ shortcut-fe-cm-objs := \
 	sfe_cm.o
 
-ccflags-y += -Werror -Wall
+ccflags-y += -Wall
PATCH_EOF

  echo "  3 patch files created in $SHORTCUT_FE_DIR/patches/"
fi