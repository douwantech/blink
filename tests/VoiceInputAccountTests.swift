import Foundation

@main struct VoiceInputAccountTests {
  static func main() {
    precondition(VoiceInputAccount.ownConfigVersion(previous: "7:12", personal: "13") == "7:13")
    precondition(VoiceInputAccount.ownConfigVersion(previous: "7:12", personal: "14") == nil)
    precondition(VoiceInputAccount.ownConfigVersion(previous: nil, personal: "13") == nil)
    let name = "BlinkVoiceInputTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = VoiceInputAccount(defaults: defaults)
    store.perform("addFavorite", text: " old favorite ")
    store.perform("useFavorite", text: "old favorite")
    store.perform("recordHistory", text: "old submission")
    store.prepareAccount("alice")
    store.adopt(nil, username: "alice")
    let seed = store.pending(username: "alice")
    precondition(seed.count == 1 && seed[0].kind == "seed")
    precondition(seed[0].data?.favoriteCounts["old favorite"] == 1)
    store.acknowledge(seed, remote: seed[0].data!, username: "alice")
    precondition(store.pending(username: "alice").isEmpty)

    // Offline edits survive process restart and a newer remote snapshot.
    store.perform("addFavorite", text: "offline favorite")
    store.perform("removeFavorite", text: "old favorite")
    store.perform("recordHistory", text: "offline submission")
    let restarted = VoiceInputAccount(defaults: defaults)
    let remote = AccountVoiceInput(favorites: ["old favorite", "other device"],
      history: ["other submission"], favoriteCounts: ["old favorite": 5])
    restarted.adopt(remote, username: "alice")
    precondition(restarted.snapshot.favorites == ["other device", "offline favorite"])
    precondition(restarted.snapshot.history == ["other submission", "offline submission"])
    precondition(restarted.snapshot.favoriteCounts["old favorite"] == nil)
    let sent = restarted.pending(username: "alice")
    restarted.perform("recordHistory", text: "typed during upload")
    var applied = remote
    for op in sent { applied.apply(op) }
    restarted.acknowledge(sent, remote: applied, username: "alice")
    precondition(restarted.pending(username: "alice").count == 1)
    precondition(restarted.snapshot.history.last == "typed during upload")

    // An old response and offline queue must not spill into another account.
    restarted.prepareAccount("bob", previous: "alice")
    precondition(restarted.snapshot == AccountVoiceInput())
    precondition(restarted.pending(username: "alice").isEmpty)
    restarted.adopt(AccountVoiceInput(), username: "bob")
    precondition(restarted.pending(username: "bob").isEmpty)
    restarted.acknowledge(sent, remote: remote, username: "alice")
    precondition(restarted.snapshot == AccountVoiceInput())
    restarted.perform("addFavorite", text: "bob only")
    precondition(restarted.pending(username: "alice").isEmpty)
    precondition(restarted.pending(username: "bob").count == 1)
    print("PASS: migration, offline/restart, concurrent devices, in-flight edits, account isolation")
  }
}
