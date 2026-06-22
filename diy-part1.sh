#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

echo "src-git istore https://github.com/linkease/istore;main" >> ./feeds.conf.default
echo "src-git kenzo https://github.com/kenzok8/openwrt-packages" >> ./feeds.conf.default
echo "src-git small https://github.com/kenzok8/small" >> ./feeds.conf.default
echo "src-git wrtbwmon https://github.com/brvphoenix/wrtbwmon" >> ./feeds.conf.default

# 6. Add tunnel/intranet penetration feeds (???????
echo "src-git frp https://github.com/kuoruan/openwrt-frp;master" >> ./feeds.conf.default
echo "src-git zerotier https://github.com/mwarning/zerotier-openwrt;master" >> ./feeds.conf.default
echo "src-git tailscale https://github.com/adyanth/openwrt-tailscale-enabler;main" >> ./feeds.conf.default
echo "src-git natmap https://github.com/muink/openwrt-natmap;master" >> ./feeds.conf.default
echo "src-git lucky https://github.com/gdy666/luci-app-lucky;main" >> ./feeds.conf.default


# 7. Fix Go module downloads (proxy.golang.org unreliable from GitHub Actions)
export GOPROXY="https://goproxy.cn,https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"
export GO111MODULE="on"
echo "GOPROXY=$GOPROXY"

# Free up disk space on GitHub Actions runner
# The runner has ~28GB total; OpenWrt build with many packages easily exceeds this
echo "=== Before cleanup ==="
df -hT $PWD

echo "Removing unnecessary pre-installed tools..."
sudo rm -rf \
  /usr/local/lib/android \
  /opt/ghc \
  /usr/local/.ghcup \
  /usr/share/dotnet \
  /usr/local/share/powershell \
  /usr/local/share/chromium \
  /usr/local/lib/node_modules 2>/dev/null || true

echo "=== After cleanup ==="
df -hT $PWD
