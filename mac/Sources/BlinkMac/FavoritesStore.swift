import Foundation

/// Favorites now use the Blink account cache. The cloud argument remains for
/// existing callers; iCloud is only read once by ServerSync during migration.
enum FavoritesStore {
    static let kFav = "VoiceInputView.aiFavorites"
    static let kCounts = "VoiceInputView.aiFavoriteCounts"

    static func entries(cloud: Bool) -> [String] {
        let state = VoiceInputAccount.shared.snapshot
        return state.favorites.enumerated().sorted { l, r in
            let lc = state.favoriteCounts[l.element] ?? 0
            let rc = state.favoriteCounts[r.element] ?? 0
            return lc != rc ? lc > rc : l.offset > r.offset
        }.map { $0.element }
    }

    static func isFavorited(_ text: String, cloud: Bool) -> Bool {
        VoiceInputAccount.shared.snapshot.favorites.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func add(_ text: String, cloud: Bool) {
        guard !isFavorited(text, cloud: cloud) else { return }
        VoiceInputAccount.shared.perform("addFavorite", text: text)
    }

    static func remove(_ text: String, cloud: Bool) {
        VoiceInputAccount.shared.perform("removeFavorite", text: text)
    }

    static func incrementUse(_ text: String, cloud: Bool) {
        VoiceInputAccount.shared.perform("useFavorite", text: text)
    }
}
