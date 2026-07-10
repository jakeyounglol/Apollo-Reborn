#import "ApolloHiddenContentData.h"
#import "ApolloCommon.h"
#import "ApolloImageUploadHost.h"
#import "ApolloState.h"

// Soft cap on total items pulled per source so a prolific account can't turn
// one tap into thousands of requests; truncation is logged, not silent.
static NSUInteger const kApolloHiddenContentPageSize = 100;
static NSUInteger const kApolloHiddenContentLiveListingCap = 1000;   // 10 pages
static NSUInteger const kApolloHiddenContentArcticCap = 500;         // 5 pages
static NSUInteger const kApolloHiddenContentInfoBatchSize = 100;     // Reddit /api/info limit
static NSTimeInterval const kApolloHiddenContentRequestTimeout = 15.0;
static NSTimeInterval const kApolloHiddenContentCacheTTL = 3600.0;

@implementation ApolloHiddenContentItem
@end

#pragma mark - Result cache

static NSMutableDictionary<NSString *, NSArray<ApolloHiddenContentItem *> *> *sApolloHiddenContentCache;
static NSMutableDictionary<NSString *, NSDate *> *sApolloHiddenContentCacheTimestamps;

static NSObject *ApolloHiddenContentCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSArray<ApolloHiddenContentItem *> *ApolloHiddenContentCachedResult(NSString *cacheKey) {
    @synchronized (ApolloHiddenContentCacheLock()) {
        NSDate *cachedAt = sApolloHiddenContentCacheTimestamps[cacheKey];
        if (!cachedAt || [[NSDate date] timeIntervalSinceDate:cachedAt] > kApolloHiddenContentCacheTTL) {
            return nil;
        }
        return sApolloHiddenContentCache[cacheKey];
    }
}

static void ApolloHiddenContentStoreResult(NSString *cacheKey, NSArray<ApolloHiddenContentItem *> *results) {
    @synchronized (ApolloHiddenContentCacheLock()) {
        if (!sApolloHiddenContentCache) {
            sApolloHiddenContentCache = [NSMutableDictionary dictionary];
            sApolloHiddenContentCacheTimestamps = [NSMutableDictionary dictionary];
        }
        sApolloHiddenContentCache[cacheKey] = results;
        sApolloHiddenContentCacheTimestamps[cacheKey] = [NSDate date];
    }
}

#pragma mark - Shared request helpers

static NSString *ApolloHiddenContentUserAgent(void) {
    return sUserAgent.length > 0 ? sUserAgent : @"ApolloReborn/1.0";
}

static NSMutableURLRequest *ApolloHiddenContentAuthedRequest(NSURL *url, NSString *bearerToken) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kApolloHiddenContentRequestTimeout;
    [request setValue:[@"Bearer " stringByAppendingString:bearerToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:ApolloHiddenContentUserAgent() forHTTPHeaderField:@"User-Agent"];
    return request;
}

static NSDate *ApolloHiddenContentDateFromCreatedUTC(id createdUTC) {
    double seconds = 0.0;
    if ([createdUTC isKindOfClass:[NSNumber class]]) {
        seconds = [(NSNumber *)createdUTC doubleValue];
    } else if ([createdUTC isKindOfClass:[NSString class]]) {
        seconds = [(NSString *)createdUTC doubleValue];
    }
    return seconds > 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}

static NSString *ApolloHiddenContentLiveListingKind(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"submitted" : @"comments";
}

static NSString *ApolloHiddenContentFullNamePrefix(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"t3_" : @"t1_";
}

#pragma mark - Live listing (paginated, authenticated)

