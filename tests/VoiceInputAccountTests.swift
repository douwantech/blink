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

    // --- Review race: a GET issued before the voice POST (an in-flight refresh) ---
    // --- lands *after* the ack and used to re-adopt the older favorites.      ---
    let raceName = "BlinkVoiceInputRace.\(UUID().uuidString)"
    let raceDefaults = UserDefaults(suiteName: raceName)!
    defer { raceDefaults.removePersistentDomain(forName: raceName) }
    let race = VoiceInputAccount(defaults: raceDefaults)
    race.prepareAccount("carol")
    race.adopt(AccountVoiceInput(favorites: ["old"]), version: "7:12", username: "carol")
    precondition(race.snapshot.favorites == ["old"])
    race.perform("addFavorite", text: "fresh")
    let sentOps = race.pending(username: "carol")
    precondition(sentOps.count == 1)
    var serverDoc = AccountVoiceInput(favorites: ["old"])
    for op in sentOps { serverDoc.apply(op) }

    // Two real async hops on one queue: POST+ack first, the stale GET lands after it.
    let raceQ = DispatchQueue(label: "voice-race")
    let acked = DispatchSemaphore(value: 0)
    let staleLanded = DispatchSemaphore(value: 0)
    raceQ.async {
      race.markAcknowledged(version: "7:13", username: "carol")
      race.acknowledge(sentOps, remote: serverDoc, username: "carol")
      acked.signal()
    }
    raceQ.async {
      acked.wait()
      race.adopt(AccountVoiceInput(favorites: ["old"]), version: "7:12", username: "carol")
      staleLanded.signal()
    }
    staleLanded.wait()
    precondition(race.snapshot.favorites == ["old", "fresh"],
                 "a stale in-flight snapshot must not undo an acknowledged upload")
    precondition(race.pending(username: "carol").isEmpty)
    // A snapshot at the acknowledged version (or newer) is still adopted normally.
    race.adopt(AccountVoiceInput(favorites: ["old", "fresh", "other device"]), version: "7:13", username: "carol")
    precondition(race.snapshot.favorites.contains("other device"))
    // The acknowledged version belongs to the account: switching clears it, so a low
    // version from the new account is not blocked by the previous account's number.
    race.prepareAccount("dave", previous: "carol")
    race.adopt(AccountVoiceInput(favorites: ["dave only"]), version: "3:1", username: "dave")
    precondition(race.snapshot.favorites == ["dave only"])

    // --- rest/agents made while the voice POST is in flight must not be dropped --
    // (that is the version rule ServerConfigSync.apply() uses: a snapshot whose
    // version is exactly the one our own POST produced is not "server advanced").
    precondition(VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:13", ownVersion: "7:13"))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: false, snapshotVersion: "7:13", ownVersion: "7:13"))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:14", ownVersion: "7:13"))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:13", ownVersion: nil))
    precondition(VoiceInputAccount.personalComponent("12:34") == 34)

    print("PASS: migration, offline/restart, concurrent devices, in-flight edits, account isolation, stale in-flight snapshot, pending-personal rule")
  }
}
