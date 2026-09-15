#import <Foundation/Foundation.h>

#import "ApolloRecommendedSettingsMigration.h"
#import "UserDefaultConstants.h"

static void AssertEqual(id actual, id expected, NSString *label) {
    if (actual == nil && expected == nil) return;
    if ((actual == nil) != (expected == nil) || ![actual isEqual:expected]) {
        NSLog(@"FAIL %@: actual=%@ expected=%@", label, actual, expected);
        abort();
    }
}

int main(void) {
    @autoreleasepool {
        NSString *suiteName = [@"ApolloRecommendedSettingsMigrationTests."
            stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [defaults removePersistentDomainForName:suiteName];

        NSDictionary *protectedValues = @{
            UDKeyRedditClientId: @"reddit-client-sentinel",
            UDKeyRedditClientSecret: @"reddit-secret-sentinel",
            UDKeyGiphyAPIKey: @"giphy-secret-sentinel",
            UDKeyImageChestAPIToken: @"image-chest-secret-sentinel",
            UDKeyRedirectURI: @"dystopia://response",
            UDKeyUserAgent: @"preserve-user-agent",
            UDKeyPerAccountCredentials: @{ @"account": @{ @"clientId": @"preserve" } },
            UDKeyLibreTranslateAPIKey: @"libre-secret-sentinel",
            UDKeyOpenRouterAPIKey: @"cloud-secret-sentinel",
            UDKeyShowDeletedComments: @NO,
            UDKeyTapToRevealDeletedComments: @YES,
            UDKeyPassiveDeletedComments: @NO,
            UDKeyTagFilterSubredditOverrides: @{ @"example": @{ @"spoiler": @NO } },
            UDKeyTrendingSubredditsSource: @"preserve-trending-source",
            UDKeyRandomSubredditsSource: @"preserve-random-source",
            UDKeyRandNsfwSubredditsSource: @"preserve-randnsfw-source",
            @"UnrelatedApolloPreference": @"preserve-unrelated",
        };
        [defaults setPersistentDomain:protectedValues forName:suiteName];
        [defaults setObject:@"old-imgur" forKey:UDKeyImgurClientId];

        ApolloApplyRecommendedSettingsMigration(defaults);

        NSDictionary *expected = @{
            UDKeyWebJSONEnabled: @YES,
            UDKeyUseCustomOAuthSignIn: @YES,
            UDKeyUseModernRedditChat: @YES,
            UDKeyUseModernRedditModmail: @NO,
            UDKeyModernMailboxChoiceMigrated: @YES,
            UDKeyTagFilterEnabled: @YES,
            UDKeyTagFilterNSFW: @NO,
            UDKeyTagFilterSpoiler: @YES,
            UDKeyEnableBulkTranslation: @YES,
            UDKeyTranslationTargetLanguage: @"",
            UDKeyTranslationProvider: @"apple",
            UDKeyTranslationProviderUserSelected: @YES,
            UDKeyAppleTranslateSheet: @YES,
            UDKeyPictureInPictureEnabled: @YES,
            UDKeyPictureInPictureActivation: @1,
            UDKeyPictureInPictureStartPosition: @1,
            UDKeyPictureInPictureNative: @YES,
            UDKeyPictureInPictureLoop: @YES,
            UDKeyPictureInPictureStartHidden: @NO,
            UDKeyPictureInPictureSkipButtons: @YES,
            UDKeyPictureInPictureProgressBar: @YES,
            UDKeyEnableAISummaries: @YES,
            UDKeyEnableAIPostSummaries: @YES,
            UDKeyEnableAICommentSummaries: @YES,
            UDKeyAIPostWordThreshold: @150,
            UDKeyAIPostSummaryDetail: @1,
            UDKeyAICommentSummaryDetail: @1,
            UDKeyEnableTapToSummarize: @NO,
            UDKeyEnableAIAutoExpandSummaries: @NO,
            UDKeyAISummaryProvider: @"apple",
            UDKeyLinkPreviewBodyMode: @2,
            UDKeyLinkPreviewCommentsMode: @1,
            UDKeyLinkPreviewCardColorHex: @"",
            UDKeyHideTabBarTitles: @NO,
            UDKeyShowRecentlyReadThumbnails: @YES,
            UDKeyReadPostMaxCount: @1000,
            UDKeyFilterNSFWRecentlyRead: @NO,
            UDKeyFeedTextPostThumbnails: @YES,
            UDKeyBlockAnnouncements: @YES,
            UDKeyCollapsePinnedComments: @NO,
            UDKeyLiveCommentsFollow: @YES,
            UDKeyFeedGalleryCarousel: @YES,
            UDKeySwipeUpForComments: @YES,
            UDKeyPreferredGIFFallbackFormat: @1,
            UDKeyUnmuteCommentsVideos: @0,
            UDKeyVideoHoldSpeedEnabled: @YES,
            UDKeyVideoHoldSpeed: @2.0,
            UDKeyEnableInlineImages: @YES,
            UDKeyInlineMediaSizePercent: @100,
            UDKeyAutoplayInlineGIFs: @2,
            UDKeyImageUploadProvider: @2,
            UDKeyCommentLinkHost: @2,
            UDKeyProxyImgurDDG: @NO,
            UDKeySubredditListEnhancements: @YES,
            UDKeyModernSubredditDividers: @YES,
            UDKeyHideSubredditListDescriptions: @NO,
            UDKeyHideMultiredditDescriptions: @NO,
            UDKeyShowSubredditHeaders: @NO,
            UDKeyTrendingSubredditsLimit: @"5",
            UDKeyShowRandNsfw: @NO,
        };
        [expected enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            AssertEqual([defaults objectForKey:key], value, key);
        }];

        AssertEqual([defaults objectForKey:UDKeyImgurClientId], nil, @"Imgur client id removed");
        [protectedValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            AssertEqual([defaults objectForKey:key], value, [@"protected " stringByAppendingString:key]);
        }];

        // A subsequent launch must not overwrite an intentional user change.
        [defaults setBool:NO forKey:UDKeyPictureInPictureEnabled];
        ApolloApplyRecommendedSettingsMigration(defaults);
        AssertEqual([defaults objectForKey:UDKeyPictureInPictureEnabled], @NO, @"one-time idempotence");
        AssertEqual([defaults objectForKey:ApolloRecommendedSettingsMigrationVersionKey], @3,
                    @"migration version");

        [defaults removePersistentDomainForName:suiteName];
        NSLog(@"PASS recommended settings migration");
    }
    return 0;
}
