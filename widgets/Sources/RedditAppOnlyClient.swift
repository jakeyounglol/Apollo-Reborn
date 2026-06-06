import Foundation
import os

let rwLog = Logger(subsystem: "com.christianselig.Apollo.RebornWidgets", category: "widget")

/// URLSession with tight timeouts so the widget never hangs past WidgetKit's
/// timeline budget.
let rwSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 8
    cfg.timeoutIntervalForResource = 12
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
}()

/// Minimal Reddit client using the **app-only** OAuth grant
/// (`grant_type=...installed_client`). This requires only a client_id — no
/// user login — and can read public subreddits like r/showerthoughts.
///
/// Validated by hand:
///   POST https://www.reddit.com/api/v1/access_token   (Basic clientID:"")
///   GET  https://oauth.reddit.com/r/showerthoughts/top?t=day&limit=N
struct RedditAppOnlyClient {
    let clientID: String
    let userAgent: String

    enum ClientError: Error { case http(Int), badResponse, noToken }

    // MARK: Token cache (per-extension UserDefaults; no cross-process sharing)

    private static let defaults = UserDefaults.standard
    private static let tokenKey = "rw.appOnlyToken"
    private static let tokenExpiryKey = "rw.appOnlyTokenExpiry"
    private static let tokenClientKey = "rw.appOnlyTokenClient"
    private static let deviceIDKey = "rw.deviceID"

    /// Stable per-install device id required by the installed_client grant.
    private static var deviceID: String {
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let new = UUID().uuidString
        defaults.set(new, forKey: deviceIDKey)
        return new
    }

    private func cachedToken() -> String? {
        let d = Self.defaults
        guard d.string(forKey: Self.tokenClientKey) == clientID,
              let token = d.string(forKey: Self.tokenKey) else { return nil }
        let expiry = d.double(forKey: Self.tokenExpiryKey)
        // Refresh a little early to avoid edge-of-expiry failures.
        guard expiry - 120 > Date().timeIntervalSince1970 else { return nil }
        return token
    }

    private func storeToken(_ token: String, expiresIn: Double) {
        let d = Self.defaults
        d.set(token, forKey: Self.tokenKey)
        d.set(clientID, forKey: Self.tokenClientKey)
        d.set(Date().timeIntervalSince1970 + expiresIn, forKey: Self.tokenExpiryKey)
    }

    // MARK: OAuth

    private func fetchToken() async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // HTTP Basic: clientID as username, empty password.
        let basic = Data("\(clientID):".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=https://oauth.reddit.com/grants/installed_client&device_id=\(Self.deviceID)"
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await rwSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else { throw ClientError.http(http.statusCode) }

        struct TokenResponse: Codable { let access_token: String; let expires_in: Double }
        guard let tr = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ClientError.noToken
        }
        storeToken(tr.access_token, expiresIn: tr.expires_in)
        return tr.access_token
    }

    private func token() async throws -> String {
        if let cached = cachedToken() { return cached }
        return try await fetchToken()
    }

    // MARK: Data

    /// Convenience used by the Showerthoughts widget.
    func topShowerthoughts(limit: Int = 25) async throws -> [RedditPost] {
        try await topPosts(subreddit: "showerthoughts", sort: .top, limit: limit)
    }

    func topPosts(subreddit: String, sort: WidgetSort, limit: Int = 25) async throws -> [RedditPost] {
        let bearer = try await token()
        let sub = RedditPost.normalizeSubreddit(subreddit)
        var comps = URLComponents(string: "https://oauth.reddit.com/r/\(sub)/\(sort.path)")!
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "raw_json", value: "1"),
        ]
        if let t = sort.timeWindow { items.append(URLQueryItem(name: "t", value: t)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await rwSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else { throw ClientError.http(http.statusCode) }
        return Self.parseListing(data)
    }

    /// A subreddit's icon URL (community_icon preferred, else icon_img), or nil.
    func subredditIcon(_ subreddit: String) async throws -> String? {
        let bearer = try await token()
        let sub = RedditPost.normalizeSubreddit(subreddit)
        var req = URLRequest(url: URL(string: "https://oauth.reddit.com/r/\(sub)/about?raw_json=1")!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await rwSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }
        for key in ["community_icon", "icon_img"] {
            if let u = d[key] as? String, u.hasPrefix("http") { return u }
        }
        return nil
    }

    /// Parse a Reddit listing into posts, skipping stickied/meta entries.
    static func parseListing(_ data: Data) -> [RedditPost] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let children = dataObj["children"] as? [[String: Any]] else { return [] }

        var out: [RedditPost] = []
        for child in children {
            guard let post = child["data"] as? [String: Any],
                  let title = post["title"] as? String,
                  !(post["stickied"] as? Bool ?? false) else { continue }

            let postHint = post["post_hint"] as? String ?? ""
            let isImage = postHint == "image"
                || (post["url"] as? String).map { Self.looksLikeImage($0) } ?? false

            out.append(RedditPost(
                id: post["id"] as? String ?? UUID().uuidString,
                title: title,
                author: post["author"] as? String ?? "",
                subreddit: post["subreddit"] as? String ?? "",
                score: post["score"] as? Int ?? 0,
                numComments: post["num_comments"] as? Int ?? 0,
                permalink: post["permalink"] as? String ?? "",
                selftext: post["selftext"] as? String ?? "",
                thumbnailURL: Self.thumbnail(from: post),
                imageURL: Self.previewImage(from: post),
                isImagePost: isImage))
        }
        return out
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { lower.hasSuffix($0) }
    }

    /// Small square-ish thumbnail for feed rows.
    private static func thumbnail(from post: [String: Any]) -> String? {
        if let t = post["thumbnail"] as? String, t.hasPrefix("http") { return t }
        // Fall back to the smallest preview resolution.
        if let res = previewResolutions(from: post), let first = res.first,
           let u = first["url"] as? String { return u }
        return nil
    }

    /// A medium preview resolution (≤ ~640px) suitable for Photo/Single Post.
    private static func previewImage(from post: [String: Any]) -> String? {
        guard let res = previewResolutions(from: post) else { return nil }
        // Pick the largest resolution at or under 640px wide, else the largest.
        let sorted = res.compactMap { r -> (Int, String)? in
            guard let w = r["width"] as? Int, let u = r["url"] as? String else { return nil }
            return (w, u)
        }.sorted { $0.0 < $1.0 }
        if let pick = sorted.last(where: { $0.0 <= 640 }) ?? sorted.last {
            return pick.1
        }
        return nil
    }

    private static func previewResolutions(from post: [String: Any]) -> [[String: Any]]? {
        guard let preview = post["preview"] as? [String: Any],
              let images = preview["images"] as? [[String: Any]],
              let first = images.first,
              let resolutions = first["resolutions"] as? [[String: Any]] else { return nil }
        return resolutions
    }
}
