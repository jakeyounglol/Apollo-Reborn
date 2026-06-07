import WidgetKit
import Foundation

// MARK: Subreddit config helpers

private func resolvedSubreddit(_ raw: String?, default def: String) -> String {
    let s = RedditPost.normalizeSubreddit(raw ?? "")
    return s.isEmpty ? def : s
}

private func widgetSort(_ sort: RebornSort, default def: WidgetSort) -> WidgetSort {
    switch sort {
    case .hot: return .hot
    case .new: return .new
    case .top: return .top
    case .week: return .topWeek
    @unknown default: return def
    }
}

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
        if let first = PostCache.load("single.\(sub)\(nsfw ? ".x" : "")").first {
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
        // Keep NSFW + SFW pools in separate cache buckets so toggling the
        // setting never leaves stale opposite-rated posts on screen.
        let key = "single.\(sub)\(nsfw ? ".x" : "")"
        runPostTimeline(
            code: configuration.setupCode, cacheKey: key,
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 50, allowNSFW: nsfw) },
            assemble: { posts in
                stamped(await assembleWithImages(posts, key: key, maxPixel: 600),
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
        let cached = PostCache.load("feed.\(sub)")
        if !cached.isEmpty {
            completion(WidgetEntry(date: Date(),
                                   state: .posts(cached.map { RenderPost(post: $0, imageData: nil) }),
                                   sourceLabel: label))
        } else { completion(.sample(WidgetSample.feed, sourceLabel: label)) }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "popular")
        let sort: WidgetSort = RefreshRequest.wantsLatest(kind: "FeedWidget")
            ? .new
            : widgetSort(configuration.sort, default: .hot)
        let label = feedSourceLabel(sub)
        runPostTimeline(
            code: configuration.setupCode, cacheKey: "feed.\(sub)",
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 12) },
            assemble: { posts in
                // Download small thumbnails (concurrently) for the rows shown.
                let renders = await downloadImages(Array(posts.prefix(8)),
                                                   keyPath: { $0.thumbnailURL }, maxPixel: 160)
                return stamped(listTimeline(renders, key: "feed.\(sub)"), sourceLabel: label)
            },
            completion: completion)
    }
}

// MARK: Photo (configurable subreddit, image-only)

struct PhotoProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = SubredditConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.feed[4]]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.sample([WidgetSample.feed[4]])); return }
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        if let first = PostCache.load("photo.\(sub)").first {
            completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: first, imageData: nil)])))
        } else { completion(.sample([WidgetSample.feed[4]])) }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        // Photos default to Top (best images) when no sort is chosen.
        let sort = widgetSort(configuration.sort, default: .top)
        runPostTimeline(
            code: configuration.setupCode, cacheKey: "photo.\(sub)",
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 25).filter { $0.isImagePost } },
            assemble: { await assembleWithImages($0, key: "photo.\(sub)", maxPixel: 800) },
            completion: completion)
    }
}
