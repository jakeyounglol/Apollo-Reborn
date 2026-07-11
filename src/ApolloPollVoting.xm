#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloThemeRuntime.h"
#import "UIWindow+Apollo.h"
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Minimal declarations avoid importing the generated class-dump header graph,
// which redeclares Foundation protocols under newer SDKs.
@class RDKPoll;
@interface RDKLink : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, readonly) NSString *fullName;
@property (nonatomic, strong) RDKPoll *poll;
@end
@interface RDKPollOption : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) long long voteCount;
@end
@interface RDKPoll : NSObject
@property (nonatomic, strong) NSArray<RDKPollOption *> *options;
@property (nonatomic) long long totalVoteCount;
@property (nonatomic, copy) NSString *userSelectionIdentifier;
- (BOOL)hasPollEnded;
@end
@interface NSObject (ApolloPollVotingRuntime)
- (void)modelObjectUpdatedNotificationReceived:(id)notification;
// Texture's UIView (AsyncDisplayKit) category: _ASDisplayView -> its node.
- (id)asyncdisplaykit_node;
- (UIView *)view;
- (void)didLoad;
- (void)setNeedsLayout;
@end

// Reddit's website uses this named same-origin mutation. Keep the operation in
// one place so a server-side rename degrades to Apollo's existing web flow.
static NSString *const kApolloPollVoteOperation = @"UpdatePostPollVoteState";
// v2 contained optimistic votes which could survive rejected mutations.  v3
// contains confirmed votes only and intentionally starts with a clean store.
static NSString *const kApolloPollLocalVotesKey = @"ApolloPollLocalVotes.v3";

static NSMutableDictionary *ApolloPollLocalVotes(void) {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kApolloPollLocalVotesKey];
    return saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static NSString *ApolloPollCacheKey(NSString *username, NSString *postID) {
    if (username.length == 0 || postID.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", username.lowercaseString, postID.lowercaseString];
}

static NSString *ApolloPollCanonicalBaseID(RDKLink *link) {
    NSString *baseID = [[link.identifier ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([baseID hasPrefix:@"t3_"]) baseID = [baseID substringFromIndex:3];
    if (baseID.length == 0) return nil;
    NSRegularExpression *validID = [NSRegularExpression
        regularExpressionWithPattern:@"^[a-z0-9]+$" options:0 error:nil];
    return [validID firstMatchInString:baseID options:0
                                  range:NSMakeRange(0, baseID.length)] ? baseID : nil;
}

static void ApolloPollRememberVote(NSString *username, NSString *postID, NSString *optionID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    if (!key || optionID.length == 0) return;
    NSMutableDictionary *votes = ApolloPollLocalVotes();
    NSTimeInterval cutoff = [NSDate date].timeIntervalSince1970 - 90.0 * 24.0 * 60.0 * 60.0;
    for (NSString *savedKey in [votes.allKeys copy]) {
        NSDictionary *entry = [votes[savedKey] isKindOfClass:NSDictionary.class] ? votes[savedKey] : nil;
        if (!entry || [entry[@"savedAt"] doubleValue] < cutoff) [votes removeObjectForKey:savedKey];
    }
    if (votes.count >= 500) {
        NSArray *oldest = [votes keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"savedAt"] compare:b[@"savedAt"]];
        }];
        NSUInteger removeCount = votes.count - 499;
        for (NSUInteger i = 0; i < removeCount; i++) [votes removeObjectForKey:oldest[i]];
    }
    votes[key] = @{ @"option": optionID, @"savedAt": @([NSDate date].timeIntervalSince1970) };
    [[NSUserDefaults standardUserDefaults] setObject:votes forKey:kApolloPollLocalVotesKey];
}

static void ApolloPollForgetVote(NSString *username, NSString *postID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    if (!key) return;
    NSMutableDictionary *votes = ApolloPollLocalVotes();
    [votes removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:votes forKey:kApolloPollLocalVotesKey];
}

static NSString *ApolloPollRememberedVote(NSString *username, NSString *postID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    NSDictionary *entry = key ? ApolloPollLocalVotes()[key] : nil;
    NSString *option = [entry isKindOfClass:NSDictionary.class] ? entry[@"option"] : nil;
    return [option isKindOfClass:NSString.class] ? option : nil;
}

