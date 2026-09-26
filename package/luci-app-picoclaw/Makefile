# SPDX-License-Identifier: MIT
#
# LuCI application for PicoClaw: approval queue, audit log and service settings.
#
# Deliberately NOT used here: luci-app-picoclaw from LIKE2000-ART. Its ACL grants
# uci "*" read and write plus exec on /bin/ash, which is equivalent to handing
# the web interface a root shell. This app asks for the `picoclaw` UCI section
# and six named RPC methods, nothing more.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-picoclaw
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Samre

LUCI_TITLE:=LuCI support for the PicoClaw AI agent
LUCI_DEPENDS:=+luci-base +picoclaw
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk's default prerm calls `ubus call service delete` and removes the UCI
# config. The picoclaw core package owns the service and its configuration, so
# removing this interface must not touch either.
define Package/luci-app-picoclaw/prerm
#!/bin/sh
exit 0
endef

define Package/luci-app-picoclaw/postrm
#!/bin/sh
# Do not delete /etc/config/picoclaw here: it belongs to the picoclaw package,
# and removing only the LuCI interface must leave the agent configured.
rm -f /tmp/luci-indexcache
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
