import XCTest

@testable import Blink

final class SessionParamsTests: XCTestCase {
  func testSecureArchiveRestoresCurrentFieldsAndMoshChild() throws {
    let child = MoshParams()
    child.ip = "192.0.2.10"
    child.port = "60001"
    child.key = "fixture-key"

    let original = MCPParams()
    original.childSessionType = "mosh"
    original.childSessionParams = child
    original.machineId = "machine-1"
    original.workDirId = "work-dir-1"
    original.tmuxSession = "cc-style-test"
    original.useTmux = false
    original.initialCommand = "ephemeral command"

    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: MCPParams.self, from: data))

    XCTAssertEqual(restored.childSessionType, "mosh")
    XCTAssertEqual(restored.machineId, "machine-1")
    XCTAssertEqual(restored.workDirId, "work-dir-1")
    XCTAssertEqual(restored.tmuxSession, "cc-style-test")
    XCTAssertTrue(restored.useTmux, "Current decoder forces tmux on for old archives")
    XCTAssertNil(restored.initialCommand, "Bootstrap command is intentionally ephemeral")
    let restoredChild = try XCTUnwrap(restored.childSessionParams as? MoshParams)
    XCTAssertEqual(restoredChild.ip, "192.0.2.10")
    XCTAssertEqual(restoredChild.port, "60001")
    XCTAssertEqual(restoredChild.key, "fixture-key")
  }
}
