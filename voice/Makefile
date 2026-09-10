.PHONY: run build app install clean

# 独立 macOS 语音输入 app（SwiftUI + AppKit + Speech，纯系统框架，无外部依赖）。
# 日常开发：make run（swift run，纯本地）。注意 dev 二进制路径每次变，辅助功能/麦克风
# 授权留不住，真机 E2E 请用 make install 的正式签名版。
run:
	swift run -c debug VoiceKey

build:
	swift build

# 打成可双击的「正式版」.app：xcodegen 生成工程 + xcodebuild automatic signing（团队 659T9VUN97）。
# 签名身份稳定，辅助功能/麦克风 TCC 授权才留得住。
APP = dist/VoiceKey.app
app:
	xcodegen generate
	xcodebuild -project VoiceKey.xcodeproj -scheme VoiceKey -configuration Release \
	  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates \
	  -skipPackagePluginValidation -skipMacroValidation \
	  -derivedDataPath .build/xcode build
	rm -rf $(APP) && mkdir -p dist
	cp -R .build/xcode/Build/Products/Release/VoiceKey.app $(APP)
	@echo "built $(APP)（正式版·签名）"

# 装到 ~/Applications（用户可写，Launchpad/Spotlight 可打开）
install: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/VoiceKey.app
	cp -R $(APP) $(HOME)/Applications/VoiceKey.app
	@echo "installed ~/Applications/VoiceKey.app —— 双击或 Spotlight 打开「语音键」"

clean:
	swift package clean
	rm -rf .build dist VoiceKey.xcodeproj
