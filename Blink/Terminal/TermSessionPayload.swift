//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2025 Blink Mobile Shell Project
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


protocol TermSessionPayload {
  // TODO Maybe returning the session, but TBD
  // We use this to restore the proper payload object
  static var sessionType: TermSessionPayloadType { get }
  
  func start(in device: TermDevice, sessionKey: String)
  func suspend()
  //func resumeSession(in device: TermDevice, sessionKey: String)
  // TODO Don't remember why both have the same name, this isn't clear.
  // I think it has to do with the state the terminal is in when we call it.
  func resumeFromSuspended()

  var session: Session? { get }
}

enum TermSessionPayloadType: String, Codable {
  case mcp
}

class MCPSessionPayload : TermSessionPayload {
  static var sessionType: TermSessionPayloadType { .mcp }
  private var _session: MCPSession? = nil
  private var _initialParams: MCPParams

  // TODO Don't love this here. Because this is an extension of the state on the TermController.
  // But, if this is going to wrap that behavior, it seems the only way?
  var session: Session? { _session }

  init(params: MCPParams) {
    self._initialParams = params
  }

  func start(in device: TermDevice, sessionKey: String) {
    self._session = MCPSession(device: device, andParams: _initialParams)
    _session!.execute(withArgs: "")
  }

  func resumeFromSuspended() {
    if let session = self._session,
       session.sessionParams.hasEncodedState() {
      session.execute(withArgs: "")
    }
  }

  func suspend() {
    guard let session = self._session else { return }

    session.suspend()
    
    let hasEncodedState = session.sessionParams.hasEncodedState()
    debugPrint("MCP has encoded state", hasEncodedState)
  }
}

