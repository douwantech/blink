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
      race.noteAcknowledged(personalHeader: "13", username: "carol")
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
    precondition(VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:13", ownVersion: "7:13", acknowledgedPersonal: nil))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: false, snapshotVersion: "7:13", ownVersion: "7:13", acknowledgedPersonal: nil))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:14", ownVersion: "7:13", acknowledgedPersonal: nil))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:13", ownVersion: nil, acknowledgedPersonal: nil))
    precondition(VoiceInputAccount.personalComponent("12:34") == 34)
    // +1 判定落空（并发另一台设备写入 → +2，或幂等重试 → 不 +1）时，
    // 响应头真值下限仍要保住待上传的个人改动。
    precondition(VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:14", ownVersion: nil, acknowledgedPersonal: 14))
    precondition(VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "8:14", ownVersion: nil, acknowledgedPersonal: 14))
    precondition(!VoiceInputAccount.keepPendingPersonal(localDirty: true, snapshotVersion: "7:15", ownVersion: nil, acknowledgedPersonal: 14))

    // --- Counter-evidence A: concurrent device write makes the personal version +2,
    // so the +1 recognition is nil. The X-Personal-Version header is still a reliable
    // floor, so the late in-flight GET must not re-adopt the older favorites.
    let c2Name = "BlinkVoiceInputPlusTwo.\(UUID().uuidString)"
    let c2Defaults = UserDefaults(suiteName: c2Name)!
    defer { c2Defaults.removePersistentDomain(forName: c2Name) }
    let c2 = VoiceInputAccount(defaults: c2Defaults)
    c2.prepareAccount("erin")
    c2.adopt(AccountVoiceInput(favorites: ["old"]), version: "7:12", username: "erin")
    c2.perform("addFavorite", text: "fresh")
    let ops2 = c2.pending(username: "erin")
    precondition(ops2.count == 1)
    precondition(VoiceInputAccount.ownConfigVersion(previous: "7:12", personal: "14") == nil,
                 "+1 recognition must fail for a concurrent +2 write")
    var doc2 = AccountVoiceInput(favorites: ["old"])
    for op in ops2 { doc2.apply(op) }
    c2.noteAcknowledged(personalHeader: "14", username: "erin")   // 响应头真值 = 下限
    c2.acknowledge(ops2, remote: doc2, username: "erin")
    precondition(c2.snapshot.favorites == ["old", "fresh"])
    let late = c2.adopt(AccountVoiceInput(favorites: ["old"]), version: "7:13", username: "erin")
    precondition(!late, "a late GET older than the header floor must not be adopted")
    precondition(c2.snapshot.favorites == ["old", "fresh"])
    precondition(c2.pending(username: "erin").isEmpty)

    // --- Counter-evidence B: idempotent retry. The server already applied this
    // version, so the response header equals the cached version and previous+1 does
    // not hold. The header is still the floor that rejects a late older GET.
    let c3Name = "BlinkVoiceInputRetry.\(UUID().uuidString)"
    let c3Defaults = UserDefaults(suiteName: c3Name)!
    defer { c3Defaults.removePersistentDomain(forName: c3Name) }
    let c3 = VoiceInputAccount(defaults: c3Defaults)
    c3.prepareAccount("frank")
    c3.adopt(AccountVoiceInput(favorites: ["a"]), username: "frank")   // no version → no floor
    c3.perform("addFavorite", text: "b")
    let ops3 = c3.pending(username: "frank")
    precondition(ops3.count == 1)
    precondition(VoiceInputAccount.ownConfigVersion(previous: "7:13", personal: "13") == nil,
                 "an idempotent retry does not advance the personal version")
    var doc3 = AccountVoiceInput(favorites: ["a"])
    for op in ops3 { doc3.apply(op) }
    c3.noteAcknowledged(personalHeader: "13", username: "frank")
    c3.acknowledge(ops3, remote: doc3, username: "frank")
    precondition(c3.snapshot.favorites == ["a", "b"])
    precondition(!c3.adopt(AccountVoiceInput(favorites: ["a"]), version: "7:12", username: "frank"))
    precondition(c3.snapshot.favorites == ["a", "b"])

    // --- Counter-evidence C: two refreshes answer out of order. The higher-version
    // response lands first and must raise the floor, so the lower one that lands
    // later cannot roll the state back. (adopt() advancing the floor is what does it.)
    let c4Name = "BlinkVoiceInputOutOfOrder.\(UUID().uuidString)"
    let c4Defaults = UserDefaults(suiteName: c4Name)!
    defer { c4Defaults.removePersistentDomain(forName: c4Name) }
    let c4 = VoiceInputAccount(defaults: c4Defaults)
    c4.prepareAccount("gina")
    precondition(c4.adopt(AccountVoiceInput(favorites: ["v14"]), version: "7:14", username: "gina"))
    precondition(!c4.adopt(AccountVoiceInput(favorites: ["v13"]), version: "7:13", username: "gina"),
                 "the out-of-order older response must not roll the state back")
    precondition(c4.snapshot.favorites == ["v14"])
    precondition(c4.adopt(AccountVoiceInput(favorites: ["v15"]), version: "7:15", username: "gina"),
                 "a genuinely newer snapshot is still adopted")
    precondition(c4.snapshot.favorites == ["v15"])

    print("PASS: migration, offline/restart, concurrent devices, in-flight edits, account isolation, stale in-flight snapshot, pending-personal rule, header-floor (+2 / retry / out-of-order)")
  }
}
