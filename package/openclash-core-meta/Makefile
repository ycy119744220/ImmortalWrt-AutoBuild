#
# openclash-core-meta —— 把 mihomo（Clash Meta）官方 release 的可执行文件打进固件
#
# 背景（真实踩坑）：
#   OpenClash 自己仓库里没有预编译内核，它的 install.sh 只在「运行时」联网下载。
#   本包在「编译期」从 MetaCubeX/mihomo 的 GitHub Release 下载 linux-amd64 二进制，
#   落地 /etc/openclash/core/clash_meta。
#   曾因写死下载地址而 404 —— 所以这里不写死 URL，动态解析 tag。
#
# 资产名（v1.19.33 实测）：
#   mihomo-linux-amd64-v1.19.33.gz            <- 要这个（tag 自带 v，文件名是 -v1.x.y 而不是 -vv1.x.y）
#   mihomo-linux-amd64-compatible-v1.19.33.gz <- 老 CPU 兼容版，跳过（体积更大、性能略低）
#   mihomo-linux-amd64-go1xx-v1.19.33.gz      <- 备用变体，跳过
#
# 体积（v1.19.33 实测）：下载 22MB → 解压 62MB。低于 20MB 一律判定下载失败。
include $(TOPDIR)/rules.mk

PKG_NAME:=openclash-core-meta
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=ImmortalWrt-AutoBuild

include $(INCLUDE_DIR)/package.mk

REPO:=MetaCubeX/mihomo
MIHOMO_FALLBACK:=v1.19.33

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Mihomo (Clash Meta) core for OpenClash
	DEPENDS:=+luci-app-openclash
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  mihomo (Clash Meta) 内核，编译期预置到 /etc/openclash/core/clash_meta，
  刷机后 OpenClash 无需联网下载内核即可启动。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	rm -f $(PKG_BUILD_DIR)/clash_meta $(PKG_BUILD_DIR)/mihomo.gz
	@# 真正的取数/校验逻辑在 fetch.sh 里。
	@# 不要把这些逻辑写回 Makefile：Prepare 段带 @ 前缀时，package.mk 会把
	@# 整段 recipe 压成一行交给 bash -c，里面只要出现单引号（如 curl 的
	@# -H 'Accept: ...'）就会 "unexpected EOF while looking for matching `'`，
	@# 而且变量全空、报错完全没有指向性（实测整机编译 76 分钟才红在这里）。
	sh ./fetch.sh "$(PKG_BUILD_DIR)" "$(REPO)" "$(MIHOMO_FALLBACK)"
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/openclash/core
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/openclash/core/clash_meta $(1)/etc/openclash/core/clash_meta
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/etc/openclash/core/mihomo.version $(1)/etc/openclash/core/mihomo.version
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
