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
