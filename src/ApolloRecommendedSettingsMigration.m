#import "ApolloRecommendedSettingsMigration.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSString *const ApolloRecommendedSettingsMigrationVersionKey = @"BonemanRecommendedSettingsMigrationVersion";
NSInteger const ApolloRecommendedSettingsMigrationVersion = 3;

void ApolloApplyRecommendedSettingsMigration(NSUserDefaults *defaults) {
    if (!defaults) return;
    if ([defaults integerForKey:ApolloRecommendedSettingsMigrationVersionKey] >=
        ApolloRecommendedSettingsMigrationVersion) {
        return;
    }

    // Imgur remains intentionally unset. Reddit credentials, per-account OAuth
    // overrides, Redirect URI, User Agent, GIPHY, Image Chest, and every
    // Keychain item remain untouched.
    [defaults removeObjectForKey:UDKeyImgurClientId];

    NSDictionary<NSString *, id> *requestedValues = @{
        // Accounts and API-key-free authentication.
        UDKeyWebJSONEnabled: @YES,
        UDKeyUseCustomOAuthSignIn: @YES,
        UDKeyUseModernRedditChat: @YES,
        UDKeyUseModernRedditModmail: @NO,
        // Prevent the older API-key-free mailbox compatibility migration from
        // turning Moderator Mail back on after this explicit choice.
        UDKeyModernMailboxChoiceMigrated: @YES,

        // Tag filters. Mode and per-subreddit overrides remain untouched.
        UDKeyTagFilterEnabled: @YES,
        UDKeyTagFilterNSFW: @NO,
        UDKeyTagFilterSpoiler: @YES,

        // Translation. Empty means the device-default target language.
        UDKeyEnableBulkTranslation: @YES,
        UDKeyTranslationTargetLanguage: @"",
        UDKeyTranslationProvider: @"apple",
        UDKeyTranslationProviderUserSelected: @YES,
        UDKeyAppleTranslateSheet: @YES,

        // Picture in Picture.
        UDKeyPictureInPictureEnabled: @YES,
        UDKeyPictureInPictureActivation: @(ApolloPiPActivationModeUnmutedOnly),
        UDKeyPictureInPictureStartPosition: @(ApolloPiPStartPositionTopRight),
        UDKeyPictureInPictureNative: @YES,
        UDKeyPictureInPictureLoop: @YES,
        UDKeyPictureInPictureStartHidden: @NO,
        UDKeyPictureInPictureSkipButtons: @YES,
        UDKeyPictureInPictureProgressBar: @YES,

        // Apollo AI. No cloud-provider credentials are touched.
        UDKeyEnableAISummaries: @YES,
        UDKeyEnableAIPostSummaries: @YES,
        UDKeyEnableAICommentSummaries: @YES,
        UDKeyAIPostWordThreshold: @150,
        UDKeyAIPostSummaryDetail: @(ApolloAISummaryDetailBalanced),
        UDKeyAICommentSummaryDetail: @(ApolloAISummaryDetailBalanced),
        UDKeyEnableTapToSummarize: @NO,
        UDKeyEnableAIAutoExpandSummaries: @NO,
        UDKeyAISummaryProvider: @"apple",

        // Rich link previews and standard tab bar.
        UDKeyLinkPreviewBodyMode: @(ApolloLinkPreviewModeFull),
        UDKeyLinkPreviewCommentsMode: @(ApolloLinkPreviewModeCompact),
        UDKeyLinkPreviewCardColorHex: @"",
        UDKeyHideTabBarTitles: @NO,

        // Posts, feeds, and comments. Info-row and deleted-comment settings are
        // deliberately absent.
        UDKeyShowRecentlyReadThumbnails: @YES,
        UDKeyReadPostMaxCount: @1000,
        UDKeyFilterNSFWRecentlyRead: @NO,
        UDKeyFeedTextPostThumbnails: @YES,
        UDKeyBlockAnnouncements: @YES,
        UDKeyCollapsePinnedComments: @NO,
        UDKeyLiveCommentsFollow: @YES,

        // Media.
        UDKeyFeedGalleryCarousel: @YES,
        UDKeySwipeUpForComments: @YES,
        UDKeyPreferredGIFFallbackFormat: @1,
        UDKeyUnmuteCommentsVideos: @0,
        UDKeyVideoHoldSpeedEnabled: @YES,
        UDKeyVideoHoldSpeed: @2.0,
        UDKeyEnableInlineImages: @YES,
        UDKeyInlineMediaSizePercent: @100,
        UDKeyAutoplayInlineGIFs: @(ApolloAutoplayInlineGIFModeWiFiOnly),
        UDKeyImageUploadProvider: @(ImageUploadProviderImgChest),
        UDKeyCommentLinkHost: @(CommentLinkHostImgChest),
        UDKeyProxyImgurDDG: @NO,

        // Subreddits. Existing source strings and RandNSFW source stay intact.
        UDKeySubredditListEnhancements: @YES,
        UDKeyModernSubredditDividers: @YES,
        UDKeyHideSubredditListDescriptions: @NO,
        UDKeyHideMultiredditDescriptions: @NO,
        UDKeyShowSubredditHeaders: @NO,
        UDKeyTrendingSubredditsLimit: @"5",
        UDKeyShowRandNsfw: @NO,
    };

    [requestedValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        [defaults setObject:value forKey:key];
    }];

    // Written last: an interrupted migration is safely retried on next launch.
    [defaults setInteger:ApolloRecommendedSettingsMigrationVersion
                  forKey:ApolloRecommendedSettingsMigrationVersionKey];
}
