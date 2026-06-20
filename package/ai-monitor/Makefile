include $(TOPDIR)/rules.mk

PKG_NAME:=ai-monitor
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ai-monitor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=AI-powered system monitor with reports and optimization
  DEPENDS:=+curl +coreutils +coreutils-stat +sqlite3-cli
  PKGARCH:=all
endef

define Package/ai-monitor/description
  AI Monitor v2 continuously checks system health (CPU, memory, disk, temperature,
  traffic, client connections) and uses AI (DeepSeek/OpenAI) to analyze anomalies.
  Generates daily/weekly HTML reports with charts. Auto-optimizes system processes
  and memory. Sends push notifications via ServerChan or Telegram.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/ai-monitor/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/ai-monitor.sh $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/lib/ai-monitor
	$(INSTALL_DATA) ./files/lib/collector.sh $(1)/usr/lib/ai-monitor/
	$(INSTALL_DATA) ./files/lib/reporter.sh $(1)/usr/lib/ai-monitor/
	$(INSTALL_DATA) ./files/lib/optimizer.sh $(1)/usr/lib/ai-monitor/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/ai-monitor.init $(1)/etc/init.d/ai-monitor
	$(INSTALL_DIR) $(1)/etc/config
	touch $(1)/etc/config/ai-monitor
	$(INSTALL_DIR) $(1)/var/lib/ai-monitor
endef

define Package/ai-monitor/conffiles
/etc/ai-monitor.conf
endef

$(eval $(call BuildPackage,ai-monitor))
