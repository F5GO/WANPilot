# OpenWrt package definition for the WANPilot LuCI frontend.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wanpilot
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Nikolay

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wanpilot
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for WANPilot
  PKGARCH:=all
  DEPENDS:=+wanpilot +luci-base
endef

define Package/luci-app-wanpilot/description
 Native LuCI dashboard, configuration and runtime status views
 for the WANPilot multi-uplink manager.
endef

define Build/Compile
endef

define Package/luci-app-wanpilot/install
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
endef

$(eval $(call BuildPackage,luci-app-wanpilot))