// Pages through /user/<username>/<listingKind>.json into `fullNames`. A page-1
// error is fatal (an empty live set would misclassify everything as hidden/
// deleted); a later-page error just marks the result incomplete and stops.
static void ApolloHiddenContentFetchLiveListingPage(NSString *username, NSString *listingKind, NSString *bearerToken,
                                                     NSString * _Nullable after, NSMutableSet<NSString *> *fullNames,
                                                     void (^completion)(BOOL fatalError, BOOL incomplete)) {
    if (fullNames.count >= kApolloHiddenContentLiveListingCap) {
        ApolloLog(@"[HiddenContent] Live %@ listing capped at %lu items for u/%@", listingKind, (unsigned long)kApolloHiddenContentLiveListingCap, username);
        completion(NO, NO);
        return;
    }

    BOOL isFirstPage = (after.length == 0);

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"https://oauth.reddit.com/user/%@/%@.json", username, listingKind]];
    NSMutableArray<NSURLQueryItem *> *queryItems = [@[
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)kApolloHiddenContentPageSize]],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
    ] mutableCopy];
    if (after.length > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"after" value:after]];
    }
    components.queryItems = queryItems;

    NSURLRequest *request = ApolloHiddenContentAuthedRequest(components.URL, bearerToken);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300))) {
            ApolloLog(@"[HiddenContent] Live %@ listing fetch stopped early on page %@ (status=%ld error=%@)",
                      listingKind, isFirstPage ? @"1" : @"N", (long)http.statusCode, error.localizedDescription ?: @"none");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(isFirstPage, YES); });
            return;
        }

        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childData = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
            NSString *name = [childData[@"name"] isKindOfClass:[NSString class]] ? childData[@"name"] : nil;
            if (name.length > 0) [fullNames addObject:name];
        }

        NSString *nextAfter = [listingData[@"after"] isKindOfClass:[NSString class]] ? listingData[@"after"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (nextAfter.length > 0 && children.count > 0) {
                ApolloHiddenContentFetchLiveListingPage(username, listingKind, bearerToken, nextAfter, fullNames, completion);
            } else {
                completion(NO, NO);
            }
        });
    }];
    [task resume];
}

static void ApolloHiddenContentFetchLiveFullNames(NSString *username, ApolloHiddenContentKind kind, NSString *bearerToken,
                                                   void (^completion)(NSSet<NSString *> *fullNames, BOOL fatalError, BOOL incomplete)) {
    NSMutableSet<NSString *> *fullNames = [NSMutableSet set];
    ApolloHiddenContentFetchLiveListingPage(username, ApolloHiddenContentLiveListingKind(kind), bearerToken, nil, fullNames, ^(BOOL fatalError, BOOL incomplete) {
        completion(fullNames, fatalError, incomplete);
    });
}

#pragma mark - Arctic Shift author search (paginated, unauthenticated)

static NSString *ApolloHiddenContentArcticSearchPath(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"/api/posts/search" : @"/api/comments/search";
}

// Pages through Arctic Shift's author-search endpoint using `before` (epoch
// seconds of the oldest item seen so far) as the pagination cursor, newest-first.
static void ApolloHiddenContentFetchArcticPage(NSString *username, ApolloHiddenContentKind kind, NSNumber * _Nullable before,
                                                NSMutableArray<NSDictionary *> *items, void (^completion)(void)) {
    if (items.count >= kApolloHiddenContentArcticCap) {
        ApolloLog(@"[HiddenContent] Arctic %@ search capped at %lu items for u/%@", ApolloHiddenContentArcticSearchPath(kind), (unsigned long)kApolloHiddenContentArcticCap, username);
        completion();
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [@"https://arctic-shift.photon-reddit.com" stringByAppendingString:ApolloHiddenContentArcticSearchPath(kind)]];
    NSMutableArray<NSURLQueryItem *> *queryItems = [@[
        [NSURLQueryItem queryItemWithName:@"author" value:username],
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)kApolloHiddenContentPageSize]],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"desc"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ] mutableCopy];
    if (before) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"before" value:before.stringValue]];
    }
    components.queryItems = queryItems;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = kApolloHiddenContentRequestTimeout;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300))) {
            ApolloLog(@"[HiddenContent] Arctic %@ search stopped early (status=%ld error=%@)", ApolloHiddenContentArcticSearchPath(kind), (long)http.statusCode, error.localizedDescription ?: @"none");
            dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }

        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *page = [root[@"data"] isKindOfClass:[NSArray class]] ? root[@"data"] : nil;
        NSNumber *oldestSeen = before;
        for (NSDictionary *rawItem in page) {
            if (![rawItem isKindOfClass:[NSDictionary class]]) continue;
            [items addObject:rawItem];
            id createdUTC = rawItem[@"created_utc"];
            NSNumber *createdNumber = [createdUTC isKindOfClass:[NSNumber class]] ? createdUTC : nil;
            if (createdNumber && (!oldestSeen || createdNumber.doubleValue < oldestSeen.doubleValue)) {
                oldestSeen = createdNumber;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (page.count >= kApolloHiddenContentPageSize && oldestSeen) {
                ApolloHiddenContentFetchArcticPage(username, kind, oldestSeen, items, completion);
            } else {
                completion();
            }
        });
    }];
    [task resume];
}

