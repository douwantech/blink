//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////


import Foundation
import SwiftUI
#if targetEnvironment(macCatalyst)
import LocalAuthentication
#endif

/// 经典设置页。2026-10-06 起**不再作为 iOS 的设置入口**：iPhone/iPad 的设置页是
/// `BlinkSettingsViewController`，这里只留「订阅 / 支持 / 关于」三段，作为它
/// 「关于与支持」那一行的叶子页（`SpaceController.presentSettings`）。
/// Mac Catalyst 仍然整页用它，所以 Connect / Terminal / Configuration 那几段用
/// `#if targetEnvironment(macCatalyst)` 原样留着（Style / Display / Keys & Certificates /
/// Hosts / iCloud Sync 只有 Mac 端在用，删了就没别的入口了）。
struct SettingsView: View {

  /// 推入时的导航标题：iOS 侧传「关于与支持」，Mac Catalyst 保持 Settings。
  var navigationTitle: String = "Settings"

  @State private var _blinkVersion = UIApplication.blinkShortVersion() ?? ""
  @StateObject private var _entitlements: EntitlementsManager = .shared
  @StateObject private var _model = PurchasesUserModel.shared
  @State private var _displayBlinkClassicToPlus = false

#if targetEnvironment(macCatalyst)
  // 只有 Mac 保留的那几段在用。
  @State private var _biometryType = LAContext().biometryType
  @State private var _iCloudSyncOn = BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigiCloud)
  @State private var _autoLockOn = BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigAutoLock)
  @State private var _defaultUser = BLKDefaults.defaultUserName() ?? ""
#endif

  var body: some View {
    List {
      Section("Subscription") {
        HStack {
          Label(_entitlements.currentPlanName(), systemImage: "bag")
          Spacer()
          if !(_entitlements.earlyAccessFeatures.active || FeatureFlags.earlyAccessFeatures) {
            Button("Get Blink+") { _displayBlinkClassicToPlus = true }
          }
        }
        if _entitlements.earlyAccessFeatures.active {
          Row {
            HStack {
              Label("Build Beta", systemImage: "hammer.circle")
              Spacer()
              if _entitlements.earlyAccessFeatures.period == .Trial {
                Text("Needs Blink+")
              } else {
                Text("") // TODO: show status?
                  .foregroundColor(.secondary)
              }
            }
          } details: {
              BuildView().onAppear(perform: {
                BuildAccountModel.shared.checkBuildToken(animated: false)
              })
          }.disabled(_entitlements.earlyAccessFeatures.period != .Normal)
        }
      }

#if targetEnvironment(macCatalyst)
      // ↓ Mac Catalyst 专属：这几段（钥匙/主机/终端外观/书签/Snips/iCloud 同步/自动锁）
      // 只有 Mac 端有别的入口，iPhone/iPad 按 2026-10-06 的收窄口径删掉。
      Section("Connect") {
        Row {
          Label("Keys & Certificates", systemImage: "key")
        } details: {
          KeyListView()
        }
        Row {
          Label("Hosts", systemImage: "server.rack")
        } details: {
          HostListView()
        }
        Row {
          Label("Default Agent", systemImage: "key.viewfinder")
        } details: {
          DefaultAgentSettingsView()
        }
        RowWithStoryBoardId(content: {
          HStack {
            Label("Default User", systemImage: "person")
            Spacer()
            Text(_defaultUser).foregroundColor(.secondary)
          }
        }, storyBoardId: "BKDefaultUserViewController")
      }

      Section("Terminal") {
        Row {
          Label("Style", systemImage: "paintpalette")
        } details: {
          StyleCustomizationView()
        }
        Row {
          Label("Display", systemImage: "display")
        } details: {
          DisplaySettingsView()
        }
        Row {
          Label("Keyboard", systemImage: "keyboard")
        } details: {
          KBConfigView(config: KBTracker.shared.loadConfig())
        }
        RowWithStoryBoardId(content: {
          Label("Smart Keys", systemImage: "keyboard.badge.ellipsis")
        }, storyBoardId: "BKSmartKeysConfigViewController")
        Row {
          Label("Notifications", systemImage: "bell")
        } details: {
          BKNotificationsView()
        }
        Row {
          Label("Gestures", systemImage: "rectangle.and.hand.point.up.left.filled")
        } details: {
          GesturesView()
        }
      }

      Section("Configuration") {
        Row {
          Label("Bookmarks", systemImage: "bookmark")
        } details: {
          BookmarkedLocationsView()
        }
        Row {
          Label("Snips", systemImage: "chevron.left.square")
        } details: {
          SnippetsConfigView()
        }
        RowWithStoryBoardId(content: {
          HStack {
            Label("iCloud Sync", systemImage: "icloud")
            Spacer()
            Text(_iCloudSyncOn ? "On" : "Off").foregroundColor(.secondary)
          }
        }, storyBoardId: "BKiCloudConfigurationViewController")
        RowWithStoryBoardId(content: {
          HStack {
            Label("Auto Lock", systemImage: _biometryType == .faceID ? "faceid" : "touchid")
            Spacer()
            Text(_autoLockOn ? "On" : "Off").foregroundColor(.secondary)
          }
        }, storyBoardId: "BKSecurityConfigurationViewController")
      }
#endif

      Section("Get in touch") {
        Row {
          Label("Support", systemImage: "book")
        } details: {
          SupportView()
        }
        Row {
          Label("Community", systemImage: "bubble.left")
        } details: {
          FeedbackView()
        }
      }

      Section {
        RowWithStoryBoardId(content: {
          HStack {
            Label("About", systemImage: "questionmark.circle")
            Spacer()
            Text(_blinkVersion).foregroundColor(.secondary)
          }
        }, storyBoardId: "BKAboutViewController")
        HStack {
          Button {
            _model.openPrivacyAndPolicy()
          } label: {
            Label("Privacy Policy", systemImage: "link")
          }
        }
        HStack {
          Button {
            _model.openTermsOfUse()
          } label: {
            Label("Terms of Use", systemImage: "link")
          }
        }
      }
    }
    .listStyle(.grouped)
    .navigationTitle(navigationTitle)
    .sheet(isPresented: $_displayBlinkClassicToPlus) {
      BlinkClassicToPlusWindow(urlHandler: blink_openurl, dismissHandler: { _displayBlinkClassicToPlus = false })
    }

  }
}

fileprivate struct BlinkClassicToPlusWindow: View {
  let urlHandler: (URL) -> ()
  let dismissHandler: () -> ()

  @Environment(\.dynamicTypeSize) var dynamicTypeSize

  var body: some View {
    GeometryReader { proxy in
      let ctx = PageCtx(
        proxy: proxy,
        dynamicTypeSize: dynamicTypeSize
      )

      NewOfferingsView(classicOffering: true, ctx: ctx, purchaseCompletedHandler: dismissHandler, urlHandler: urlHandler, dismissHandler: dismissHandler)
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(.black)
  }
}
