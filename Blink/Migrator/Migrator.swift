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
import SSH
import UserNotifications


@objc class Migrator : NSObject {
  @objc static func perform() {
    Self.perform(steps: [MigrationToAppGroup(),
                         MigrationAddSnippetsShortcut(),
                         MigrationFileProviderReplicatedExtension(),
                         MigrationStyleFromDefaults(),
                         MigrationWipeSessionRegistry()
                        ])
  }

  @objc static func setupAutoSSHKey() {
    let keyID = "AutoMac"
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let logURL = docs.appendingPathComponent("autossh.log")
    func dlog(_ s: String) {
      let line = "\(Date()) \(s)\n"
      if let data = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
          h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
          try? data.write(to: logURL)
        }
      }
    }
    dlog("setupAutoSSHKey enter, withID=\(BKPubKey.withID(keyID) as Any)")

    if !UserDefaults.standard.bool(forKey: "Blink.oscNotificationsAutoEnabled") {
      BLKDefaults.setOscNotifications(true)
      UserDefaults.standard.set(true, forKey: "Blink.oscNotificationsAutoEnabled")
      BLKDefaults.save()
      dlog("oscNotifications auto-enabled")
    }
    if !UserDefaults.standard.bool(forKey: "Blink.bellSoundAutoEnabled") {
      BLKDefaults.setPlaySoundOnBell(true)
      UserDefaults.standard.set(true, forKey: "Blink.bellSoundAutoEnabled")
      BLKDefaults.save()
      dlog("playSoundOnBell auto-enabled")
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      dlog("notification authorization granted=\(granted)")
    }
    let blob = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBhKWYQft5vRmWA8zd74u3KLW/99sshjHt66dv2h72c9AAAAJDL4pQ6y+KU
OgAAAAtzc2gtZWQyNTUxOQAAACBhKWYQft5vRmWA8zd74u3KLW/99sshjHt66dv2h72c9A
AAAECLn2rrwcjqcn0pCEduLsPAs37coc5NnEdCfMrD9EZiKmEpZhB+3m9GZYDzN3vi7cot
b/32yyGMe3rp2/aHvZz0AAAACWJsaW5rLXNpbQECAwQ=
-----END OPENSSH PRIVATE KEY-----

"""

    var justImported = false
    if BKPubKey.withID(keyID) == nil {
      guard let data = blob.data(using: .utf8) else {
        dlog("data nil"); return
      }
      dlog("blob len=\(data.count)")
      do {
        let key = try SSHKey(fromFileBlob: data, passphrase: "")
        dlog("SSHKey ok")
        try BKPubKey.addKeychainKey(id: keyID, key: key, comment: "auto")
        dlog("addKeychainKey ok")
        BKPubKey.saveIDS()
        dlog("saveIDS ok, withID now=\(BKPubKey.withID(keyID) as Any)")
        justImported = true
      } catch {
        dlog("error: \(error)")
      }
    } else {
      dlog("AutoMac exists, skip import")
    }

    let desired = BKAgentSettings(prompt: .Allow, keys: [keyID])
    let current = (try? SSHDefaultAgent.getSettings()) ?? nil
    dlog("current=\(String(describing: current)) desired=\(desired) justImported=\(justImported)")
    if justImported || current != desired {
      try? SSHDefaultAgent.setSettings(desired)
      dlog("setSettings done")
    }
  }

  static func perform(steps: [MigrationStep]) {
    let migratorFileURL = URL(fileURLWithPath: BlinkPaths.groupContainerPath()).appendingPathComponent(".migrator")

    let currentVersionString = try? String(contentsOf: migratorFileURL, encoding: .utf8)
    var currentVersion = Int(currentVersionString ?? "0") ?? 0

    steps.forEach { step in
      guard step.version > currentVersion else {
        return
      }

      do {
        try step.execute()
        currentVersion = step.version
        try String(currentVersion)
          .data(using: .utf8)!
          .write(to: migratorFileURL,
                 options:  [.atomic, .noFileProtection])
      } catch {
        print(error)
        exit(0)
      }
    }
  }
}

protocol MigrationStep {
  // Migration steps should be idempotent
  func execute() throws
  // After a step is applied, the version is updated
  var version: Int { get }
}