static void ApolloHiddenContentFetchArcticItems(NSString *username, ApolloHiddenContentKind kind,
                                                 void (^completion)(NSArray<NSDictionary *> *items)) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    ApolloHiddenContentFetchArcticPage(username, kind, nil, items, ^{
        completion(items);
    });
}

#pragma mark - Classification (batched /api/info)

// Asks /api/info which candidates still resolve live; the rest are deleted --
// except a chunk whose request itself failed, reported in `unresolvableFullNames`
// so the caller can drop those rather than guessing hidden/deleted.
static void ApolloHiddenContentClassify(NSArray<NSString *> *candidateFullNames, NSString *bearerToken,
                                         void (^completion)(NSSet<NSString *> *stillLiveFullNames, NSSet<NSString *> *unresolvableFullNames)) {
    if (candidateFullNames.count == 0) {
        completion([NSSet set], [NSSet set]);
        return;
    }

    NSMutableArray<NSArray<NSString *> *> *chunks = [NSMutableArray array];
    for (NSUInteger i = 0; i < candidateFullNames.count; i += kApolloHiddenContentInfoBatchSize) {
        NSUInteger length = MIN(kApolloHiddenContentInfoBatchSize, candidateFullNames.count - i);
        [chunks addObject:[candidateFullNames subarrayWithRange:NSMakeRange(i, length)]];
    }

    NSMutableSet<NSString *> *stillLive = [NSMutableSet set];
    NSMutableSet<NSString *> *unresolvable = [NSMutableSet set];
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];

    for (NSArray<NSString *> *chunk in chunks) {
        dispatch_group_enter(group);
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://oauth.reddit.com/api/info.json"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"id" value:[chunk componentsJoinedByString:@","]],
            [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
        ];
        NSURLRequest *request = ApolloHiddenContentAuthedRequest(components.URL, bearerToken);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            BOOL failed = error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300));
            if (failed) {
                ApolloLog(@"[HiddenContent] /api/info chunk of %lu id(s) failed (status=%ld error=%@) -- excluding those item(s) from results this pass",
                          (unsigned long)chunk.count, (long)(http ? http.statusCode : 0), error.localizedDescription ?: @"none");
                @synchronized (lock) {
                    [unresolvable addObjectsFromArray:chunk];
                }
            } else {
                NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSDictionary *listingData = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
                NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
                @synchronized (lock) {
                    for (id child in children) {
                        NSDictionary *childData = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
                        NSString *name = [childData[@"name"] isKindOfClass:[NSString class]] ? childData[@"name"] : nil;
                        if (name.length > 0) [stillLive addObject:name];
                    }
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(stillLive, unresolvable);
    });
}

#pragma mark - Item construction

static ApolloHiddenContentItem *ApolloHiddenContentItemFromArcticDict(NSDictionary *raw, ApolloHiddenContentKind kind, ApolloHiddenContentReason reason) {
    ApolloHiddenContentItem *item = [ApolloHiddenContentItem new];
    NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
    NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : nil;
    if (name.length == 0 && rawID.length > 0) {
        name = [ApolloHiddenContentFullNamePrefix(kind) stringByAppendingString:rawID];
    }
    if (name.length == 0) return nil;

    item.fullName = name;
    item.kind = kind;
    item.reason = reason;
    item.title = [raw[@"title"] isKindOfClass:[NSString class]] ? raw[@"title"] : nil;
    item.body = [raw[(kind == ApolloHiddenContentKindPost ? @"selftext" : @"body")] isKindOfClass:[NSString class]]
        ? raw[(kind == ApolloHiddenContentKindPost ? @"selftext" : @"body")] : nil;
    item.subreddit = [raw[@"subreddit"] isKindOfClass:[NSString class]] ? raw[@"subreddit"] : nil;
    NSString *permalink = [raw[@"permalink"] isKindOfClass:[NSString class]] ? raw[@"permalink"] : nil;
    item.permalink = permalink.length > 0 ? permalink : nil;
    item.createdDate = ApolloHiddenContentDateFromCreatedUTC(raw[@"created_utc"]);
    return item;
}

#pragma mark - Public entry point

