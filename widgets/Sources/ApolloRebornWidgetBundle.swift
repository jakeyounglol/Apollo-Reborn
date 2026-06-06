import WidgetKit
import SwiftUI

@main
struct ApolloRebornWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShowerthoughtsWidget()
        JokesWidget()
        SinglePostWidget()
        FeedWidget()
        PhotoWidget()
        ShortcutsWidget()
    }
}

struct ShortcutsWidget: Widget {
    let kind = "ShortcutsWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: ShortcutsConfigurationIntent.self,
                            provider: ShortcutsProvider()) { entry in
            ShortcutsWidgetView(entry: entry)
        }
        .configurationDisplayName("Shortcuts")
        .description("Quick links to your favorite subreddits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShowerthoughtsWidget: Widget {
    let kind = "ShowerthoughtsWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: ShowerthoughtsConfigurationIntent.self,
                            provider: ShowerthoughtsProvider()) { entry in
            ShowerthoughtsWidgetView(entry: entry)
        }
        .configurationDisplayName("Showerthoughts")
        .description("Top posts from r/showerthoughts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct JokesWidget: Widget {
    let kind = "JokesWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: JokesConfigurationIntent.self,
                            provider: JokesProvider()) { entry in
            JokesWidgetView(entry: entry)
        }
        .configurationDisplayName("Jokes")
        .description("A joke from r/Jokes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SinglePostWidget: Widget {
    let kind = "SinglePostWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: SubredditConfigurationIntent.self,
                            provider: SinglePostProvider()) { entry in
            SinglePostWidgetView(entry: entry)
        }
        .configurationDisplayName("Post")
        .description("The top post from a subreddit you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct FeedWidget: Widget {
    let kind = "FeedWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: SubredditConfigurationIntent.self,
                            provider: FeedProvider()) { entry in
            FeedWidgetView(entry: entry)
        }
        .configurationDisplayName("Feed")
        .description("Top posts from a subreddit you choose.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PhotoWidget: Widget {
    let kind = "PhotoWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: SubredditConfigurationIntent.self,
                            provider: PhotoProvider()) { entry in
            PhotoWidgetView(entry: entry)
        }
        .configurationDisplayName("Photo")
        .description("The top image from a subreddit you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
