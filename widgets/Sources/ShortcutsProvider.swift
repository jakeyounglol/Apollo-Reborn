import WidgetKit
import Foundation

/// One subreddit shortcut tile.
struct ShortcutItem: Hashable {
    let subreddit: String
    let iconData: Data?
}

struct ShortcutsEntry: TimelineEntry {
    let date: Date
    let items: [ShortcutItem]
    let needsConfig: Bool

    static let placeholder = ShortcutsEntry(
        date: Date(),
        items: ["apple", "ios", "apolloapp", "showerthoughts", "aww", "EarthPorn", "todayilearned", "popular"]
            .map { ShortcutItem(subreddit: $0, iconData: nil) },
        needsConfig: false)
}

/// Subreddit shortcuts: a configurable grid of tappable subreddits that open in
/// Apollo. No network is required (tiles fall back to letter avatars); if the
/// shared setup code is present, real subreddit icons are fetched.
struct ShortcutsProvider: IntentTimelineProvider {
    typealias Entry = ShortcutsEntry
    typealias Intent = ShortcutsConfigurationIntent

    func placeholder(in context: Context) -> ShortcutsEntry { .placeholder }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (ShortcutsEntry) -> Void) {
        let subs = Self.parseSubs(configuration.subreddits)
        if subs.isEmpty { completion(.placeholder); return }
        completion(ShortcutsEntry(date: Date(),
                                  items: subs.map { ShortcutItem(subreddit: $0, iconData: nil) },
                                  needsConfig: false))
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<ShortcutsEntry>) -> Void) {
        let subs = Self.parseSubs(configuration.subreddits)
        guard !subs.isEmpty else {
            completion(Timeline(entries: [ShortcutsEntry(date: Date(), items: [], needsConfig: true)],
                                policy: .never))
            return
        }

        Task {
            var items = subs.map { ShortcutItem(subreddit: $0, iconData: nil) }
            // Best-effort icons via the shared setup code; letter avatars otherwise.
            if let creds = SetupCode.resolve(configuration.setupCode) {
                let client = RedditAppOnlyClient(clientID: creds.clientID, userAgent: creds.resolvedUserAgent)
                items = await Self.withIcons(subs, client: client)
            }
            // Refresh icons daily; subreddit icons rarely change.
            completion(Timeline(entries: [ShortcutsEntry(date: Date(), items: items, needsConfig: false)],
                                policy: .after(Date().addingTimeInterval(24 * 60 * 60))))
        }
    }

    /// Concurrently fetch + downsample each subreddit's icon, preserving order.
    private static func withIcons(_ subs: [String], client: RedditAppOnlyClient) async -> [ShortcutItem] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, sub) in subs.enumerated() {
                group.addTask {
                    let url = try? await client.subredditIcon(sub)
                    let data = await ImageLoader.fetchDownsampled(url ?? nil, maxPixel: 120)
                    return (i, data)
                }
            }
            var byIndex: [Int: Data?] = [:]
            for await (i, data) in group { byIndex[i] = data }
            return subs.enumerated().map { ShortcutItem(subreddit: $1, iconData: byIndex[$0] ?? nil) }
        }
    }

    /// Split a user-typed list on commas/whitespace/newlines, normalize, dedupe,
    /// cap at 12 (the large family's capacity).
    static func parseSubs(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let parts = raw.split(whereSeparator: { ", \n\t".contains($0) })
        var seen = Set<String>()
        var out: [String] = []
        for p in parts {
            let s = RedditPost.normalizeSubreddit(String(p))
            guard !s.isEmpty else { continue }
            let lower = s.lowercased()
            if seen.insert(lower).inserted { out.append(s) }
            if out.count == 12 { break }
        }
        return out
    }
}
