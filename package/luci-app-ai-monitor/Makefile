include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for AI Monitor
LUCI_DEPENDS:=+luci-base +ai-monitor
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-ai-monitor))
