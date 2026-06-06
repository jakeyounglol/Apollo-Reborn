import SwiftUI
import WidgetKit

struct ShortcutsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShortcutsEntry

    private var columns: Int {
        switch family {
        case .systemLarge: return 4
        case .systemMedium: return 4
        default: return 2   // small
        }
    }
    private var maxItems: Int {
        switch family {
        case .systemLarge: return 12
        case .systemMedium: return 8
        default: return 4
        }
    }

    var body: some View {
        Group {
            if entry.needsConfig {
                MessageView(icon: "square.grid.2x2",
                            title: "Add subreddits",
                            detail: "Edit this widget and type subreddits (comma or space separated), e.g. aww, apple, EarthPorn.")
            } else {
                grid
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.10, green: 0.11, blue: 0.13) }
    }

    private var grid: some View {
        let items = Array(entry.items.prefix(maxItems))
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: columns)
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(items, id: \.subreddit) { item in
                tile(item)
            }
        }
    }

    @ViewBuilder private func tile(_ item: ShortcutItem) -> some View {
        let content = VStack(spacing: 3) {
            avatar(item)
            Text("r/\(item.subreddit)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        if let url = RedditPost.subredditURL(item.subreddit) {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    @ViewBuilder private func avatar(_ item: ShortcutItem) -> some View {
        let size: CGFloat = family == .systemSmall ? 30 : 34
        if let img = imageFromData(item.iconData) {
            img.resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(color(for: item.subreddit))
                Text(String(item.subreddit.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    /// Stable per-subreddit color for the letter avatar.
    private func color(for sub: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]
        let idx = abs(sub.lowercased().hashValue) % palette.count
        return palette[idx]
    }
}