@interface ApolloPollVoteRequest : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *postID;
@property (nonatomic, copy) NSString *optionID;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *csrfToken;
@property (nonatomic, copy) void (^completion)(BOOL success, NSString *message);
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL mutationSent;
@end

static NSMutableSet<ApolloPollVoteRequest *> *sApolloPollVoteRequests;
static NSMutableSet<NSString *> *sApolloPollVotesInFlight;
static const void *kApolloPollLastTouchPointKey = &kApolloPollLastTouchPointKey;
static const void *kApolloPollHighlightedViewKey = &kApolloPollHighlightedViewKey;

static NSDictionary<NSString *, NSString *> *ApolloPollCookiePairs(NSString *header) {
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    for (NSString *component in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [component rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[component substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [component substringFromIndex:equals.location + 1];
        if (name.length > 0) pairs[name] = value;
    }
    return pairs;
}

@implementation ApolloPollVoteRequest

- (void)startWithSession:(ApolloWebSessionEntry *)session {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.finished) [self finish:NO message:@"Reddit took too long to respond. The vote may still have been recorded; check the poll before retrying."];
    });
    NSDictionary *pairs = ApolloPollCookiePairs(session.cookieHeader);
    self.csrfToken = pairs[@"csrf_token"] ?: @"";
    if (self.csrfToken.length == 0) {
        ApolloLog(@"[PollVoting] vote request failed stage=csrf");
        [self finish:NO message:@"The Reddit session has no CSRF token."];
        return;
    }

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Never consult the shared jar: it may belong to another Apollo account.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;

    dispatch_group_t group = dispatch_group_create();
    [pairs enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        NSDictionary *properties = @{ NSHTTPCookieName: name, NSHTTPCookieValue: value,
                                      NSHTTPCookieDomain: @".reddit.com", NSHTTPCookiePath: @"/",
                                      NSHTTPCookieSecure: @"TRUE" };
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        if (!cookie) return;
        dispatch_group_enter(group);
        [configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/"]]];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.mutationSent) return;
    self.mutationSent = YES;
    NSDictionary *input = @{ @"postId": self.postID, @"optionId": self.optionID };
    NSDictionary *body = @{ @"operation": kApolloPollVoteOperation,
                            @"variables": @{ @"input": input },
                            @"csrf_token": self.csrfToken };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"try { const r = await fetch('/svc/shreddit/graphql', {method:'POST', credentials:'include', headers:{'Content-Type':'application/json','X-Csrf-Token':%@}, body:%@}); const t=await r.text(); return JSON.stringify({status:r.status,body:t}); } catch(e) { return JSON.stringify({status:0,body:String(e)}); }",
        [self JSONString:self.csrfToken], [self JSONString:json]];
    [webView callAsyncJavaScript:script arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld
               completionHandler:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:NSString.class]) {
            [self finish:NO message:error.localizedDescription ?: @"Reddit did not return a response."];
            return;
        }
        NSData *wrapperData = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *wrapperObject = [NSJSONSerialization JSONObjectWithData:wrapperData options:0 error:nil];
        NSDictionary *wrapper = [wrapperObject isKindOfClass:NSDictionary.class] ? wrapperObject : nil;
        NSInteger status = [wrapper[@"status"] integerValue];
        NSString *bodyString = [wrapper[@"body"] isKindOfClass:NSString.class] ? wrapper[@"body"] : nil;
        NSData *responseData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
        id responseObject = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
        NSDictionary *response = [responseObject isKindOfClass:NSDictionary.class] ? responseObject : nil;
        id vote = [response valueForKeyPath:@"data.updatePostPollVoteState"];
        // Reddit currently returns { ok: true, errors: null }; older variants
        // returned a bare Boolean.  Invalid/no-op votes can still be HTTP 200,
        // so require an explicit true result rather than mere non-null data.
        BOOL mutationAccepted = NO;
        if ([vote isKindOfClass:NSNumber.class]) {
            mutationAccepted = [vote boolValue];
        } else if ([vote isKindOfClass:NSDictionary.class]) {
            id payloadErrors = vote[@"errors"];
            BOOL hasPayloadErrors = payloadErrors && payloadErrors != NSNull.null &&
                (![payloadErrors respondsToSelector:@selector(count)] || [payloadErrors count] > 0);
            mutationAccepted = [vote[@"ok"] boolValue] && !hasPayloadErrors;
        }
        id topErrors = response[@"errors"];
        BOOL hasTopErrors = topErrors && topErrors != NSNull.null &&
            (![topErrors respondsToSelector:@selector(count)] || [topErrors count] > 0);
        BOOL ok = status >= 200 && status < 300 && mutationAccepted && !hasTopErrors;
        NSString *message = nil;
        if (!ok) {
            NSString *serverMessage = nil;
            if ([topErrors isKindOfClass:NSArray.class] && [topErrors count] > 0) {
                id first = [topErrors firstObject];
                if ([first isKindOfClass:NSDictionary.class] && [first[@"message"] isKindOfClass:NSString.class]) serverMessage = first[@"message"];
            }
            if (status == 429) message = @"Reddit is rate limiting votes. Wait a moment before trying again.";
            else if (status == 401 || status == 403) {
                ApolloWebSessionRemove(self.username);
                message = @"The Reddit web session expired. Sign in again and retry.";
            }
            else message = serverMessage ?: (status >= 200 && status < 300
                ? @"Reddit did not confirm the poll vote."
                : [NSString stringWithFormat:@"Reddit returned HTTP %ld.", (long)status]);
            ApolloLog(@"[PollVoting] vote request failed stage=response status=%ld", (long)status);
        }
        [self finish:ok message:message];
    }];
}

