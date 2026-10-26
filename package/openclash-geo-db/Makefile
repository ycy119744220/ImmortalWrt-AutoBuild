#
# openclash-geo-db —— 把 OpenClash 需要的四个数据库在编译期下载并打进固件，装到 /etc/openclash/
#
# 为什么要有这个包：
#   官方 luci-app-openclash 只带 Country.mmdb(205KB 桩) 与 GeoSite.dat(10MB 旧快照)，
#   GeoIP.dat / ASN.mmdb 根本没有，要等运行时 install.sh 联网下载。本包让固件开箱即用。
#
# 数据来源（上游官方 release，不引入任何第三方 feed 仓库）：
#   https://github.com/MetaCubeX/meta-rules-dat  release "latest"（滚动更新，每天重建）
#
# ⚠ 变更记录（真实踩坑，务必保留）：
#   1) 早期该 release 提供打包的 meta.zip（内含 geo/*.dat、*.mmdb）。
#      2026-10 起 meta.zip 已从资产列表移除，改为逐个文件发布：
#         country.mmdb(7.3MB)  geosite.dat(4.1MB)  geoip.dat(16.5MB)  GeoLite2-ASN.mmdb(8.6MB)
#      所以这里不再解 zip，而是逐文件下载 + 逐个 sha256 校验。
#   2) 上游资产名与包内文件名不一致：country.mmdb -> Country.mmdb，
#      geosite.dat -> GeoSite.dat，geoip.dat -> GeoIP.dat，GeoLite2-ASN.mmdb -> ASN.mmdb。
#      OpenClash 只认后者，映射写错就是"装了一堆文件但插件报缺库"。
#   3) geoip.dat 实际 16.5MB，不是 173KB（release 页面上 geoip.metadb 才是小文件）。
#      体积下限必须按实测值给，否则桩文件/错误页能混进来。
#   4) gh-proxy.com 在构建机（海外 runner）与国内网络都实测可用；
#      但为防代理挂掉，这里做「直连 → 加速 → 再直连」的降级重试。
include $(TOPDIR)/rules.mk

PKG_NAME:=openclash-geo-db
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=ImmortalWrt-AutoBuild

include $(INCLUDE_DIR)/package.mk

RULES_PATH:=MetaCubeX/meta-rules-dat/releases/download/latest
DIRECT:=https://github.com/$(RULES_PATH)
MIRROR:=https://gh-proxy.com/https://github.com/$(RULES_PATH)

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=GeoIP/GeoSite/MMDB/ASN databases for OpenClash
	DEPENDS:=+luci-app-openclash
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  OpenClash 所需的四个数据库（Country.mmdb / GeoSite.dat / GeoIP.dat / ASN.mmdb），
  编译期从 MetaCubeX/meta-rules-dat 官方 release 下载并预置到 /etc/openclash/。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/out
	@# 真正的取数/校验逻辑在 fetch.sh 里。
	@# 千万不要写回 Makefile：Prepare 段带 @ 前缀时 package.mk 会把整段 recipe
	@# 压成一行交给 bash -c，里面一旦有引号嵌套或函数定义，就会
	@# "unexpected EOF while looking for matching `'`"，且变量全空、
	@# 报错完全没有指向性（实测整机编译 76 分钟才红在这里）。
	sh ./fetch.sh "$(PKG_BUILD_DIR)" "$(DIRECT)" "$(MIRROR)"
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/openclash
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/out/Country.mmdb $(1)/etc/openclash/Country.mmdb
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/out/GeoSite.dat $(1)/etc/openclash/GeoSite.dat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/out/GeoIP.dat $(1)/etc/openclash/GeoIP.dat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/out/ASN.mmdb $(1)/etc/openclash/ASN.mmdb
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
