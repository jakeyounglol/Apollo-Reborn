# Boneman recommended settings mapping

This document records the implementation trace used by the one-time migration in
`ApolloRecommendedSettingsMigration.m`. All listed preferences use
`NSUserDefaults.standardUserDefaults` unless noted otherwise. The migration runs
after `registerDefaults:` and before `Tweak.xm` hydrates the `ApolloState` globals.

Secrets are intentionally excluded from the migration. GIPHY and Image Chest
credentials are standard-defaults values read into process memory at launch; the
reddit.com web-session cookie and modhash are stored by
`ApolloWebSessionStore.m` as generic-password Keychain items.

| UI control / requested state | Storage key and stored value | Registered default | Runtime consumer |
| --- | --- | --- | --- |
| Reddit API Key: preserve | `RedditApiClientId`, untouched | empty fallback | `Tweak.xm`, OAuth request hooks |
| Reddit API Secret: preserve | `RedditApiClientSecret`, untouched | `""` | `Tweak.xm`, `ApolloAccountCredentials.m` |
| Imgur API Key: unset | `ImgurApiClientId` removed | empty fallback | `Tweak.xm`, Imgur request hooks |
| GIPHY API Key: preserve | `GiphyAPIKey`, untouched | `""` | `ApolloGiphyClient.m` |
| Image Chest API Key: preserve | `ImageChestAPIToken`, untouched | `""` | `ApolloImgChestUpload.m` |
| reddit.com Web Sign-In: preserve | Keychain service `com.christianselig.Apollo.webjson`, untouched | none | `ApolloWebSessionStore.m`, `ApolloWebJSON.m` |
| API-Key-Free Mode: on | `WebJSONEnabled = YES` | `NO` | `ApolloWebJSON.m`, `ApolloWebJSONIdentity.xm` |
| Universal OAuth Sign-In: on | `UseCustomOAuthSignIn = YES` | `YES` | `Tweak.xm` OAuth hook |
| Modern Reddit Chat: on | `UseModernRedditChat = YES` | `NO` | `ApolloDirectChatWeb.xm`, `ApolloChatUnreadPoller.m` |
| Modern Moderator Mail: off | `UseModernRedditModmail = NO` and `ModernMailboxChoiceMigrated = YES` | `NO` / absent | `ApolloDirectChatWeb.xm` |
| Enable Tag Filters: on | `TagFilterEnabled = YES` | `NO` | `ApolloTagFilters.xm` |
| NSFW tag filter: off | `TagFilterNSFW = NO` | `YES` | `ApolloTagFilters.xm` |
| Spoiler tag filter: on | `TagFilterSpoiler = YES` | `YES` | `ApolloTagFilters.xm` |
| Tag mode and subreddit overrides: preserve | `TagFilterMode`, `TagFilterSubredditOverrides`, untouched | `"blur"`, `{}` | `ApolloTagFilters.xm` |
| Bulk Translation: on | `EnableBulkTranslation = YES` | `NO` | `ApolloTranslation.xm` |
| Target Language: device default | `TranslationTargetLanguage = ""` | `""` | `ApolloTranslation.xm` |
| Primary Provider: Apple On-Device | `TranslationProvider = "apple"`; `TranslationProviderUserSelected = YES` | unset / `NO` | `ApolloTranslation.xm`, `ApolloAppleTranslation.swift` |
| Apple Translate Sheet: on | `AppleTranslateSheet = YES` | `NO` | `ApolloAppleTranslateSheet.xm` |
| In-App PiP: on | `PictureInPictureEnabled = YES` | `NO` | `ApolloPictureInPicture.xm` |
| PiP default position: Top Right | `PictureInPictureStartPosition = 1` | Top Right (`1`) | `ApolloPictureInPicture.xm` |
| PiP hidden by default: off | `PictureInPictureStartHidden = NO` | `NO` | `ApolloPictureInPicture.xm` |
| PiP skip buttons / progress: on | `PictureInPictureSkipButtons = YES`; `PictureInPictureProgressBar = YES` | `NO` / `NO` | `ApolloPictureInPicture.xm` |
| PiP when leaving app: on | `PictureInPictureNative = YES` | `NO` | `ApolloPictureInPicture.xm` |
| PiP activation: unmuted videos only | `PictureInPictureActivation = 1` | Unmuted Only (`1`) | `ApolloPictureInPicture.xm` |
| PiP loop videos: on | `PictureInPictureLoop = YES` | `YES` | `ApolloPictureInPicture.xm` |
| Apollo AI: on | `EnableAISummaries = YES` | `NO` | `ApolloAISummary.xm` |
| AI Provider: Apple On-Device | `AISummaryProvider = "apple"` | `"apple"` | `ApolloAISummary.xm`, `ApolloFoundationModels.swift` |
| Post/Link Summaries: on | `EnableAIPostSummaries = YES` | `YES` | `ApolloAISummary.xm` |
| Minimum Post Length: 150 | `AIPostWordThreshold = 150` | `150` | `ApolloAISummary.xm` |
| Post/Link Detail: Balanced | `AIPostSummaryDetail = 1` | Balanced (`1`) | `ApolloAISummary.xm` |
| Comment Summaries: on | `EnableAICommentSummaries = YES` | `YES` | `ApolloAISummary.xm` |
| Discussion Detail: Balanced | `AICommentSummaryDetail = 1` | Balanced (`1`) | `ApolloAISummary.xm` |
| Generate on Open | `EnableTapToSummarize = NO`; `EnableAIAutoExpandSummaries = NO` | `NO` / `NO` | `ApolloAISummary.xm` |
| AI availability indicator | no stored override | live Foundation Models status | `ApolloFoundationModels.swift`, `ApolloAISettingsViewController.m` |
| Rich Link Body: Full | `LinkPreviewBodyMode = 2` | Full (`2`) | `ApolloInlineLinkPreviews.xm` |
| Rich Link Comments: Compact | `LinkPreviewCommentsMode = 1` | Full (`2`) | `ApolloInlineLinkPreviews.xm` |
| Rich Link Card Color: Default | `LinkPreviewCardColorHex = ""` | empty on hydration | `ApolloCommon.m`, link preview renderers |
| Icon-Only Tab Bar: off | `HideTabBarTitles = NO` | `NO` | `ApolloTabBarTitles.xm` |
| Recently Read Thumbnails: on | `ShowRecentlyReadThumbnails = YES` | `YES` | `ApolloRecentlyRead.xm` |
| Recently Read Posts Limit: 1000 | `ReadPostMaxCount = 1000` | `0` | `Tweak.xm`, `ApolloRecentlyRead.xm` |
| Hide NSFW in Recently Read: off | `FilterNSFWRecentlyRead = NO` | false fallback | `ApolloRecentlyRead.xm` |
| Text Post Thumbnails: on | `FeedTextPostThumbnails = YES` | `YES` | `ApolloFeedTextPostThumbnails.xm` |
| Block Announcements: on | `DisableApollonouncements = YES` | `YES` | announcement hooks in `Tweak.xm` |
| Collapse Pinned Comments: off | `CollapsePinnedComments = NO` | false fallback | `ApolloCommentsCollapse.xm` |
| Follow New Live Comments: on | `LiveCommentsFollow = YES` | `YES` | `ApolloLiveCommentsFollow.xm` |
| Deleted Comments submenu | all deleted-comment keys untouched | all safe modes off | `ApolloDeletedCommentsData.m`, `ApolloDeletedCommentsUI.xm` |
| Swipe Through Feed Galleries: on | `FeedGalleryCarousel = YES` | `YES` | `ApolloFeedGalleryCarousel.xm` |
| Swipe Up for Comments: on | `SwipeUpForComments = YES` | `YES` | `ApolloSwipeUpComments.xm` |
| GIF fallback: MP4 | `PreferredGIFFallbackFormat = 1` | `1` | `ApolloMedia.xm` |
| Unmute Videos in Comments: Default | `UnmuteCommentsVideos = 0` | `0` | `ApolloVideoUnmute.xm` |
| Hold for Video Speed: 2x | `VideoHoldSpeedEnabled = YES`; `VideoHoldSpeed = 2.0` | `YES` / `2.0` | `ApolloVideoHoldSpeed.xm` |
| Inline Media: on, 100%, Wi-Fi autoplay | `EnableInlineImages = YES`; `InlineMediaSizePercent = 100`; `AutoplayInlineGIFs = 2` | `YES` / `100` / legacy default | `ApolloInlineImages.xm`, `ApolloMediaAutoplay.m` |
| Media Upload Host: Image Chest | `ImageUploadProvider = 2` | Imgur (`0`) | `ApolloImageUploadHost.xm`, `ApolloImgChestUpload.m` |
| Comment Link Host: Image Chest | `CommentLinkHost = 2` | Off (`0`) | `ApolloMarkdownToolbarGif.xm`, `ApolloImageUploadHost.xm` |
| Proxy Imgur via DuckDuckGo: off | `ProxyImgurDDG = NO` | false fallback | Imgur request hooks in `Tweak.xm` |
| Subreddit List Enhancements: on | `SubredditListEnhancements = YES` | `YES` | `ApolloSubredditIndexPolish.xm` |
| Modern Subreddit Dividers: on | `ModernSubredditDividers = YES` | `YES` | `ApolloSubredditIndexPolish.xm` |
| Hide feed / multireddit descriptions: off | `HideSubredditListDescriptions = NO`; `HideMultiredditDescriptions = NO` | false fallback | `ApolloSubredditIndexPolish.xm`, `ApolloMultiredditEdit.xm` |
| Subreddit Layout: Native Apollo | `ShowSubredditHeaders = NO` | `NO` | `ApolloSubredditHeaders.xm` |
| Trending Subreddits Limit: 5 | `TrendingSubredditsLimit = "5"` | `"5"` | subreddit source logic in `Tweak.xm` |
| Trending and Random sources: preserve | `TrendingSubredditsSource`, `RandomSubredditsSource`, untouched | source defaults | subreddit source logic in `Tweak.xm` |
| Show RandNSFW in Search: off | `ShowRandNsfwButton = NO` | `NO` | `ApolloSearchTabFixes.xm` |
| RandNSFW source: preserve | `RandNsfwSubredditsSource`, untouched | `""` | subreddit source logic in `Tweak.xm` |

The migration deliberately leaves Redirect URI, User Agent, Info Row settings,
all cloud-AI credentials, LibreTranslate values, deleted-comment retrieval,
tag overrides, and unrelated Apollo preferences unchanged.
