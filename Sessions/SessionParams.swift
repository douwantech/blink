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
import UIKit

/// Typealias for session parameter objects that can be snapshotted and securely coded
public typealias BKSessionParams = (any NSSecureCoding & BKSessionParamsSnapshotting)

/// Opt-in storage hook for params that want a built-in Data backing.
@objc public protocol EncodedStateBacked {
  @objc dynamic var encodedStateStorage: Data? { get set }
}

/// Default behavior for snapshot methods when the type provides storage.
public extension EncodedStateBacked {
  @inlinable func _hasEncodedStateDefault() -> Bool {
    return encodedStateStorage != nil
  }

  @inlinable @discardableResult
  func _takeEncodedStateDefault() -> Data? {
    let data = encodedStateStorage
    encodedStateStorage = nil
    return data
  }

  @inlinable func _putEncodedStateDefault(_ data: Data) {
    encodedStateStorage = data
  }
}

@objc class TermUIState: NSObject, NSSecureCoding {
    @objc var viewSize: CGSize = .zero
    @objc var rows: Int = 0
    @objc var cols: Int = 0
    @objc var themeName: String? = nil
    @objc var fontName: String? = nil
    @objc var fontSize: Int = 16
    @objc var layoutMode: Int = 0
    @objc var boldAsBright: Bool = false
    @objc var enableBold: UInt = 0
    @objc var layoutLocked: Bool = false
    @objc var layoutLockedFrame: CGRect = .zero

    private enum Key: CodingKey {
        case viewSize
        case rows
        case cols
        case themeName
        case fontName
        case fontSize
        case layoutMode
        case boldAsBright
        case enableBold
        case layoutLocked
        case layoutLockedFrame
    }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
        self.viewSize = coder.bk_decode(for: Key.viewSize)
        self.rows = coder.bk_decode(for: Key.rows)
        self.cols = coder.bk_decode(for: Key.cols)
        self.themeName = coder.bk_decode(for: Key.themeName)
        self.fontName = coder.bk_decode(for: Key.fontName)
        self.fontSize = coder.bk_decode(for: Key.fontSize)
        self.layoutMode = coder.bk_decode(for: Key.layoutMode)
        self.boldAsBright = coder.bk_decode(for: Key.boldAsBright)
        self.enableBold = coder.bk_decode(for: Key.enableBold)
        self.layoutLocked = coder.bk_decode(for: Key.layoutLocked)
        self.layoutLockedFrame = coder.bk_decode(for: Key.layoutLockedFrame)
    }

    func encode(with coder: NSCoder) {
        coder.bk_encode(viewSize, for: Key.viewSize)
        coder.bk_encode(rows, for: Key.rows)
        coder.bk_encode(cols, for: Key.cols)
        coder.bk_encode(themeName, for: Key.themeName)
        coder.bk_encode(fontName, for: Key.fontName)
        coder.bk_encode(fontSize, for: Key.fontSize)
        coder.bk_encode(layoutMode, for: Key.layoutMode)
        coder.bk_encode(boldAsBright, for: Key.boldAsBright)
        coder.bk_encode(enableBold, for: Key.enableBold)
        coder.bk_encode(layoutLocked, for: Key.layoutLocked)
        coder.bk_encode(layoutLockedFrame, for: Key.layoutLockedFrame)
    }

    static var supportsSecureCoding: Bool { true }
}

@objc class TermParams: NSObject, NSSecureCoding {
  // Protocol-typed: matches Session.sessionParams
  @objc var sessionParams: BKSessionParams?
  @objc var sessionType: String?
  @objc var termUIState: TermUIState?

  private enum Key: CodingKey {
    case sessionParams
    case sessionType
    case termUIState
  }

  @objc init(
    sessionParams: BKSessionParams,
    sessionType: String,
    termUIState: TermUIState
  ) {
    self.sessionParams = sessionParams
    self.sessionType = sessionType
    self.termUIState = termUIState
    super.init()
  }

  // MARK: - NSSecureCoding
  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.bk_encode(sessionParams, for: Key.sessionParams)
    coder.bk_encode(sessionType, for: Key.sessionType)
    coder.bk_encode(termUIState, for: Key.termUIState)
  }

  required init?(coder: NSCoder) {
    super.init()
    // IMPORTANT: include all concrete param types you support here
    // (extend this list as you add new SessionParams types)
    self.sessionParams = coder.bk_decode(of: [MCPParams.self], for: Key.sessionParams)
    self.sessionType = coder.bk_decode(for: Key.sessionType)
    self.termUIState = coder.bk_decode(of: [TermUIState.self], for: Key.termUIState)
  }

  // MARK: - Utility
  @objc func deepCopy() -> TermParams? {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.encode(self, forKey: "params")
    let data = archiver.encodedData
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    unarchiver.requiresSecureCoding = true
    return unarchiver.decodeObject(of: TermParams.self, forKey: "params")
  }
}

