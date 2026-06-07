import AppIntents
import WidgetKit
import Foundation

/// Per-widget rotation offset, keyed by the widget's cache key (e.g.
/// "showerthoughts", "single.aww"). The interactive button bumps it; the
/// provider rotates that widget's cached posts so a new one shows first.
/// Lives in the extension's own UserDefaults — survives across refreshes.
enum Rotation {
    private static let defaults = UserDefaults.standard
    private static func key(_ k: String) -> String { "rw.offset.\(k)" }

    static func offset(_ k: String) -> Int { defaults.integer(forKey: key(k)) }
    static func advance(_ k: String) { defaults.set(offset(k) + 1, forKey: key(k)) }

    /// Rotate `posts` so the current offset for `k` is first.
    static func rotated<T>(_ k: String, _ posts: [T]) -> [T] {
        guard posts.count > 1 else { return posts }
        let off = ((offset(k) % posts.count) + posts.count) % posts.count
        return Array(posts[off...] + posts[..<off])
    }
}

/// Short-lived request made by an interactive widget button. WidgetKit does not
/// pass button context into `getTimeline`, so providers read this flag on reload.
enum RefreshRequest {
    private static let defaults = UserDefaults.standard
    private static func key(_ kind: String) -> String { "rw.refreshLatest.\(kind)" }
    private static let lifetime: TimeInterval = 2 * 60

    static func requestLatest(kind: String) {
        defaults.set(Date().timeIntervalSince1970 + lifetime, forKey: key(kind))
    }

    static func wantsLatest(kind: String) -> Bool {
        defaults.double(forKey: key(kind)) > Date().timeIntervalSince1970
    }
}

/// Interactive "show me another" button — confirmed to fire under Feather
/// (AppIntents perform() works at runtime even though AppIntents *config*
/// doesn't survive re-signing). The widget's cache key is passed in so the
/// right widget advances. Widget button intents must carry assigned parameter
/// values (no resolution).
struct NextItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Another Post"
    static var description = IntentDescription("Show the next post in this widget.")

    @Parameter(title: "Key") var key: String

    init() {}
    init(key: String) { self.key = key }

    func perform() async throws -> some IntentResult {
        Rotation.advance(key)        // returning reloads the timeline
        return .result()
    }
}

/// Force a fresh fetch for one widget kind (used by Feed, which is a list and
/// doesn't rotate).
struct ReloadKindIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh"
    static var description = IntentDescription("Reload this widget.")

    @Parameter(title: "Kind") var kind: String

    init() {}
    init(kind: String) { self.kind = kind }

    func perform() async throws -> some IntentResult {
        RefreshRequest.requestLatest(kind: kind)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        return .result()
    }
}
