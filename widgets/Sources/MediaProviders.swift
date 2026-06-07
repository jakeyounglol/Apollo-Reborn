import WidgetKit
import Foundation

// MARK: Subreddit config helpers

func resolvedSubreddit(_ raw: String?, default def: String) -> String {
    let s = RedditPost.normalizeSubreddit(raw ?? "")
    return s.isEmpty ? def : s
}

func widgetSort(_ sort: RebornSort, default def: WidgetSort) -> WidgetSort {
    switch sort {
    case .hot: return .hot
    case .new: return .new
    case .top: return .top
    case .week: return .topWeek
    @unknown default: return def
    }
}

/// Cache-key suffix that distinguishes one sort from another, so a fetch failure
/// (e.g. a 429) for "top" never falls back to the cached "hot" posts. Without
/// this every sort shared one bucket and looked like the sort was ignored.
func sortSuffix(_ s: WidgetSort) -> String { ".\(s.path)\(s.timeWindow ?? "")" }

/// Map the SiriKit Display enum to our render mode. `.unknown` (unset) → Standard.
private func displayMode(_ d: RebornDisplay) -> DisplayMode {
    switch d {
    case .clean: return .clean
    case .standard: return .standard
    case .detailed: return .detailed
    @unknown default: return .standard
    }
}

// MARK: Jokes (fixed r/Jokes, text)

struct JokesProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = JokesConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.joke]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.sample([WidgetSample.joke])); return }
        if let first = PostCache.load("jokes").first {
            completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: first, imageData: nil)])))
        } else { completion(.sample([WidgetSample.joke])) }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        runPostTimeline(
            code: configuration.setupCode, cacheKey: "jokes",
            fetch: { try await $0.topPosts(subreddit: "Jokes", sort: .top, limit: 25) },
            assemble: { assembleText($0.filter { !$0.selftext.isEmpty }, key: "jokes") },
            completion: completion)
    }
}

// MARK: Single Post (configurable subreddit, image)

struct SinglePostProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = PostConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.post]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        let display = displayMode(configuration.display)
        let showPreview = configuration.showPreview?.boolValue ?? false
        if context.isPreview {
            completion(WidgetEntry(date: Date(),
                                   state: .posts([RenderPost(post: WidgetSample.post, imageData: nil)]),
                                   display: display, showPreview: showPreview))
            return
        }
        let sub = resolvedSubreddit(configuration.subreddit, default: "popular")
        let nsfw = configuration.allowNSFW?.boolValue ?? false
        let sort = widgetSort(configuration.sort, default: .hot)
        if let first = PostCache.load("single.\(sub)\(sortSuffix(sort))\(nsfw ? ".x" : "")").first {
            completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: first, imageData: nil)]),
                                   display: display, showPreview: showPreview))
        } else {
            completion(WidgetEntry(date: Date(),
                                   state: .posts([RenderPost(post: WidgetSample.post, imageData: nil)]),
                                   display: display, showPreview: showPreview))
        }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "popular")
        let sort = widgetSort(configuration.sort, default: .hot)
        let nsfw = configuration.allowNSFW?.boolValue ?? false
        let display = displayMode(configuration.display)
        let showPreview = configuration.showPreview?.boolValue ?? false
        // Keep NSFW + SFW pools AND each sort in separate cache buckets so
        // toggling never leaves stale opposite-rated or wrong-sort posts.
        let key = "single.\(sub)\(sortSuffix(sort))\(nsfw ? ".x" : "")"
        // Lock-screen (accessory) widgets are text-only — skip image downloads
        // so the timeline builds fast and never risks the tight accessory
        // reload budget (a slow build shows the redacted placeholder skeleton).
        let accessory = isAccessoryFamily(context.family)
        rwLog.log("getTimeline Post r/\(sub, privacy: .public) family=\(familyName(context.family), privacy: .public) sortRaw=\(configuration.sort.rawValue) → \(sort.path, privacy: .public)")
        runPostTimeline(
            code: configuration.setupCode, cacheKey: key,
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 50, allowNSFW: nsfw) },
            assemble: { posts in
                if accessory {
                    return stamped(assembleText(posts, key: key), display: display, showPreview: showPreview)
                }
                return stamped(await assembleWithImages(posts, key: key, maxPixel: 600),
                               display: display, showPreview: showPreview)
            },
            completion: completion)
    }
}

