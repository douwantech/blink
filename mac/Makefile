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

# 打成可双击的 .app（release 构建 + Info.plist + 图标 + ad-hoc 签名）
APP = dist/BlinkMac.app
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/BlinkMac $(APP)/Contents/MacOS/BlinkMac
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --deep -s - $(APP)
	@echo "built $(APP)"

# 装到 ~/Applications（用户可写，Launchpad/Spotlight 可打开）
install: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/BlinkMac.app
	cp -R $(APP) $(HOME)/Applications/BlinkMac.app
	@echo "installed ~/Applications/BlinkMac.app —— 双击或 Spotlight 打开"

clean:
	swift package clean
	rm -rf .build dist
