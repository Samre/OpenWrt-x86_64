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


#5. Remove packages causing build failures (mihomo/nikki/fchomo)
#    These are auto-selected by proxy packages, Kconfig "select" overrides user disable.
#    The only reliable way is to remove the package directories entirely.
#    Also fixes recursive dependency: luci-app-fchomo -> nikki -> firewall4 (circular)
echo "# CONFIG_PACKAGE_mihomo is not set" >> .config
echo "# CONFIG_PACKAGE_nikki is not set" >> .config
echo "# CONFIG_PACKAGE_luci-app-fchomo is not set" >> .config
echo "# CONFIG_PACKAGE_luci-app-nikki is not set" >> .config
rm -rf feeds/small/mihomo feeds/small/luci-app-fchomo feeds/small/luci-app-nikki feeds/packages/net/nikki feeds/small/trojan-go feeds/packages/utils/docker-compose 2>/dev/null || true
echo "  Removed mihomo/nikki/fchomo package dirs"

#5b. Disable docker-compose (Go build failure on Ubuntu 24.04)
echo "# CONFIG_PACKAGE_docker-compose is not set" >> .config

#6. Disable kmod-sound-hda-codec-realtek (snd-hda-codec-realtek-lib.ko missing in Linux 6.18+)
echo "# CONFIG_PACKAGE_kmod-sound-hda-codec-realtek is not set" >> .config

#7. Fix shortcut-fe kernel module for Linux 6.18+
#    Linux 6.13+ REMOVED from_timer() and del_timer_sync() entirely.
#    Replace with container_of() and inline timer_delete_sync().
#    Also add missing <linux/timer.h> and remove -Werror.
SHORTCUT_FE_SRC="package/qca/shortcut-fe/shortcut-fe/src"
if [ -d "$SHORTCUT_FE_SRC" ]; then
  echo "=== Fixing shortcut-fe for Linux 6.18+ ==="

  # Add <linux/timer.h> include to sfe_ipv4.c and sfe_ipv6.c
  for f in "$SHORTCUT_FE_SRC/sfe_ipv4.c" "$SHORTCUT_FE_SRC/sfe_ipv6.c"; do
    if [ -f "$f" ] && ! grep -q '<linux/timer.h>' "$f"; then
      sed -i '/#include <linux\/version.h>/i #include <linux/timer.h>' "$f"
      echo "  Added #include <linux/timer.h> to $f"
    fi

    # Replace from_timer() -> container_of() (from_timer was removed in Linux 6.13+)
    # Pattern: from_timer(si, tl, timer) => container_of(tl, typeof(*si), timer)
    sed -i 's/from_timer(si, tl, timer)/container_of(tl, typeof(*si), timer)/g' "$f"
    echo "  Replaced from_timer() -> container_of() in $f"

    # Replace del_timer_sync() -> timer_delete_sync() (removed in Linux 6.13+)
    sed -i 's/del_timer_sync(&si->timer)/timer_delete_sync(\&si->timer)/g' "$f"
    echo "  Replaced del_timer_sync() -> timer_delete_sync() in $f"
  done


  # Patch sfe_cm.c: tcp_no_window_check removed in Linux 6.18+
  if [ -f "$SHORTCUT_FE_SRC/sfe_cm.c" ]; then
    sed -i 's/tn->tcp_no_window_check)/0) \/* tcp_no_window_check removed in Linux 6.18+ *\//' "$SHORTCUT_FE_SRC/sfe_cm.c"
    echo "  Patched sfe_cm.c for Linux 6.18+"
  fi

  # Add DSFE_SUPPORT_IPV6 to ccflags if not present
  if ! grep -q "DSFE_SUPPORT_IPV6" "$SHORTCUT_FE_SRC/Makefile"; then
    sed -i '/^ccflags-y/s/$/ -DSFE_SUPPORT_IPV6/' "$SHORTCUT_FE_SRC/Makefile"
    echo "  Added DSFE_SUPPORT_IPV6 to Makefile"
  fi
  # Remove -Werror to avoid deprecation warnings becoming errors
  sed -i 's/-Werror/-Wno-deprecated-declarations/g' "$SHORTCUT_FE_SRC/Makefile"
  echo "  Replaced -Werror with -Wno-deprecated-declarations in src/Makefile"
fi
