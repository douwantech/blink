.PHONY: run build app install clean icon

# 原生 macOS 版 Blink（SwiftUI + SPM）。
run:
	swift run -c debug BlinkMac

build:
	swift build

# 从 Resources/icon-source.png 重新生成 AppIcon.icns
icon:
	swift Resources/makeicon.swift Resources/icon-source.png
	rm -rf /tmp/BlinkMac.iconset && mkdir -p /tmp/BlinkMac.iconset
	@for s in 16 32 128 256 512; do \
	  sips -z $$s $$s Resources/icon-source.png --out /tmp/BlinkMac.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s*2)); sips -z $$d $$d Resources/icon-source.png --out /tmp/BlinkMac.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/BlinkMac.iconset -o Resources/AppIcon.icns

# 打成可双击的「正式版」.app：xcodegen 生成工程 + xcodebuild automatic signing
# （团队 659T9VUN97 + iCloud KV entitlement），这样才有跨设备休息同步。
# dev 版仍走上面的 swift run，纯本地、无 iCloud。
APP = dist/BlinkMac.app
app:
	xcodegen generate
	xcodebuild -project BlinkMac.xcodeproj -scheme BlinkMac -configuration Release \
	  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates \
	  -skipPackagePluginValidation -skipMacroValidation \
	  -derivedDataPath .build/xcode build
	rm -rf $(APP) && mkdir -p dist
	cp -R .build/xcode/Build/Products/Release/BlinkMac.app $(APP)
	@echo "built $(APP)（正式版·带 iCloud 跨设备休息同步）"

# 装到 ~/Applications（用户可写，Launchpad/Spotlight 可打开）
install: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/BlinkMac.app
	cp -R $(APP) $(HOME)/Applications/BlinkMac.app
	@echo "installed ~/Applications/BlinkMac.app —— 双击或 Spotlight 打开"

clean:
	swift package clean
	rm -rf .build dist
