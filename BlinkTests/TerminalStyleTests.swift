import XCTest

@testable import Blink

final class TerminalStyleTests: XCTestCase {
  private func makeStyle(name: String = "Shared") -> TerminalStyle {
    TerminalStyle(
      id: UUID(), name: name, themeName: "Default",
      fontName: TerminalStyle.makeBuiltInDefault().fontName,
      fontSize: 17, cursorBlink: true, boldMode: .on, boldAsBright: true
    )
  }

  private func makeStore() throws -> (TerminalStyleStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TerminalStyleTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (TerminalStyleStore.makeForTesting(directory: directory), directory)
  }

  func testStyleJSONRoundTripPreservesCurrentFields() throws {
    let original = makeStyle()
    let restored = try JSONDecoder().decode(TerminalStyle.self, from: JSONEncoder().encode(original))

    XCTAssertEqual(restored, original)
    XCTAssertEqual(restored.fontSize, 17)
    XCTAssertTrue(restored.cursorBlink)
    XCTAssertEqual(restored.boldMode, .on)
    XCTAssertTrue(restored.boldAsBright)
  }

  func testBundleExportEncodeDecodeImportRoundTrip() throws {
    let original = makeStyle(name: "Exported")
    let exported = TerminalStyleBundle.export(style: original)
    let decoded = try TerminalStyleBundle.decode(from: exported.encode())
    XCTAssertEqual(decoded.style, original)

    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    switch decoded.importInto(store: store) {
    case .success(let imported), .successWithWarnings(let imported, _):
      XCTAssertEqual(imported, original)
      XCTAssertEqual(store.style(for: original.id), original)
    case .alreadyExists:
      XCTFail("A fresh store must accept the exported style")
    }
  }

  func testImportSameUUIDDoesNotDuplicateStyle() throws {
    let original = makeStyle()
    let bundle = TerminalStyleBundle.export(style: original)
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = bundle.importInto(store: store)

    switch bundle.importInto(store: store) {
    case .alreadyExists(let existing, let incoming):
      XCTAssertEqual(existing, original)
      XCTAssertEqual(incoming, original)
      XCTAssertEqual(store.styles.count, 1)
    default:
      XCTFail("Importing the same UUID again must report a duplicate")
    }
  }

  func testStorePersistenceRoundTripPreservesSelectionAndStyle() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = makeStyle(name: "Persisted")
    store.addStyle(original)
    store.setSelected(original.id)

    let restored = TerminalStyleStore.makeForTesting(directory: directory)
    XCTAssertEqual(restored.styles, [original])
    XCTAssertEqual(restored.selectedStyleID, original.id)
    XCTAssertEqual(restored.selectedStyle, original)
  }
}
