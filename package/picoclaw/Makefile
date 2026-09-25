# SPDX-License-Identifier: MIT
#
# PicoClaw for OpenWrt (x86_64) — native package for Samre/OpenWrt-x86_64.
#
# Why this package exists instead of the third-party one
# (LIKE2000-ART/luci-app-picoclaw), whose Makefile was audited at the same
# upstream revision:
#
#   1. It injects version info into $(GO_PKG_BUILD_PKG)/internal.* — but
#      upstream moved those vars to github.com/sipeed/picoclaw/pkg/config.
#      A version -X on a non-existent symbol is silently ignored by the Go
#      linker, so the firmware would report "0.1.2" forever.
#   2. It copies $(PKG_BUILD_DIR)/workspace to
#      cmd/picoclaw/internal/onboard/workspace. Upstream explicitly documents
#      that directory as a generated copy that "may be absent", and embeds the
#      template from the module root via //go:embed in
#      onboard_workspace_embed.go. The copy is unnecessary.
#   3. It patches cmd/picoclaw/internal/helpers.go with two seds that no longer
#      match. That patch is both broken and unnecessary: upstream honours
#      PICOCLAW_HOME natively in pkg/config/envkeys.go (GetHome()), so no
#      source patch is required at all. The third-party init script works
#      around the "missing" support by symlinking /.picoclaw -> /etc/picoclaw,
#      which is dead weight.
#   4. It builds with tags "stdjson" only. Upstream defaults to
#      "goolm,stdjson"; goolm is the pure-Go driver for modernc.org/sqlite,
#      which is what makes the store work with CGO_ENABLED=0.
#
# This package therefore needs no source patch: it pins one upstream commit and
# relies only on documented upstream behaviour (PICOCLAW_HOME + *_env knobs).

include $(TOPDIR)/rules.mk

PKG_NAME:=picoclaw
# The most recent upstream release tag at the pinned commit below (v0.3.1,
# published 2026-07-03). The pinned commit is the tip of main, which is ahead of
# that tag, so this is a human-readable label rather than an exact claim about
# the source. Bump both together.
PKG_VERSION:=0.3.1
PKG_RELEASE:=1

# Pinned commit on purpose. The upstream project has no stable API yet and the
# third-party package tracked `main`, which is how its sed patches rotted
# silently. Update this together with the patch file below.
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/sipeed/picoclaw.git
PKG_SOURCE_VERSION:=bbf6893ca7afad27f1d00a0f5a45982a549c6ed6
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Samre

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

# The module declares `go 1.25.13`. lede's packages feed (coolsnowwolf/packages)
# ships Go 1.27.1, so no toolchain swap is needed — unlike upstream OpenWrt
# 24.10, whose golang package is too old for this module.
GO_PKG:=github.com/sipeed/picoclaw
GO_PKG_BUILD_PKG:=github.com/sipeed/picoclaw/cmd/picoclaw

# goolm = pure-Go modernc.org/sqlite driver (required because OpenWrt Go
# packages build with CGO_ENABLED=0). stdjson selects the encoding/json path
# instead of the bytedance/sonic assembler path. Both are upstream defaults.
GO_PKG_TAGS:=goolm,stdjson

# Injection target verified against upstream onboard_workspace_embed.go and
# pkg/config: the version vars live in github.com/sipeed/picoclaw/pkg/config.
GO_PKG_LDFLAGS:=-s -w \
	-X 'github.com/sipeed/picoclaw/pkg/config.Version=$(PKG_VERSION)' \
	-X 'github.com/sipeed/picoclaw/pkg/config.GitCommit=$(PKG_SOURCE_VERSION)' \
	-X 'github.com/sipeed/picoclaw/pkg/config.BuildTime=$(SOURCE_DATE_EPOCH)' \
	-X 'github.com/sipeed/picoclaw/pkg/config.GoVersion=$(shell $(STAGING_DIR_HOSTPKG)/bin/go version | sed "s/go version //")'

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/picoclaw
  TITLE:=PicoClaw — ultra-lightweight AI assistant (Go)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/sipeed/picoclaw
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +zoneinfo-core
endef

define Package/picoclaw/description
 PicoClaw is an ultra-lightweight personal AI assistant written in Go.
 It runs on minimal hardware with a small memory footprint and talks to the
 user through 19+ messaging channels (Telegram, Feishu/Lark, DingTalk, ...)
 while supporting both cloud LLM APIs and a local Ollama instance.
endef

# No source patch: PICOCLAW_HOME (pkg/config/envkeys.go) and the PICOCLAW_*
# environment overrides are upstream-supported, so the package only has to set
# them from UCI in the init script.
define Build/Prepare
	$(call Build/Prepare/Default)
endef

define Package/picoclaw/install
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/picoclaw.init $(1)/etc/init.d/picoclaw
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/picoclaw.uci-default $(1)/etc/uci-defaults/99-picoclaw
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/picoclaw.conf $(1)/etc/config/picoclaw
	$(INSTALL_DIR) $(1)/usr/share/picoclaw
	$(INSTALL_DATA) $(CURDIR)/files/picoclaw-config.json $(1)/usr/share/picoclaw/picoclaw-config.json
endef

define Package/picoclaw/conffiles
/etc/config/picoclaw
/etc/picoclaw/config.json
/etc/picoclaw/.security.yml
endef

define Package/picoclaw/prerm
#!/bin/sh
[ -x /etc/init.d/picoclaw ] && /etc/init.d/picoclaw stop
[ -x /etc/init.d/picoclaw ] && /etc/init.d/picoclaw disable
exit 0
endef

define Package/picoclaw/postrm
#!/bin/sh
# Deliberately does NOT delete /etc/picoclaw: it holds the operator's API keys,
# channel tokens and chat history. Removing a package must not destroy them.
rm -f /etc/config/picoclaw
rm -f /etc/config/picoclaw-opkg
exit 0
endef

$(eval $(call GoBinPackage,picoclaw))
$(eval $(call BuildPackage,picoclaw))