@objc class MoshParams: NSObject, NSSecureCoding, BKSessionParamsSnapshotting, EncodedStateBacked {
  @objc var ip: String? = nil
  @objc var port: String? = nil
  @objc var key: String? = nil
  @objc var predictionMode: String? = nil
  @objc var predictOverwrite: String? = nil
  @objc var startupCmd: String? = nil
  @objc var serverPath: String? = nil
  @objc var experimentalRemoteIp: String? = nil
  
  // Snapshot storage (backing for the default behavior)
  @objc dynamic public var encodedStateStorage: Data? = nil
  
  override init() { super.init() }
  
  private enum Key: String, CodingKey {
    case ip, port, key, predictionMode, predictOverwrite, startupCmd, serverPath, experimentalRemoteIp
    case encodedState
  }
  
  // Satisfy @objc protocol by forwarding to helpers:
  @objc func hasEncodedState() -> Bool { _hasEncodedStateDefault() }
  @objc func takeEncodedState() -> Data? { _takeEncodedStateDefault() }
  @objc func putEncodedState(_ data: Data) { _putEncodedStateDefault(data) }
  
  func encode(with coder: NSCoder) {
    coder.bk_encode(ip, for: Key.ip)
    coder.bk_encode(port, for: Key.port)
    coder.bk_encode(key, for: Key.key)
    coder.bk_encode(predictionMode, for: Key.predictionMode)
    coder.bk_encode(predictOverwrite, for: Key.predictOverwrite)
    coder.bk_encode(startupCmd, for: Key.startupCmd)
    coder.bk_encode(serverPath, for: Key.serverPath)
    coder.bk_encode(experimentalRemoteIp, for: Key.experimentalRemoteIp)
    coder.bk_encode(encodedStateStorage, for: Key.encodedState)
  }
  
  required init?(coder: NSCoder) {
    super.init()
    
    self.ip = coder.bk_decode(for: Key.ip)
    self.port = coder.bk_decode(for: Key.port)
    self.key = coder.bk_decode(for: Key.key)
    self.predictionMode = coder.bk_decode(for: Key.predictionMode)
    self.predictOverwrite = coder.bk_decode(for: Key.predictOverwrite)
    self.startupCmd = coder.bk_decode(for: Key.startupCmd)
    self.serverPath = coder.bk_decode(for: Key.serverPath)
    self.experimentalRemoteIp = coder.bk_decode(for: Key.experimentalRemoteIp)
    self.encodedStateStorage = coder.bk_decode(for: Key.encodedState)
  }
  
  static var secureCoding2 = true
  static var supportsSecureCoding: Bool { true }
  
  public func copy(from params: MoshParams) {
    self.ip = params.ip
    self.port = params.port
    self.key = params.key
    self.predictionMode = params.predictionMode
    self.predictOverwrite = params.predictOverwrite
    self.startupCmd = params.startupCmd
    self.serverPath = params.serverPath
    self.experimentalRemoteIp = params.experimentalRemoteIp
  }
}

@objc class MCPParams: NSObject, NSSecureCoding, BKSessionParamsSnapshotting {
  @objc var childSessionType: String? = nil
  @objc var childSessionParams: BKSessionParams?

  private enum Key: CodingKey { case childSessionType, childSessionParams }

  override init() { super.init() }

  // MARK: - NSSecureCoding
  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.bk_encode(childSessionType, for: Key.childSessionType)
    coder.bk_encode(childSessionParams, for: Key.childSessionParams)
  }

  required init?(coder: NSCoder) {
    super.init()
    self.childSessionType = coder.bk_decode(for: Key.childSessionType)
    // NOTE: include all known MCP children subclasses here for secure decoding
    self.childSessionParams = coder.bk_decode(of: [MoshParams.self], for: Key.childSessionParams)
  }

  // MARK: - BKSessionParamsSnapshotting (forward)
  @objc func hasEncodedState() -> Bool { childSessionParams?.hasEncodedState() ?? false }
  @objc func takeEncodedState() -> Data? { childSessionParams?.takeEncodedState() }
  @objc func putEncodedState(_ data: Data) { childSessionParams?.putEncodedState(data) }
}