- (NSString *)JSONString:(NSString *)string {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[string ?: @""] options:0 error:nil];
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

- (void)finish:(BOOL)success message:(NSString *)message {
    if (self.finished) return;
    self.finished = YES;
    self.completion(success, message);
    self.webView.navigationDelegate = nil;
    self.webView = nil;
    [sApolloPollVoteRequests removeObject:self];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    ApolloLog(@"[PollVoting] vote request failed stage=navigation code=%ld", (long)error.code);
    [self finish:NO message:error.localizedDescription ?: @"Reddit could not be reached."];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[PollVoting] vote request failed stage=web-process");
    [self finish:NO message:@"Reddit's web session stopped unexpectedly."];
}
@end

static UIViewController *ApolloPollPresenter(void) {
    for (UIWindow *window in ApolloAllWindows()) if (window.isKeyWindow) return window.visibleViewController;
    return ApolloAllWindows().firstObject.visibleViewController;
}

static void ApolloPollShowError(UIViewController *presenter, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Vote"
        message:message ?: @"Reddit rejected the poll vote. You can still vote on reddit.com."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id ApolloPollObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIView *ApolloPollNodeView(id node) {
    return [node respondsToSelector:@selector(view)] ? [node view] : nil;
}

// The PollOptionNode whose row contains `point` (in the poll view's coordinate
// space). Option rows are direct subnodes of the PollNode stack, but recurse
// one container level in case a future Apollo build wraps them.
static RDKPollOption *ApolloPollOptionAtPoint(UIView *containerView, CGPoint point, NSUInteger depth) {
    Class optionClass = objc_getClass("_TtC6Apollo14PollOptionNode");
    for (UIView *row in containerView.subviews) {
        if (!CGRectContainsPoint(row.frame, point)) continue;
        id node = [row respondsToSelector:@selector(asyncdisplaykit_node)] ? [row asyncdisplaykit_node] : nil;
        if (node && [node isKindOfClass:optionClass]) {
            return ApolloPollObjectIvar(node, "option");
        }
        if (depth > 0) {
            RDKPollOption *nested = ApolloPollOptionAtPoint(row, [containerView convertPoint:point toView:row], depth - 1);
            if (nested) return nested;
        }
    }
    return nil;
}

static UIView *ApolloPollOptionViewAtPoint(UIView *pollView, CGPoint point) {
    UIView *hit = [pollView hitTest:point withEvent:nil];
    Class optionClass = objc_getClass("_TtC6Apollo14PollOptionNode");
    while (hit && hit != pollView) {
        id node = [hit respondsToSelector:@selector(asyncdisplaykit_node)] ? [hit asyncdisplaykit_node] : nil;
        if (node && [node isKindOfClass:optionClass]) return hit;
        hit = hit.superview;
    }
    return nil;
}

static void ApolloPollClearTouchHighlight(id pollNode) {
    UIView *row = objc_getAssociatedObject(pollNode, kApolloPollHighlightedViewKey);
    if (row) row.backgroundColor = UIColor.clearColor;
    objc_setAssociatedObject(pollNode, kApolloPollHighlightedViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Consume the touch point recorded by the PollNode touchesEnded hook and map
// it to the option row it landed on. Returns nil for taps outside the rows and
// for touchless activations (VoiceOver sends the control action directly).
static RDKPollOption *ApolloPollConsumeTappedOption(id pollNode) {
    NSValue *pointValue = objc_getAssociatedObject(pollNode, kApolloPollLastTouchPointKey);
    objc_setAssociatedObject(pollNode, kApolloPollLastTouchPointKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *pollView = ApolloPollNodeView(pollNode);
    if (!pointValue || !pollView) return nil;
    return ApolloPollOptionAtPoint(pollView, pointValue.CGPointValue, 1);
}

// Apollo builds the poll's "N Votes · Closes in …" title once in PollNode's
// Swift init and never refreshes it: didLoad (also the model-updated
// reconfigure path) rebuilds only the option/results rows, and
// layoutSpecThatFits: just arranges existing nodes. Without this, the count
// line keeps the pre-vote number until the post is fetched fresh. Rewrite just
// the leading count in place, keeping the string's attributes; if a future
// Apollo build changes the format, the regex misses and this no-ops.
static void ApolloPollRefreshVoteCountTitle(id pollNode) {
    RDKPoll *poll = ApolloPollObjectIvar(pollNode, "poll");
    id titleNode = ApolloPollObjectIvar(pollNode, "titleNode");
    NSAttributedString *title = [titleNode respondsToSelector:@selector(attributedText)]
        ? [titleNode attributedText] : nil;
    if (!poll || title.length == 0) return;
    NSRegularExpression *countPattern = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\d.,]+[KkMm]?\\s+Votes?" options:0 error:nil];
    NSTextCheckingResult *match = [countPattern firstMatchInString:title.string options:0
                                                             range:NSMakeRange(0, title.length)];
    if (!match) return;
    long long total = poll.totalVoteCount;
    NSString *replacement = [NSString stringWithFormat:@"%lld %@", total,
                             total == 1 ? @"Vote" : @"Votes"];
    NSMutableAttributedString *updated = [title mutableCopy];
    [updated replaceCharactersInRange:match.range withString:replacement];
    [titleNode setAttributedText:updated];
}

// Some Apollo/Reddit responses carry the current user's selection but omit
// aggregate counts (totalVoteCount and option voteCount are both zero). That
// combination is impossible for a displayed voted poll and produces the
// misleading "0 Votes" footer. Preserve the server-confirmed selection and
// make the local minimum internally consistent until a full aggregate arrives.
static void ApolloPollNormalizeSelectedCounts(RDKPoll *poll) {
    if (!poll || poll.userSelectionIdentifier.length == 0) return;
    RDKPollOption *selected = nil;
    for (RDKPollOption *option in poll.options) {
        if ([option.identifier isEqualToString:poll.userSelectionIdentifier]) {
            selected = option;
            break;
        }
    }
    if (!selected) return;
    if (selected.voteCount < 1) selected.voteCount = 1;
    if (poll.totalVoteCount < selected.voteCount) poll.totalVoteCount = selected.voteCount;
}

static void ApolloPollReconcilePoll(RDKPoll *poll, NSString *postID, NSString *username) {
    if (!poll || username.length == 0 || postID.length == 0) return;
    // A non-empty server selection is authoritative and refreshes our cache.
    if (poll.userSelectionIdentifier.length > 0) {
        ApolloPollRememberVote(username, postID, poll.userSelectionIdentifier);
        ApolloPollNormalizeSelectedCounts(poll);
        return;
    }
    NSString *remembered = ApolloPollRememberedVote(username, postID);
    if (remembered.length == 0) return;
    for (RDKPollOption *option in poll.options) {
        if ([option.identifier isEqualToString:remembered]) {
            poll.userSelectionIdentifier = remembered;
            ApolloPollNormalizeSelectedCounts(poll);
            return;
        }
    }
}

static void ApolloPollReconcileRememberedVote(RDKLink *link, NSString *username) {
    ApolloPollReconcilePoll(link.poll, link.identifier, username);
}

static void ApolloPollRenderCurrentVote(id pollNode) {
    if (!pollNode) return;
    ApolloPollNormalizeSelectedCounts(ApolloPollObjectIvar(pollNode, "poll"));
    if ([pollNode respondsToSelector:@selector(didLoad)]) {
        [pollNode didLoad];
        [pollNode setNeedsLayout];
    }
    ApolloPollRefreshVoteCountTitle(pollNode);
}

// Section controllers deliberately ignore an update whose `newModel` is the
// same object.  Publish a copy as soon as the local model changes, rather than
// waiting for Reddit's response: PollNode decides whether to build option rows
// or checked result rows at construction time, so merely changing `poll` on
// the old node cannot transition it to the voted presentation.
static void ApolloPollPublishLinkUpdate(RDKLink *link, id pollNode) {
    if (!link) return;
    RDKLink *newLink = [(id)link copy];
    if (newLink) {
        if ([pollNode respondsToSelector:@selector(modelObjectUpdatedNotificationReceived:)]) {
            NSNotification *notification = [NSNotification notificationWithName:@"com.christianselig.ModelObjectUpdated"
                                                                             object:link
                                                                           userInfo:@{ @"newModel": newLink }];
            [pollNode modelObjectUpdatedNotificationReceived:notification];
        }
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"com.christianselig.ModelObjectUpdated" object:link
                        userInfo:@{ @"newModel": newLink }];
    }
    // The notification replaces feed/header cells.  This covers the currently
    // mounted node too until its section controller consumes the update.
    ApolloPollRenderCurrentVote(pollNode);
}

static void ApolloPollCastVote(RDKLink *link, RDKPollOption *option,
                               ApolloWebSessionEntry *session, NSString *username, id pollNode) {
    NSString *baseID = ApolloPollCanonicalBaseID(link);
    if (baseID.length == 0 || option.identifier.length == 0) {
        ApolloLog(@"[PollVoting] vote rejected invalid local identifiers");
        ApolloPollShowError(ApolloPollPresenter(), @"Apollo could not identify this poll post.");
        return;
    }
    // RDKLink.fullName can format missing backing fields as the non-empty
    // literal "(null)_(null)".  Never use it as a wire identifier.
    NSString *postID = [@"t3_" stringByAppendingString:baseID];
    NSString *inFlightKey = ApolloPollCacheKey(username, baseID);
    if (inFlightKey.length == 0) return;
    if (!sApolloPollVotesInFlight) sApolloPollVotesInFlight = [NSMutableSet set];
    if ([sApolloPollVotesInFlight containsObject:inFlightKey]) {
        return;
    }
    [sApolloPollVotesInFlight addObject:inFlightKey];

    ApolloPollVoteRequest *request = [ApolloPollVoteRequest new];
    request.postID = postID;
    request.optionID = option.identifier;
    request.username = username;
    NSString *linkIdentifier = [baseID copy];
    __weak RDKLink *weakLink = link;
    __weak id weakPollNode = pollNode;
    request.completion = ^(BOOL success, NSString *message) {
        [sApolloPollVotesInFlight removeObject:inFlightKey];
        RDKLink *strongLink = weakLink;
        RDKPoll *poll = strongLink.poll;
        if (!success) {
            ApolloPollForgetVote(username, linkIdentifier);
            // Roll back the optimistic check/result bars if Reddit rejects it.
            if ([poll.userSelectionIdentifier isEqualToString:option.identifier]) {
                poll.userSelectionIdentifier = nil;
                option.voteCount = MAX(0, option.voteCount - 1);
                poll.totalVoteCount = MAX(0, poll.totalVoteCount - 1);
                ApolloPollRenderCurrentVote(weakPollNode);
            }
            UIView *nodeView = ApolloPollNodeView(weakPollNode);
            if (nodeView.window) {
                UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
                [feedback notificationOccurred:UINotificationFeedbackTypeError];
                ApolloPollShowError(ApolloPollPresenter(), message);
            }
            return;
        }
        // Cache only a mutation Reddit explicitly accepted.  This cache exists
        // to bridge Apollo's OAuth models, which sometimes omit the web
        // account's user_selection; it must never manufacture a server vote.
        ApolloPollRememberVote(username, linkIdentifier, option.identifier);
        if (!poll) return;

        // UI already changed in ApolloPollBeginVote.  The request only
        // confirms it now; a second delayed model notification used to be the
        // source of the visible gray-then-magenta pause after every tap.
    };
    if (!sApolloPollVoteRequests) sApolloPollVoteRequests = [NSMutableSet set];
    [sApolloPollVoteRequests addObject:request];
    [request startWithSession:session];
}

static void ApolloPollBeginVote(RDKLink *link, RDKPollOption *option, NSString *username, id pollNode) {
    RDKPoll *poll = link.poll;
    if (!poll || poll.userSelectionIdentifier.length > 0) return;
    if (ApolloPollCanonicalBaseID(link).length == 0 || option.identifier.length == 0) {
        ApolloLog(@"[PollVoting] vote rejected invalid local identifiers");
        ApolloPollShowError(ApolloPollPresenter(), @"Apollo could not identify this poll post.");
        return;
    }

    // Optimistic UI: selecting an option behaves like checking a control.
    // Network latency is no longer part of the interaction feedback path.
    poll.userSelectionIdentifier = option.identifier;
    option.voteCount += 1;
    poll.totalVoteCount += 1;
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    ApolloPollPublishLinkUpdate(link, pollNode);

    void (^continueVote)(ApolloWebSessionEntry *) = ^(ApolloWebSessionEntry *session) {
        if (!session) {
            ApolloPollForgetVote(username, link.identifier);
            poll.userSelectionIdentifier = nil;
            option.voteCount = MAX(0, option.voteCount - 1);
            poll.totalVoteCount = MAX(0, poll.totalVoteCount - 1);
            ApolloPollPublishLinkUpdate(link, pollNode);
            if (ApolloPollNodeView(pollNode).window) {
                ApolloPollShowError(ApolloPollPresenter(), @"A Reddit web session is required to vote in polls.");
            }
            return;
        }
        ApolloPollCastVote(link, option, session, username, pollNode);
    };
    ApolloWebSessionEntry *session = ApolloWebSessionFor(username);
    if (session) { continueVote(session); return; }

    // First vote on an OAuth account: harvest a matching reddit.com cookie
    // session once, then vote silently forever after.
    ApolloWebSessionLoginViewController *login = [ApolloWebSessionLoginViewController
        loginControllerForUsername:username completion:^(BOOL success) {
            if (success) {
                continueVote(ApolloWebSessionFor(username));
                return;
            }
            // Cancelling the one-time cookie harvest must also cancel the
            // optimistic selection; otherwise the checked result is left on
            // screen despite no vote ever having been sent.
            if ([poll.userSelectionIdentifier isEqualToString:option.identifier]) {
                ApolloPollForgetVote(username, link.identifier);
                poll.userSelectionIdentifier = nil;
                option.voteCount = MAX(0, option.voteCount - 1);
                poll.totalVoteCount = MAX(0, poll.totalVoteCount - 1);
                ApolloPollPublishLinkUpdate(link, pollNode);
            }
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    [ApolloPollPresenter() presentViewController:nav animated:YES completion:nil];
}

// Option picker for activations without a usable touch point: VoiceOver
// (the control action fires with no touch) and taps on the poll's title or
// vote-count footer.
static void ApolloPollPresentPicker(id pollNode, RDKLink *link, NSString *username) {
    RDKPoll *poll = link.poll;
    UIViewController *presenter = ApolloPollPresenter();
    if (!presenter || poll.options.count == 0) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Vote in Poll" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (RDKPollOption *option in poll.options) {
        if (option.text.length == 0 || option.identifier.length == 0) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:option.text style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            ApolloPollBeginVote(link, option, username, pollNode);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *pollView = ApolloPollNodeView(pollNode) ?: presenter.view;
    sheet.popoverPresentationController.sourceView = pollView;
    sheet.popoverPresentationController.sourceRect = pollView.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

// PollNode is an ASControlNode: Apollo registers pollNodeTappedWithSender: for
// its TouchUpInside event, and taps anywhere inside the poll — option rows
// included, since plain option subnodes bubble touches up the responder chain —
// fire that action. ASControlNode sends the action synchronously from
// touchesEnded, so recording the lift point here lets the action hook below
// resolve which option row was tapped. No per-row recognizers needed.
%hook _TtC6Apollo8PollNode
- (void)layoutSubviews {
    %orig;
    ApolloPollNormalizeSelectedCounts(ApolloPollObjectIvar(self, "poll"));
    if (!ApolloThemeRuntimeIsActive()) return;
    UIColor *card = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground);
    UIView *pollView = ApolloPollNodeView(self);
    if (card && pollView) pollView.backgroundColor = card;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    UIView *pollView = ApolloPollNodeView(self);
    UIView *row = touch && pollView
        ? ApolloPollOptionViewAtPoint(pollView, [touch locationInView:pollView]) : nil;
    if (row) {
        row.backgroundColor = [(ApolloThemeAccentColor() ?: row.tintColor) colorWithAlphaComponent:0.16];
        // Retain until touchesEnded: its synchronous action can rebuild the
        // PollNode and release the old option views before we clear the state.
        objc_setAssociatedObject(self, kApolloPollHighlightedViewKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    UIView *view = ApolloPollNodeView(self);
    if (touch && view) {
        objc_setAssociatedObject(self, kApolloPollLastTouchPointKey,
            [NSValue valueWithCGPoint:[touch locationInView:view]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
    ApolloPollClearTouchHighlight(self);
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    %orig;
    ApolloPollClearTouchHighlight(self);
}
%end

// Reconcile at the model boundary, before CommentsHeaderCellNode's Swift
// initializer snapshots link.poll into its immutable pollNode. Restoring from
// didLoad is too late: by then PollNode has already chosen optionNodes instead
// of resultsNodes, which is why the success state appeared only after a manual
// refresh created another header.
%hook RDKLink
- (void)setPoll:(RDKPoll *)poll {
    %orig(poll);
    ApolloPollReconcileRememberedVote(self, ApolloActiveAccountUsername());
}

- (void)setIdentifier:(NSString *)identifier {
    %orig(identifier);
    // JSON/model decoding may assign poll before identifier. Reconcile again
    // once the stable post key becomes available; the helper is idempotent.
    if (self.poll) {
        ApolloPollReconcileRememberedVote(self, ApolloActiveAccountUsername());
    }
}
%end

// The selector is implemented by CommentsHeaderCellNode (in its Apollo Swift
// extension), not CommentsHeaderSectionController. The cell's actionDelegate is
// the section controller and owns the model refresh method used after voting.
%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didLoad {
    // Reconcile before Apollo constructs/configures the mounted poll UI. A
    // navigation round trip creates a new RDKLink/RDKPoll, so fixing only the
    // old PollNode can never persist across that boundary.
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    ApolloPollReconcileRememberedVote(link, ApolloActiveAccountUsername());
    %orig;
    id pollNode = ApolloPollObjectIvar(self, "pollNode");
    // PollNode may retain a copy made during the header's initializer rather
    // than the exact RDKPoll currently attached to link. Reconcile both sides
    // of that boundary before asking the mounted node to rebuild its rows.
    ApolloPollReconcilePoll(ApolloPollObjectIvar(pollNode, "poll"), link.identifier,
                            ApolloActiveAccountUsername());
    ApolloPollRenderCurrentVote(pollNode);
}

- (void)pollNodeTappedWithSender:(id)sender {
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    RDKPoll *poll = link.poll;
    ApolloPollReconcileRememberedVote(link, ApolloActiveAccountUsername());
    // Ended/voted polls keep Apollo's native percentages/counts toggle; a
    // logged-out browser keeps today's Safari flow.
    if (!poll || poll.hasPollEnded || poll.userSelectionIdentifier.length > 0) { %orig; return; }
    NSString *username = ApolloActiveAccountUsername();
    if (username.length == 0) { %orig; return; }

    id pollNode = sender;
    if (![pollNode isKindOfClass:objc_getClass("_TtC6Apollo8PollNode")]) {
        pollNode = ApolloPollObjectIvar(self, "pollNode");
    }
    RDKPollOption *option = ApolloPollConsumeTappedOption(pollNode);
    if (option) {
        ApolloPollBeginVote(link, option, username, pollNode);
    } else {
        ApolloPollPresentPicker(pollNode, link, username);
    }
}
%end

%ctor {}