void ApolloHiddenContentFetch(NSString *username, ApolloHiddenContentKind kind, BOOL forceRefresh, ApolloHiddenContentFetchCompletion completion) {
    if (!completion) return;
    if (username.length == 0) {
        completion(nil, @"No username to look up.");
        return;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld", username.lowercaseString, (long)kind];
    if (!forceRefresh) {
        NSArray<ApolloHiddenContentItem *> *cached = ApolloHiddenContentCachedResult(cacheKey);
        if (cached) {
            ApolloLog(@"[HiddenContent] u/%@ (%@): serving %lu cached result(s)", username, ApolloHiddenContentArcticSearchPath(kind), (unsigned long)cached.count);
            completion(cached, nil);
            return;
        }
    }

    NSString *bearerToken = ApolloLatestRedditBearerToken();
    if (bearerToken.length == 0) {
        completion(nil, @"No active Reddit session detected yet. Browse a screen that talks to Reddit (e.g. your feed) and try again.");
        return;
    }

    ApolloHiddenContentFetchLiveFullNames(username, kind, bearerToken, ^(NSSet<NSString *> *liveFullNames, BOOL fatalError, BOOL liveIncomplete) {
        if (fatalError) {
            completion(nil, @"Couldn't verify this account's current posts/comments (network or session error). Try again.");
            return;
        }

        // Only caches a complete result -- a failed/partial pass would otherwise
        // stick around wrong for kApolloHiddenContentCacheTTL.
        void (^finish)(NSArray<ApolloHiddenContentItem *> *, BOOL) = ^(NSArray<ApolloHiddenContentItem *> *results, BOOL complete) {
            if (complete) ApolloHiddenContentStoreResult(cacheKey, results);
            completion(results, nil);
        };

        ApolloHiddenContentFetchArcticItems(username, kind, ^(NSArray<NSDictionary *> *arcticItems) {
            if (arcticItems.count == 0) {
                finish(@[], !liveIncomplete);
                return;
            }

            // Candidates: archived items missing from the live listing, deduped
            // by fullname (Arctic Shift's cursor can repeat items sharing a
            // created_utc second across pages).
            NSString *prefix = ApolloHiddenContentFullNamePrefix(kind);
            NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
            NSMutableArray<NSString *> *candidateFullNames = [NSMutableArray array];
            NSMutableSet<NSString *> *seenFullNames = [NSMutableSet set];

            for (NSDictionary *raw in arcticItems) {
                NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
                NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : (rawID.length > 0 ? [prefix stringByAppendingString:rawID] : nil);
                if (name.length == 0 || [liveFullNames containsObject:name] || [seenFullNames containsObject:name]) continue;
                [seenFullNames addObject:name];
                [candidates addObject:raw];
                [candidateFullNames addObject:name];
            }

            if (candidateFullNames.count == 0) {
                finish(@[], !liveIncomplete);
                return;
            }

            ApolloHiddenContentClassify(candidateFullNames, bearerToken, ^(NSSet<NSString *> *stillLiveFullNames, NSSet<NSString *> *unresolvableFullNames) {
                NSMutableArray<ApolloHiddenContentItem *> *results = [NSMutableArray array];
                for (NSDictionary *raw in candidates) {
                    NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
                    NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : (rawID.length > 0 ? [prefix stringByAppendingString:rawID] : nil);
                    if ([unresolvableFullNames containsObject:name]) continue;
                    ApolloHiddenContentReason reason = [stillLiveFullNames containsObject:name] ? ApolloHiddenContentReasonHidden : ApolloHiddenContentReasonDeleted;
                    ApolloHiddenContentItem *item = ApolloHiddenContentItemFromArcticDict(raw, kind, reason);
                    if (item) [results addObject:item];
                }

                [results sortUsingComparator:^NSComparisonResult(ApolloHiddenContentItem *a, ApolloHiddenContentItem *b) {
                    NSDate *da = a.createdDate ?: [NSDate distantPast];
                    NSDate *db = b.createdDate ?: [NSDate distantPast];
                    return [db compare:da];
                }];

                ApolloLog(@"[HiddenContent] u/%@ (%@): %lu candidates (%lu hidden, %lu deleted, %lu unresolvable)", username, ApolloHiddenContentArcticSearchPath(kind),
                          (unsigned long)results.count,
                          (unsigned long)[results filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"reason == %d", ApolloHiddenContentReasonHidden]].count,
                          (unsigned long)[results filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"reason == %d", ApolloHiddenContentReasonDeleted]].count,
                          (unsigned long)unresolvableFullNames.count);

                finish(results, !liveIncomplete && unresolvableFullNames.count == 0);
            });
        });
    });
}
