import Foundation

struct TabEntry: Codable {
  let id: UUID
  var machineId: String?
  var workDirId: String?
  var tmuxSession: String?
}

struct TabState: Codable {
  var version: Int
  var tabs: [TabEntry]
  var currentId: UUID?

  init(version: Int = 1, tabs: [TabEntry] = [], currentId: UUID? = nil) {
    self.version = version
    self.tabs = tabs
    self.currentId = currentId
  }
}

final class TabStateStore {
  static let shared = TabStateStore()

  private let fileURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("blink_tabs.json")
  }()

  private let ioQueue = DispatchQueue(label: "sh.blink.TabStateStore")
  private var pendingWork: DispatchWorkItem?
  private var dirty = false
  private(set) var state = TabState()

  private init() {
    load()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      state = try JSONDecoder().decode(TabState.self, from: data)
    } catch {
      let ts = Int(Date().timeIntervalSince1970)
      let backup = fileURL.appendingPathExtension("corrupt.\(ts)")
      try? FileManager.default.moveItem(at: fileURL, to: backup)
      NSLog("[TabStateStore] decode failed (%@), backed up to %@", "\(error)", backup.lastPathComponent)
      state = TabState()
    }
  }

  func snapshot() -> TabState { state }

  func update(_ mutate: (inout TabState) -> Void) {
    mutate(&state)
    scheduleSave()
  }

  func flushNow() {
    pendingWork?.cancel()
    pendingWork = nil
    guard dirty else { return }
    let snap = state
    ioQueue.sync { self.write(snap) }
  }

  private func scheduleSave() {
    dirty = true
    pendingWork?.cancel()
    let snap = state
    let work = DispatchWorkItem { [weak self] in
      self?.write(snap)
    }
    pendingWork = work
    ioQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
  }

  private func write(_ snap: TabState) {
    do {
      let data = try JSONEncoder().encode(snap)
      try data.write(to: fileURL, options: [.atomic])
      dirty = false
    } catch {
      NSLog("[TabStateStore] write failed: %@", "\(error)")
    }
  }
}
