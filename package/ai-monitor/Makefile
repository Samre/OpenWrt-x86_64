include $(TOPDIR)/rules.mk

PKG_NAME:=ai-monitor
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ai-monitor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=AI-powered system monitor with push notifications
  DEPENDS:=+curl +coreutils +coreutils-stat
  PKGARCH:=all
endef

define Package/ai-monitor/description
  AI Monitor continuously checks system health (CPU, memory, disk, temperature)
  and uses AI (DeepSeek/OpenAI) to analyze anomalies. Sends push notifications
  via ServerChan or Telegram when issues are detected.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/ai-monitor/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/ai-monitor.sh $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/ai-monitor.init $(1)/etc/init.d/ai-monitor
	$(INSTALL_DIR) $(1)/etc/config
	touch $(1)/etc/config/ai-monitor
endef

define Package/ai-monitor/conffiles
/etc/ai-monitor.conf
endef

$(eval $(call BuildPackage,ai-monitor))
