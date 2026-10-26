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

# fetch <远端文件> <本地路径>：直连 -> 加速 -> 再直连
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/out
	rm -rf $(PKG_BUILD_DIR)/out/*

	@fetch() { \
		for u in "$(DIRECT)/$$1" "$(MIRROR)/$$1" "$(DIRECT)/$$1"; do \
			echo "==> 下载 $$1  <-  $$u"; \
			if curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 600 -o "$$2" "$$u"; then \
				[ -s "$$2" ] && return 0; \
			fi; \
			rm -f "$$2"; \
		done; \
		echo "!! $$1 所有通道均失败"; return 1; \
	}; \
	fetch country.mmdb       $(PKG_BUILD_DIR)/out/Country.mmdb  || exit 1; \
	fetch geosite.dat        $(PKG_BUILD_DIR)/out/GeoSite.dat   || exit 1; \
	fetch geoip.dat          $(PKG_BUILD_DIR)/out/GeoIP.dat     || exit 1; \
	fetch GeoLite2-ASN.mmdb  $(PKG_BUILD_DIR)/out/ASN.mmdb      || exit 1

	@# 体积下限（按 2026-10 实测值的一半给，留出上游瘦身余量但仍能挡住桩文件）
	@for spec in "Country.mmdb 3000000" "GeoSite.dat 1500000" "GeoIP.dat 5000000" "ASN.mmdb 3000000"; do \
		set -- $$spec; \
		f="$(PKG_BUILD_DIR)/out/$$1"; min=$$2; \
		[ -s "$$f" ] || { echo "!! $$1 缺失或为空"; exit 1; }; \
		sz=$$(stat -c '%s' "$$f"); \
		if [ "$$sz" -lt "$$min" ]; then \
			echo "!! $$1 只有 $$sz 字节，低于下限 $$min（疑似桩文件或错误页）"; exit 1; \
		fi; \
		printf '    %-16s %10s 字节\n' "$$1" "$$sz"; \
	done

	@# sha256 校验：上游每个文件都带 .sha256sum，能取到就强制校验
	@for spec in "Country.mmdb country.mmdb" "GeoSite.dat geosite.dat" "GeoIP.dat geoip.dat" "ASN.mmdb GeoLite2-ASN.mmdb"; do \
		set -- $$spec; local=$$1; remote=$$2; \
		want=""; \
		for u in "$(DIRECT)/$$remote.sha256sum" "$(MIRROR)/$$remote.sha256sum"; do \
			want=$$(curl -fsSL --retry 2 --connect-timeout 20 "$$u" 2>/dev/null | awk '{ print $$1 }' | head -1); \
			[ -n "$$want" ] && break; \
		done; \
		if [ -n "$$want" ]; then \
			got=$$(sha256sum "$(PKG_BUILD_DIR)/out/$$local" | awk '{ print $$1 }'); \
			if [ "$$want" != "$$got" ]; then \
				echo "!! $$local sha256 校验失败"; echo "   want $$want"; echo "   got  $$got"; exit 1; \
			fi; \
			echo "    $$local sha256 OK"; \
		else \
			echo "    $$local 上游未提供 sha256sum，跳过校验"; \
		fi; \
	done

	ls -lh $(PKG_BUILD_DIR)/out
	echo "==> 四个数据库就绪"
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