// MARK: Feed (configurable subreddit, list)

struct FeedProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = SubredditConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample(WidgetSample.feed, sourceLabel: "Popular") }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "popular")
        let label = feedSourceLabel(sub)
        if context.isPreview { completion(.sample(WidgetSample.feed, sourceLabel: label)); return }
        let sort = widgetSort(configuration.sort, default: .hot)
        let cached = PostCache.load("feed.\(sub)\(sortSuffix(sort))")
        if !cached.isEmpty {
            completion(WidgetEntry(date: Date(),
                                   state: .posts(cached.map { RenderPost(post: $0, imageData: nil) }),
                                   sourceLabel: label))
        } else { completion(.sample(WidgetSample.feed, sourceLabel: label)) }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "popular")
        let sort = widgetSort(configuration.sort, default: .hot)
        let label = feedSourceLabel(sub)
        let key = "feed.\(sub)\(sortSuffix(sort))"
        rwLog.log("Feed r/\(sub, privacy: .public) sortRaw=\(configuration.sort.rawValue) → \(sort.path, privacy: .public)")
        runPostTimeline(
            code: configuration.setupCode, cacheKey: key,
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 12) },
            assemble: { posts in
                // Download small thumbnails (concurrently) for the rows shown.
                let renders = await downloadImages(Array(posts.prefix(8)),
                                                   keyPath: { $0.thumbnailURL }, maxPixel: 160)
                return stamped(listTimeline(renders, key: key), sourceLabel: label)
            },
            completion: completion)
    }
}

// MARK: Photo (configurable subreddit, image-only)

struct PhotoProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = PhotoConfigurationIntent

    /// Read the caption toggles. `showTitle` defaults to true (Photo's original
    /// behaviour); the rest default off to keep the minimal look.
    private func photoOptions(_ c: Intent) -> PhotoOptions {
        PhotoOptions(showTitle: c.showTitle?.boolValue ?? true,
                     showSubreddit: c.showSubreddit?.boolValue ?? false,
                     showStats: c.showStats?.boolValue ?? false)
    }

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.feed[4]]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        let opts = photoOptions(configuration)
        if context.isPreview {
            var e = WidgetEntry.sample([WidgetSample.feed[4]]); e.photo = opts
            completion(e); return
        }
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        let nsfw = configuration.allowNSFW?.boolValue ?? false
        let sort = widgetSort(configuration.sort, default: .top)
        if let first = PostCache.load("photo.\(sub)\(sortSuffix(sort))\(nsfw ? ".x" : "")").first {
            var e = WidgetEntry(date: Date(), state: .posts([RenderPost(post: first, imageData: nil)]))
            e.photo = opts
            completion(e)
        } else {
            var e = WidgetEntry.sample([WidgetSample.feed[4]]); e.photo = opts
            completion(e)
        }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        // Photos default to Top (best images) when no sort is chosen.
        let sort = widgetSort(configuration.sort, default: .top)
        let nsfw = configuration.allowNSFW?.boolValue ?? false
        let opts = photoOptions(configuration)
        // Separate NSFW/SFW + per-sort cache buckets so toggling never leaves
        // stale opposite-rated or wrong-sort images on screen.
        let key = "photo.\(sub)\(sortSuffix(sort))\(nsfw ? ".x" : "")"
        rwLog.log("Photo r/\(sub, privacy: .public) sortRaw=\(configuration.sort.rawValue) → \(sort.path, privacy: .public)")
        runPostTimeline(
            code: configuration.setupCode, cacheKey: key,
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 25, allowNSFW: nsfw).filter { $0.isImagePost } },
            assemble: { stamped(await assembleWithImages($0, key: key, maxPixel: 800), photo: opts) },
            completion: completion)
    }
}
