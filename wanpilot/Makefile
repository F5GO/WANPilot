# OpenWrt package definition for the WANPilot core package.
include $(TOPDIR)/rules.mk

PKG_NAME:=wanpilot
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Nikolay

include $(INCLUDE_DIR)/package.mk

define Package/wanpilot
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=Multi-uplink manager for OpenWrt
  DEPENDS:=+ubus +uci +libubox
endef

define Package/wanpilot/description
 WANPilot is a lightweight multi-uplink manager for OpenWrt with
 verified metric switching, per-interface connectivity checks,
 a CLI and native LuCI integration.
endef

define Package/wanpilot/conffiles
/etc/config/wanpilot
endef

define Build/Compile
endef

define Package/wanpilot/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,wanpilot))
