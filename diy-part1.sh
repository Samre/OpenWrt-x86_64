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
# Runs with the repository's working directory set to the OpenWrt tree
# (the workflow does `cd openwrt` before invoking this script), so relative
# paths land inside the OpenWrt checkout.

set -euo pipefail

# --- Extra feed sources -----------------------------------------------------
# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

[ -f ./feeds.conf.default ] \
  || { echo "::error::./feeds.conf.default not found — refusing to append feeds to an unknown path"; exit 1; }

echo "src-git istore https://github.com/linkease/istore;main" >> ./feeds.conf.default
echo "src-git kenzo https://github.com/kenzok8/openwrt-packages" >> ./feeds.conf.default
echo "src-git small https://github.com/kenzok8/small" >> ./feeds.conf.default

# Verify the append actually reached the file the feeds scripts will read.
for feed in istore kenzo small; do
  grep -q "^src-git ${feed} " ./feeds.conf.default \
    || { echo "::error::feed ${feed} missing from ./feeds.conf.default"; exit 1; }
done
echo "custom feeds appended: $(grep -c '^src-git' ./feeds.conf.default) sources total"

# --- Free up disk space on GitHub Actions runner ----------------------------
# The runner has ~28GB total; the OpenWrt build tree plus a multi-GB rootfs
# image easily exceeds it. Paths are hard-coded absolute paths of preinstalled
# runner toolchains that are unrelated to the build.
echo "=== Before cleanup ==="
df -hT "$PWD"

echo "Removing unnecessary pre-installed tools..."
for dir in \
  /usr/local/lib/android \
  /opt/ghc \
  /usr/local/.ghcup \
  /usr/share/dotnet \
  /usr/local/share/powershell \
  /usr/local/share/chromium \
  /usr/local/lib/node_modules
do
  if [ -e "$dir" ]; then
    if sudo rm -rf "$dir"; then
      echo "  removed $dir"
    else
      echo "::warning::failed to remove $dir (runner image may have changed)"
    fi
  fi
done

# GH Actions runner preinstalls /usr/local/bin/runc, which triggers the moby
# binary-daemon host-executable copy bug (openwrt/packages#30355); moving it
# aside makes the copy step return early. Not needed by the OpenWrt build.
if [ -e /usr/local/bin/runc ]; then
  sudo mv /usr/local/bin/runc /usr/local/bin/runc.bak
  echo "  moved host runc aside"
fi

echo "=== After cleanup ==="
df -hT "$PWD"

# Fail fast instead of discovering an out-of-space runner hours into the build.
# The build needs roughly 30GB for build_dir plus the image output.
MIN_FREE_GB=20
FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
if [ -z "$FREE_GB" ]; then
  echo "::warning::could not determine free disk space; skipping the space check"
elif [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
  echo "::error::only ${FREE_GB}GB free on / (need at least ${MIN_FREE_GB}GB); cleanup is no longer effective"
  exit 1
else
  echo "free space on /: ${FREE_GB}GB (minimum ${MIN_FREE_GB}GB)"
fi
