#import "ApolloCommon.h"
#import "ApolloState.h"
#import <objc/message.h>
#import <objc/runtime.h>

static char kApolloUserFlairEditorPresentedKey;
static char kApolloUserFlairCapturedOptionsKey;
static char kApolloUserFlairCollapseModelKey;

static const NSUInteger kApolloUserFlairMaxLength = 64;

// The flair selector's flair options live in section 1 of its table.
static const NSInteger kApolloUserFlairOptionsSection = 1;

// Placeholder shown on the single collapsed "custom flair" row when a subreddit
// uses the old (empty-template) flair system.
static NSString *const kApolloUserFlairCustomRowText = @"Set custom flair…";

static __thread __unsafe_unretained UIViewController *tApolloUserFlairCaptureController = nil;
static __thread NSInteger tApolloUserFlairCaptureSection = NSNotFound;
static __thread NSInteger tApolloUserFlairCaptureRow = NSNotFound;
// While a collapsed "custom flair" cell is being built, this points at the
// RDKFlairOption backing that row so its (otherwise empty) getters render the
// placeholder text instead of nothing. Never mutates the model.
static __thread __unsafe_unretained id tApolloUserFlairCustomRowOption = nil;

@interface ApolloUserFlairOptionAdapter : NSObject
@property (nonatomic, strong) id option;
+ (instancetype)adapterWithOption:(id)option;
- (NSString *)templateID;
- (NSString *)displayText;
- (BOOL)isEditableWithKnown:(BOOL *)known;
- (BOOL)setDisplayText:(NSString *)text;
@end

@interface ApolloUserFlairSelectorAdapter : NSObject
@property (nonatomic, weak) UIViewController *controller;
+ (instancetype)adapterWithController:(UIViewController *)controller;
- (BOOL)isUserFlairSelector;
- (NSString *)subredditNameUsingSource:(id)source;
- (UIViewController *)presenter;
- (BOOL)prepareForNativeUpdate;
- (BOOL)performNativeUpdate;
@end

@interface ApolloUserFlairEditSession : NSObject
@property (nonatomic, strong) ApolloUserFlairSelectorAdapter *selectorAdapter;
@property (nonatomic, strong) ApolloUserFlairOptionAdapter *optionAdapter;
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *templateID;
@property (nonatomic, copy) NSString *initialText;
+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText;
@end

#pragma mark - Runtime Access

static id ApolloUserFlairObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloUserFlairSwiftStringIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') return nil;

        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *base = (uint8_t *)(__bridge void *)object + offset;
        uint64_t low = 0;
        uint64_t high = 0;
        memcpy(&low, base, sizeof(low));
        memcpy(&high, base + sizeof(low), sizeof(high));

        uint8_t discriminator = (uint8_t)(high >> 56);
        if (discriminator < 0xE0 || discriminator > 0xEF) return nil;

        NSUInteger length = discriminator - 0xE0;
        if (length == 0 || length > 15) return nil;

        char buffer[16] = {0};
        for (NSUInteger i = 0; i < length && i < 8; i++) {
            buffer[i] = (char)((low >> (i * 8)) & 0xFF);
        }
        for (NSUInteger i = 8; i < length; i++) {
            buffer[i] = (char)((high >> ((i - 8) * 8)) & 0xFF);
        }

        return [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static BOOL ApolloUserFlairBoolIvar(id object, NSString *name, BOOL *found) {
    if (found) *found = NO;
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        if (found) *found = YES;
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(BOOL *)((uint8_t *)(__bridge void *)object + offset);
    }
    return NO;
}

static BOOL ApolloUserFlairSetBoolIvar(id object, NSString *name, BOOL value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *(BOOL *)((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static BOOL ApolloUserFlairSetByteIvar(id object, NSString *name, uint8_t value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static id ApolloUserFlairRawObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *rawValue = NULL;
        memcpy(&rawValue, (uint8_t *)(__bridge void *)object + offset, sizeof(rawValue));
        return (__bridge id)rawValue;
    }
    return nil;
}

static id ApolloUserFlairSendObject(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ApolloUserFlairSendBool(id target, NSString *selectorName, BOOL *found) {
    if (found) *found = NO;
    if (!target || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    if (found) *found = YES;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        if (found) *found = NO;
        return NO;
    }
}

static id ApolloUserFlairKVCValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *ApolloUserFlairStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value respondsToSelector:@selector(stringValue)]) {
        id stringValue = ApolloUserFlairSendObject(value, @"stringValue");
        if ([stringValue isKindOfClass:[NSString class]]) return stringValue;
    }
    return nil;
}

static NSString *ApolloUserFlairObjectString(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSString *string = ApolloUserFlairStringFromValue([(NSDictionary *)object objectForKey:name]);
            if (string.length > 0) return string;
        }

        NSString *string = ApolloUserFlairStringFromValue(ApolloUserFlairSendObject(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairKVCValue(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, name));
        if (string.length > 0) return string;

        NSString *underscored = [@"_" stringByAppendingString:name];
        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, underscored));
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, name);
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, underscored);
        if (string.length > 0) return string;
    }
    return nil;
}

static NSArray *ApolloUserFlairObjectArray(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = ApolloUserFlairSendObject(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairKVCValue(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]);
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    return nil;
}

#pragma mark - Flair Option Adapter

static BOOL ApolloUserFlairOptionIsEditable(id option, BOOL *found) {
    BOOL localFound = NO;
    BOOL editable = ApolloUserFlairSendBool(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairSendBool(option, @"editable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"_isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    if (found) *found = NO;
    return NO;
}

static NSString *ApolloUserFlairOptionIdentifier(id option) {
    return ApolloUserFlairObjectString(option, @[
        @"identifier",
        @"flairID",
        @"flairId",
        @"flairTemplateID",
        @"flairTemplateId",
        @"templateID",
        @"templateId"
    ]);
}

static NSString *ApolloUserFlairOptionText(id option) {
    NSString *text = ApolloUserFlairObjectString(option, @[
        @"textRepresentation",
        @"text",
        @"flairText",
        @"flair_text",
        @"plainText",
        @"title"
    ]);
    if (text.length > 0) return text;

    NSArray *flairs = ApolloUserFlairObjectArray(option, @[@"flairs"]);
    NSMutableString *joined = [NSMutableString string];
    for (id flair in flairs) {
        NSString *piece = ApolloUserFlairObjectString(flair, @[@"textRepresentation", @"text", @"emojiLabel"]);
        if (piece.length == 0) continue;
        [joined appendString:piece];
    }
    return joined.length > 0 ? joined : nil;
}

static BOOL ApolloUserFlairSetOptionText(id option, NSString *text) {
    SEL setter = @selector(setTextRepresentation:);
    if (!option || ![option respondsToSelector:setter]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(option, setter, text ?: @"");
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@implementation ApolloUserFlairOptionAdapter

+ (instancetype)adapterWithOption:(id)option {
    ApolloUserFlairOptionAdapter *adapter = [ApolloUserFlairOptionAdapter new];
    adapter.option = option;
    return adapter;
}

- (NSString *)templateID {
    return ApolloUserFlairOptionIdentifier(self.option);
}

- (NSString *)displayText {
    return ApolloUserFlairOptionText(self.option) ?: @"";
}

- (BOOL)isEditableWithKnown:(BOOL *)known {
    return ApolloUserFlairOptionIsEditable(self.option, known);
}

- (BOOL)setDisplayText:(NSString *)text {
    return ApolloUserFlairSetOptionText(self.option, text);
}

@end

#pragma mark - Flair Selector Adapter

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth);

static NSString *ApolloUserFlairSubredditNameFromValue(id value, NSUInteger depth) {
    if (!value || depth > 2) return nil;
    NSString *direct = ApolloUserFlairStringFromValue(value);
    if (direct.length > 0) return direct;
    return ApolloUserFlairSubredditNameFromObject(value, depth + 1);
}

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;

    NSArray<NSString *> *names = @[
        @"subredditName",
        @"subreddit",
        @"displayName",
        @"name",
        @"subredditIdentifier",
        @"currentSubreddit"
    ];
    for (NSString *name in names) {
        NSString *value = ApolloUserFlairObjectString(object, @[name]);
        if (value.length > 0) return value;

        value = ApolloUserFlairObjectString(object, @[[@"_" stringByAppendingString:name]]);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairSendObject(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]), depth);
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *ApolloUserFlairCleanSubredditName(NSString *subredditName) {
    if (subredditName.length == 0) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"]) clean = [clean substringFromIndex:2];
    return clean.length > 0 ? clean : nil;
}

static BOOL ApolloUserFlairControllerLooksUserScoped(UIViewController *controller) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    if (controller.title.length > 0) [strings addObject:controller.title];
    if (controller.navigationItem.title.length > 0) [strings addObject:controller.navigationItem.title];
    if (controller.navigationItem.prompt.length > 0) [strings addObject:controller.navigationItem.prompt];

    for (NSString *string in strings) {
        NSString *lower = string.lowercaseString;
        if ([lower containsString:@"post flair"] || [lower containsString:@"link flair"] || [lower containsString:@"crosspost"]) return NO;
    }
    return YES;
}

static UIViewController *ApolloUserFlairPresenterForController(UIViewController *controller) {
    UIViewController *presenter = controller;
    while (presenter.presentedViewController && ![presenter.presentedViewController isKindOfClass:[UIAlertController class]]) {
        presenter = presenter.presentedViewController;
    }
    return presenter ?: controller;
}

@implementation ApolloUserFlairSelectorAdapter

+ (instancetype)adapterWithController:(UIViewController *)controller {
    ApolloUserFlairSelectorAdapter *adapter = [ApolloUserFlairSelectorAdapter new];
    adapter.controller = controller;
    return adapter;
}

- (BOOL)isUserFlairSelector {
    return ApolloUserFlairControllerLooksUserScoped(self.controller);
}

- (NSString *)subredditNameUsingSource:(id)source {
    NSString *subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(source ?: self.controller, 0));
    if (subredditName.length == 0 && source != self.controller) {
        subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(self.controller, 0));
    }
    return subredditName;
}

- (UIViewController *)presenter {
    return ApolloUserFlairPresenterForController(self.controller);
}

- (BOOL)prepareForNativeUpdate {
    BOOL marked = ApolloUserFlairSetBoolIvar(self.controller, @"hasMadeChanges", YES);
    if (!marked) marked = ApolloUserFlairSetByteIvar(self.controller, @"hasMadeChanges", 1);

    id updateButton = ApolloUserFlairObjectIvar(self.controller, @"updateBarButtonItem");
    if (!updateButton) updateButton = ApolloUserFlairRawObjectIvar(self.controller, @"updateBarButtonItem");
    BOOL buttonEnabled = NO;
    if ([updateButton respondsToSelector:@selector(setEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(updateButton, @selector(setEnabled:), YES);
        buttonEnabled = YES;
    }
    ApolloLog(@"[UserFlair] prepared native update dirty=%@ updateButton=%@ buttonEnabled=%@",
        marked ? @"yes" : @"no",
        updateButton ? @"yes" : @"no",
        buttonEnabled ? @"yes" : @"no");
    return marked;
}

- (BOOL)performNativeUpdate {
    UIViewController *controller = self.controller;
    SEL updateSEL = @selector(updateBarButtonItemTappedWithSender:);
    if (!controller || ![controller respondsToSelector:updateSEL]) return NO;

    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(controller, updateSEL, nil);
    });
    return YES;
}

@end

#pragma mark - Edit Session

@implementation ApolloUserFlairEditSession

+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText {
    ApolloUserFlairEditSession *session = [ApolloUserFlairEditSession new];
    session.selectorAdapter = selectorAdapter;
    session.optionAdapter = optionAdapter;
    session.subredditName = subredditName;
    session.templateID = templateID;
    session.initialText = initialText ?: @"";
    return session;
}

@end

static ApolloUserFlairEditSession *ApolloUserFlairBuildEditSession(UIViewController *controller, id option, id source, NSString *reason) {
    ApolloUserFlairSelectorAdapter *selectorAdapter = [ApolloUserFlairSelectorAdapter adapterWithController:controller];
    ApolloUserFlairOptionAdapter *optionAdapter = [ApolloUserFlairOptionAdapter adapterWithOption:option];

    BOOL editableKnown = NO;
    BOOL editable = [optionAdapter isEditableWithKnown:&editableKnown];
    NSString *subredditName = [selectorAdapter subredditNameUsingSource:source];
    NSString *templateID = [optionAdapter templateID];

    ApolloLog(@"[UserFlair] %@ tapped optionClass=%@ templateID=%@ editable=%@ editableKnown=%@ subreddit=%@",
        reason ?: @"selection",
        option ? NSStringFromClass([option class]) : @"(nil)",
        templateID ?: @"(nil)",
        editable ? @"yes" : @"no",
        editableKnown ? @"yes" : @"no",
        subredditName ?: @"(nil)");

    if (!option || ![selectorAdapter isUserFlairSelector] || !editableKnown || !editable || subredditName.length == 0 || templateID.length == 0) return nil;
    return [ApolloUserFlairEditSession sessionWithSelectorAdapter:selectorAdapter
                                                    optionAdapter:optionAdapter
                                                    subredditName:subredditName
                                                      templateID:templateID
                                                     initialText:[optionAdapter displayText]];
}

#pragma mark - Editor

static void ApolloUserFlairShowError(UIViewController *controller, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error Setting Flair"
                                                                       message:message.length > 0 ? message : @"Reddit returned an error while saving your flair."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [ApolloUserFlairPresenterForController(controller) presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL ApolloUserFlairCommitEditedSession(ApolloUserFlairEditSession *session, NSString *text) {
    // Apollo only saves through the native Update path when its selector is dirty.
    // Text-only edits on the checked template do not flip that flag, so update the option text,
    // mark the selector dirty, then invoke Apollo's Update handler.
    if (![session.optionAdapter setDisplayText:text]) return NO;
    if (![session.selectorAdapter prepareForNativeUpdate]) return NO;

    ApolloLog(@"[UserFlair] committing through native update subreddit=%@ templateID=%@ textLen=%lu",
        session.subredditName ?: @"(nil)",
        session.templateID ?: @"(nil)",
        (unsigned long)text.length);
    return [session.selectorAdapter performNativeUpdate];
}

#pragma mark - Subreddit Emoji Picker

// Reddit caps user flair at 64 text characters and 10 emojis. An emoji is inserted
// into the flair text as a :name: token, which Reddit renders back as the image.
static const NSUInteger kApolloUserFlairMaxEmojis = 10;

static NSRegularExpression *ApolloUserFlairEmojiTokenRegex(void) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+\\-]+:" options:0 error:NULL];
    });
    return regex;
}

// Cache of the user-flair-allowed emoji list per subreddit (lowercased key).
// Each item: @{ @"name": <token without colons>, @"url": <png url> }.
static NSMutableDictionary<NSString *, NSArray *> *ApolloUserFlairEmojiListCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static void ApolloUserFlairFetchEmojis(NSString *subreddit, void (^completion)(NSArray *emojis)) {
    NSString *key = subreddit.lowercaseString;
    if (key.length == 0) { if (completion) completion(@[]); return; }
    NSArray *cached;
    @synchronized (ApolloUserFlairEmojiListCache()) { cached = ApolloUserFlairEmojiListCache()[key]; }
    if (cached) { if (completion) completion(cached); return; }

    NSString *token = [sLatestRedditBearerToken copy];
    NSString *enc = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    NSString *urlStr = token.length
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/api/v1/%@/emojis/all?raw_json=1", enc]
        : [NSString stringWithFormat:@"https://www.reddit.com/api/v1/%@/emojis/all.json?raw_json=1", enc];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    if (token.length) [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 20;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSMutableArray *emojis = [NSMutableArray array];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            for (NSString *group in (NSDictionary *)json) {
                id g = ((NSDictionary *)json)[group];
                if (![g isKindOfClass:[NSDictionary class]]) continue;
                for (NSString *name in (NSDictionary *)g) {
                    id meta = ((NSDictionary *)g)[name];
                    if (![meta isKindOfClass:[NSDictionary class]]) continue;
                    if (![meta[@"user_flair_allowed"] boolValue]) continue;
                    NSString *url = meta[@"url"];
                    if (![url isKindOfClass:[NSString class]] || url.length == 0) continue;
                    [emojis addObject:@{ @"name": name, @"url": url }];
                }
            }
        }
        [emojis sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
        }];
        ApolloLog(@"[UserFlair] fetched %lu user-flair emoji for r/%@", (unsigned long)emojis.count, subreddit);
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (ApolloUserFlairEmojiListCache()) { ApolloUserFlairEmojiListCache()[key] = emojis; }
            if (completion) completion(emojis);
        });
    }] resume];
}

static NSCache<NSString *, UIImage *> *ApolloUserFlairEmojiImageCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 800; });
    return cache;
}

static void ApolloUserFlairLoadEmojiImage(NSString *urlStr, void (^completion)(UIImage *image)) {
    if (urlStr.length == 0) { if (completion) completion(nil); return; }
    UIImage *cached = [ApolloUserFlairEmojiImageCache() objectForKey:urlStr];
    if (cached) { if (completion) completion(cached); return; }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (completion) completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
        if (image) [ApolloUserFlairEmojiImageCache() setObject:image forKey:urlStr];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(image); });
    }] resume];
}

#pragma mark Emoji grid cell

@interface ApolloUserFlairEmojiCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, copy) NSString *urlKey;
@end

@implementation ApolloUserFlairEmojiCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_imageView];
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.urlKey = nil;
}
@end

#pragma mark Flair editor view controller

@interface ApolloUserFlairEditorViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) ApolloUserFlairEditSession *session;
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, strong) NSArray *allEmojis;       // [{name,url}]
@property (nonatomic, strong) NSArray *filteredEmojis;
@property (nonatomic, strong) NSDictionary *emojiURLByName;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *saveItem;
@property (nonatomic, assign) BOOL didFinish;
@end

@implementation ApolloUserFlairEditorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Set Flair";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelTapped)];
    self.saveItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem = self.saveItem;

    // Preview (rendered flair with inline emoji)
    UILabel *previewTitle = [UILabel new];
    previewTitle.text = @"Preview";
    previewTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    previewTitle.textColor = [UIColor secondaryLabelColor];

    self.previewLabel = [UILabel new];
    self.previewLabel.numberOfLines = 2;
    self.previewLabel.font = [UIFont systemFontOfSize:15];
    self.previewLabel.textColor = [UIColor labelColor];

    // Text field
    self.textField = [UITextField new];
    self.textField.placeholder = @"Flair text";
    self.textField.borderStyle = UITextBorderStyleRoundedRect;
    self.textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.textField.autocorrectionType = UITextAutocorrectionTypeDefault;
    self.textField.returnKeyType = UIReturnKeyDone;
    self.textField.delegate = self;
    NSString *initial = self.session.initialText ?: @"";
    self.textField.text = initial;
    [self.textField addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

    self.counterLabel = [UILabel new];
    self.counterLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.counterLabel.textColor = [UIColor secondaryLabelColor];
    self.counterLabel.textAlignment = NSTextAlignmentRight;

    // Search bar (filter emoji)
    self.searchBar = [UISearchBar new];
    self.searchBar.placeholder = @"Search emoji";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.hidden = YES; // shown once emoji arrive

    // Emoji grid
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(44, 44);
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(4, 12, 12, 12);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[ApolloUserFlairEmojiCell class] forCellWithReuseIdentifier:@"emoji"];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[previewTitle, self.previewLabel, self.textField, self.counterLabel, self.searchBar]];
    top.axis = UILayoutConstraintAxisVertical;
    top.spacing = 6;
    [top setCustomSpacing:2 afterView:previewTitle];
    [top setCustomSpacing:14 afterView:self.previewLabel];
    [top setCustomSpacing:2 afterView:self.textField];

    top.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:top];
    [self.view addSubview:self.collectionView];
    [self.view addSubview:self.spinner];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.collectionView.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:4],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.collectionView.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.collectionView.topAnchor constant:24],
    ]];

    [self updateCounterAndPreview];
    [self loadEmojis];
}

- (void)loadEmojis {
    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    ApolloUserFlairFetchEmojis(self.subreddit, ^(NSArray *emojis) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self.spinner stopAnimating];
        self.allEmojis = emojis;
        self.filteredEmojis = emojis;
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *e in emojis) map[e[@"name"]] = e[@"url"];
        self.emojiURLByName = map;
        self.searchBar.hidden = (emojis.count <= 24);
        [self.collectionView reloadData];
        [self updateCounterAndPreview]; // preview can now resolve tokens to images
    });
}

#pragma mark counter + preview

// Counts recognised :emoji: tokens, and reports the length of the remaining text
// (characters not part of a recognised token). Unknown :x: tokens count as text.
- (NSUInteger)emojiCountInText:(NSString *)text textLength:(NSUInteger *)outTextLen {
    NSUInteger emojiCount = 0;
    NSMutableIndexSet *emojiChars = [NSMutableIndexSet indexSet];
    NSArray *matches = [ApolloUserFlairEmojiTokenRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *m in matches) {
        NSString *tok = [text substringWithRange:m.range];
        NSString *name = [tok substringWithRange:NSMakeRange(1, tok.length - 2)];
        if (self.emojiURLByName[name]) {
            emojiCount++;
            [emojiChars addIndexesInRange:m.range];
        }
    }
    if (outTextLen) *outTextLen = text.length - emojiChars.count;
    return emojiCount;
}

- (void)updateCounterAndPreview {
    NSString *text = self.textField.text ?: @"";
    NSUInteger textLen = 0;
    NSUInteger emojiCount = [self emojiCountInText:text textLength:&textLen];
    BOOL overText = textLen > kApolloUserFlairMaxLength;
    BOOL overEmoji = emojiCount > kApolloUserFlairMaxEmojis;
    self.counterLabel.text = [NSString stringWithFormat:@"%lu/%lu chars · %lu/%lu emoji",
        (unsigned long)textLen, (unsigned long)kApolloUserFlairMaxLength,
        (unsigned long)emojiCount, (unsigned long)kApolloUserFlairMaxEmojis];
    self.counterLabel.textColor = (overText || overEmoji) ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
    self.saveItem.enabled = !overText && !overEmoji;
    [self refreshPreview];
}

- (void)refreshPreview {
    NSString *text = self.textField.text ?: @"";
    if (text.length == 0) {
        self.previewLabel.attributedText = nil;
        self.previewLabel.text = @"(empty)";
        self.previewLabel.textColor = [UIColor tertiaryLabelColor];
        return;
    }
    self.previewLabel.textColor = [UIColor labelColor];
    self.previewLabel.attributedText = [self attributedFlairForText:text];
}

// Build an attributed string, replacing recognised :name: tokens with inline emoji
// images (loaded async; refreshes the preview when an image arrives).
- (NSAttributedString *)attributedFlairForText:(NSString *)text {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSDictionary *baseAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:15], NSForegroundColorAttributeName: [UIColor labelColor] };
    NSArray *matches = [ApolloUserFlairEmojiTokenRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSUInteger cursor = 0;
    __weak typeof(self) weakSelf = self;
    for (NSTextCheckingResult *m in matches) {
        NSString *name = [[text substringWithRange:m.range] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
        NSString *url = self.emojiURLByName[name];
        if (!url) continue; // leave unknown tokens as literal text (handled below)
        if (m.range.location > cursor) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringWithRange:NSMakeRange(cursor, m.range.location - cursor)] attributes:baseAttrs]];
        }
        NSTextAttachment *att = [NSTextAttachment new];
        att.bounds = CGRectMake(0, -3, 18, 18);
        UIImage *img = [ApolloUserFlairEmojiImageCache() objectForKey:url];
        if (img) {
            att.image = img;
        } else {
            ApolloUserFlairLoadEmojiImage(url, ^(UIImage *image) {
                typeof(self) self = weakSelf;
                if (self && image) [self refreshPreview];
            });
        }
        [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        cursor = m.range.location + m.range.length;
    }
    if (cursor < text.length) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringFromIndex:cursor] attributes:baseAttrs]];
    }
    return out;
}

- (void)textChanged { [self updateCounterAndPreview]; }

#pragma mark actions

- (void)insertEmojiToken:(NSString *)name {
    NSUInteger textLen = 0;
    NSUInteger emojiCount = [self emojiCountInText:(self.textField.text ?: @"") textLength:&textLen];
    if (emojiCount >= kApolloUserFlairMaxEmojis) {
        [self flashCounter];
        return;
    }
    NSString *token = [NSString stringWithFormat:@":%@:", name];
    UITextField *tf = self.textField;
    UITextRange *range = tf.selectedTextRange;
    if (!range) range = [tf textRangeFromPosition:tf.endOfDocument toPosition:tf.endOfDocument];
    [tf replaceRange:range withText:token];
    [self updateCounterAndPreview];
}

- (void)flashCounter {
    self.counterLabel.textColor = [UIColor systemRedColor];
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)cancelTapped { [self finishAndDismiss]; }

- (void)saveTapped {
    NSString *text = self.textField.text ?: @"";
    ApolloUserFlairEditSession *session = self.session;
    ApolloLog(@"[UserFlair] save tapped subreddit=%@ templateID=%@ textLen=%lu",
        session.subredditName ?: @"(nil)", session.templateID ?: @"(nil)", (unsigned long)text.length);
    self.didFinish = YES;
    UIViewController *presenter = ApolloUserFlairPresenterForController(session.selectorAdapter.controller);
    UIViewController *flairController = session.selectorAdapter.controller;
    [self dismissViewControllerAnimated:YES completion:^{
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!ApolloUserFlairCommitEditedSession(session, text)) {
            ApolloUserFlairShowError(presenter, @"Apollo's native flair update action was unavailable.");
        }
    }];
}

- (void)finishAndDismiss {
    self.didFinish = YES;
    UIViewController *flairController = self.session.selectorAdapter.controller;
    [self dismissViewControllerAnimated:YES completion:^{
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Catch interactive (swipe-down) dismissal so the selector can present again later.
    if (!self.didFinish) {
        UIViewController *flairController = self.session.selectorAdapter.controller;
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

#pragma mark text field

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return NO; }

#pragma mark search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredEmojis = self.allEmojis;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *bindings) {
            return [e[@"name"] rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.filteredEmojis = [self.allEmojis filteredArrayUsingPredicate:p];
    }
    [self.collectionView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredEmojis.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloUserFlairEmojiCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"emoji" forIndexPath:indexPath];
    if (indexPath.item >= (NSInteger)self.filteredEmojis.count) return cell;
    NSDictionary *e = self.filteredEmojis[indexPath.item];
    NSString *url = e[@"url"];
    cell.urlKey = url;
    UIImage *cached = [ApolloUserFlairEmojiImageCache() objectForKey:url];
    if (cached) {
        cell.imageView.image = cached;
    } else {
        // Capture the cell weakly so an in-flight download for a since-recycled cell
        // doesn't keep it alive while scrolling thousands of emoji; the urlKey guard
        // still prevents a stale image from landing on a reused cell.
        __weak ApolloUserFlairEmojiCell *weakCell = cell;
        ApolloUserFlairLoadEmojiImage(url, ^(UIImage *image) {
            ApolloUserFlairEmojiCell *strongCell = weakCell;
            if (image && strongCell && [strongCell.urlKey isEqualToString:url]) strongCell.imageView.image = image;
        });
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (indexPath.item >= (NSInteger)self.filteredEmojis.count) return;
    NSDictionary *e = self.filteredEmojis[indexPath.item];
    [self insertEmojiToken:e[@"name"]];
}

@end

static void ApolloUserFlairPresentEditor(ApolloUserFlairEditSession *session) {
    UIViewController *controller = session.selectorAdapter.controller;
    if ([objc_getAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloUserFlairEditorViewController *editor = [ApolloUserFlairEditorViewController new];
    editor.session = session;
    editor.subreddit = session.subredditName;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    ApolloLog(@"[UserFlair] presenting flair editor subreddit=%@ templateID=%@ initialLen=%lu",
        session.subredditName ?: @"(nil)",
        session.templateID ?: @"(nil)",
        (unsigned long)(session.initialText.length));
    [[session.selectorAdapter presenter] presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Row Option Capture

static NSNumber *ApolloUserFlairRowKey(NSInteger section, NSInteger row) {
    return @((((long long)section) << 32) | ((long long)row & 0xffffffffLL));
}

static NSMutableDictionary<NSNumber *, id> *ApolloUserFlairCapturedOptions(UIViewController *controller, BOOL create) {
    if (!controller) return nil;
    @synchronized (controller) {
        NSMutableDictionary *options = objc_getAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey);
        if (!options && create) {
            options = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey, options, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return options;
    }
}

static void ApolloUserFlairCaptureOptionIfNeeded(id option) {
    UIViewController *controller = tApolloUserFlairCaptureController;
    if (!controller || tApolloUserFlairCaptureSection == NSNotFound || tApolloUserFlairCaptureRow == NSNotFound || !option) return;

    NSNumber *key = ApolloUserFlairRowKey(tApolloUserFlairCaptureSection, tApolloUserFlairCaptureRow);
    @synchronized (controller) {
        NSMutableDictionary *options = ApolloUserFlairCapturedOptions(controller, YES);
        options[key] = option;
    }
}

static id ApolloUserFlairCapturedOptionAtIndexPath(UIViewController *controller, NSIndexPath *indexPath) {
    if (!controller || !indexPath) return nil;
    NSNumber *key = ApolloUserFlairRowKey(indexPath.section, indexPath.row);
    @synchronized (controller) {
        return ApolloUserFlairCapturedOptions(controller, NO)[key];
    }
}

static BOOL ApolloUserFlairMaybePresentEditorForOption(UIViewController *controller, id option, id source, NSString *reason) {
    if (!controller) return NO;
    ApolloUserFlairEditSession *session = ApolloUserFlairBuildEditSession(controller, option, source, reason);
    if (!session) return NO;
    ApolloUserFlairPresentEditor(session);
    return YES;
}

#pragma mark - Old Flair System Collapse
//
// Subreddits still on Reddit's "old" CSS-class flair system expose their flair
// templates with NO text and NO emoji — only an editable flag and a UUID. On
// mobile they are indistinguishable, so Apollo renders a wall of identical blank
// rows (r/nintendo returns 346) and shows a scary "Apollo is unable to interact"
// alert. We collapse every empty-but-editable template into a single, labelled
// "Set custom flair…" row that opens the text editor, and suppress the alert.
// Labelled templates (text or emoji) and ordinary (new-system) subreddits are
// left exactly as Apollo presents them.

// Returns the controller's flairOptions as an NSArray. The Swift
// `[RDKFlairOption]?` ivar bridges to a _ContiguousArrayStorage which responds
// to NSArray selectors (verified at runtime); nil/empty read back safely.
static NSArray *ApolloUserFlairControllerOptions(UIViewController *controller) {
    id raw = ApolloUserFlairRawObjectIvar(controller, @"flairOptions");
    if ([raw isKindOfClass:[NSArray class]]) return (NSArray *)raw;
    return nil;
}

// "Labelled" = something the user can actually tell apart: non-empty text or at
// least one flair piece (e.g. an emoji-only flair).
static BOOL ApolloUserFlairOptionIsLabeled(id option) {
    NSString *text = ApolloUserFlairOptionText(option);
    if (text.length > 0) return YES;
    NSArray *flairs = ApolloUserFlairObjectArray(option, @[@"flairs"]);
    return flairs.count > 0;
}

@interface ApolloUserFlairCollapseModel : NSObject
@property (nonatomic) BOOL active;
// displayRow -> real index into flairOptions
@property (nonatomic, strong) NSArray<NSNumber *> *realRows;
// real index of the single representative "custom flair" row (or NSNotFound)
@property (nonatomic) NSInteger customRealRow;
// identity of the flairOptions array this model was computed from
@property (nonatomic) const void *sourcePtr;
@end

@implementation ApolloUserFlairCollapseModel
@end

static ApolloUserFlairCollapseModel *ApolloUserFlairBuildCollapseModel(NSArray *options) {
    ApolloUserFlairCollapseModel *model = [ApolloUserFlairCollapseModel new];
    model.customRealRow = NSNotFound;
    model.active = NO;

    NSMutableArray<NSNumber *> *labeledRows = [NSMutableArray array];
    NSInteger firstEmptyEditable = NSNotFound;
    NSInteger emptyEditableCount = 0;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        id option = options[i];
        if (ApolloUserFlairOptionIsLabeled(option)) {
            [labeledRows addObject:@(i)];
            continue;
        }
        BOOL editableKnown = NO;
        BOOL editable = ApolloUserFlairOptionIsEditable(option, &editableKnown);
        if (editableKnown && editable) {
            emptyEditableCount++;
            if (firstEmptyEditable == NSNotFound) firstEmptyEditable = i;
        }
        // Empty AND non-editable templates carry no usable information on mobile
        // (no text, can't be typed into) — they are dropped from the collapsed list.
    }

    // Only collapse when the "endless blank rows" problem actually exists: two or
    // more empty editable templates. One empty editable row is fine as-is.
    if (emptyEditableCount >= 2 && firstEmptyEditable != NSNotFound) {
        NSMutableArray<NSNumber *> *rows = [labeledRows mutableCopy];
        [rows addObject:@(firstEmptyEditable)];
        model.realRows = rows;
        model.customRealRow = firstEmptyEditable;
        model.active = YES;
    }
    return model;
}

static ApolloUserFlairCollapseModel *ApolloUserFlairCollapseModelFor(UIViewController *controller) {
    if (!controller) return nil;
    NSArray *options = ApolloUserFlairControllerOptions(controller);
    if (!options) return nil;

    ApolloUserFlairCollapseModel *cached = objc_getAssociatedObject(controller, &kApolloUserFlairCollapseModelKey);
    if (cached && cached.sourcePtr == (__bridge const void *)options) return cached;

    ApolloUserFlairCollapseModel *model = ApolloUserFlairBuildCollapseModel(options);
    model.sourcePtr = (__bridge const void *)options;
    objc_setAssociatedObject(controller, &kApolloUserFlairCollapseModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (model.active) {
        ApolloLog(@"[UserFlair] old-flair collapse: %lu options -> %lu rows (custom row real index %ld)",
            (unsigned long)options.count, (unsigned long)model.realRows.count, (long)model.customRealRow);
    }
    return model;
}

// One reusable RDKFlair carrying the placeholder text, so the collapsed row
// renders through Apollo's normal flair cell layout instead of as a blank pill.
static NSArray *ApolloUserFlairCustomRowSyntheticFlairs(void) {
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class flairClass = objc_getClass("RDKFlair");
        SEL initSEL = @selector(initWithRawText:);
        if (flairClass && [flairClass instancesRespondToSelector:initSEL]) {
            id flair = ((id (*)(id, SEL, id))objc_msgSend)([flairClass alloc], initSEL, kApolloUserFlairCustomRowText);
            if (flair) cached = @[flair];
        }
        if (!cached) {
            // The synthetic flair is what makes the collapsed row render its label;
            // without it the row falls back to Apollo's empty rendering (still a
            // single collapsed row, just unlabelled). Surface the failure so a
            // future RDKFlair API change doesn't degrade silently.
            ApolloLog(@"[UserFlair] warning: could not build synthetic RDKFlair; custom-flair row will render unlabelled");
        }
    });
    return cached;
}

// YES when the presenter chain contains Apollo's flair selector. Used to scope
// alert suppression to that screen. NOTE: Apollo presents this alert *before* it
// stores self.flairOptions (verified in the binary), so the collapse model is not
// yet computable here — we deliberately key off the controller's presence, not
// its model. The alert's title is unique to this one situation, so this is safe.
static BOOL ApolloUserFlairPresenterHasFlairSelector(UIViewController *presenter) {
    Class flairClass = objc_getClass("_TtC6Apollo27FlairSelectorViewController");
    if (!flairClass) return NO;

    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    if (presenter) [candidates addObject:presenter];
    if ([presenter isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)presenter;
        [candidates addObjectsFromArray:nav.viewControllers];
    }
    if (presenter.presentedViewController) [candidates addObject:presenter.presentedViewController];

    for (UIViewController *candidate in candidates) {
        if ([candidate isKindOfClass:flairClass]) return YES;
    }
    return NO;
}

#pragma mark - Hooks

// Swallow Apollo's "Subreddit Uses 'Old' Flair System" alert app-wide. The alert
// claims Apollo "is unable to properly interact" with the subreddit, which is no
// longer true once we collapse the empty templates into a usable custom-flair
// row. We only suppress it when Apollo's flair selector is the screen presenting
// it (the alert is presented off the selector's nav container, not the controller
// itself, hence this global hook); its title is unique to this one situation.
%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        NSString *title = [(UIAlertController *)viewControllerToPresent title] ?: @"";
        if ([title localizedCaseInsensitiveContainsString:@"Old"] &&
            [title localizedCaseInsensitiveContainsString:@"Flair System"] &&
            ApolloUserFlairPresenterHasFlairSelector((UIViewController *)self)) {
            ApolloLog(@"[UserFlair] suppressed old-flair-system alert (presenter=%@)", NSStringFromClass([self class]));
            if (completion) completion();
            return;
        }
    }
    %orig;
}

%end

%hook _TtC6Apollo27FlairSelectorViewController

- (NSInteger)tableNode:(id)tableNode numberOfRowsInSection:(NSInteger)section {
    if (section == kApolloUserFlairOptionsSection) {
        ApolloUserFlairCollapseModel *model = ApolloUserFlairCollapseModelFor((UIViewController *)self);
        if (model.active) return (NSInteger)model.realRows.count;
    }
    return %orig;
}

- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != kApolloUserFlairOptionsSection) return %orig;

    // Map the displayed row back to the real flairOptions index when collapsed.
    ApolloUserFlairCollapseModel *model = ApolloUserFlairCollapseModelFor((UIViewController *)self);
    NSInteger realRow = indexPath.row;
    BOOL isCustomRow = NO;
    NSIndexPath *effectiveIndexPath = indexPath;
    if (model.active) {
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)model.realRows.count) return %orig;
        realRow = [model.realRows[indexPath.row] integerValue];
        isCustomRow = (realRow == model.customRealRow);
        effectiveIndexPath = [NSIndexPath indexPathForRow:realRow inSection:kApolloUserFlairOptionsSection];
    }

    id originalBlock = %orig(tableNode, effectiveIndexPath);
    if (!originalBlock) return originalBlock;

    // For the collapsed "custom flair" row, look up the backing option so its
    // getters can render the placeholder while this cell is being built.
    __unsafe_unretained id customRowOption = nil;
    if (isCustomRow) {
        NSArray *options = ApolloUserFlairControllerOptions((UIViewController *)self);
        if (realRow >= 0 && realRow < (NSInteger)options.count) customRowOption = options[realRow];
    }

    id copiedBlock = [originalBlock copy];
    __weak UIViewController *weakController = (UIViewController *)self;
    NSInteger captureRow = realRow;

    return [^id {
        UIViewController *strongController = weakController;
        UIViewController *previousController = tApolloUserFlairCaptureController;
        NSInteger previousSection = tApolloUserFlairCaptureSection;
        NSInteger previousRow = tApolloUserFlairCaptureRow;
        id previousCustomOption = tApolloUserFlairCustomRowOption;
        id node = nil;

        tApolloUserFlairCaptureController = strongController;
        tApolloUserFlairCaptureSection = kApolloUserFlairOptionsSection;
        tApolloUserFlairCaptureRow = captureRow;
        tApolloUserFlairCustomRowOption = customRowOption;
        @try {
            node = ((id (^)(void))copiedBlock)();
        } @finally {
            tApolloUserFlairCaptureController = previousController;
            tApolloUserFlairCaptureSection = previousSection;
            tApolloUserFlairCaptureRow = previousRow;
            tApolloUserFlairCustomRowOption = previousCustomOption;
        }

        return node;
    } copy];
}

- (void)tableNode:(id)tableNode didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *effectiveIndexPath = indexPath;
    ApolloUserFlairCollapseModel *model = (indexPath.section == kApolloUserFlairOptionsSection)
        ? ApolloUserFlairCollapseModelFor((UIViewController *)self) : nil;
    if (model.active && indexPath.row >= 0 && indexPath.row < (NSInteger)model.realRows.count) {
        effectiveIndexPath = [NSIndexPath indexPathForRow:[model.realRows[indexPath.row] integerValue]
                                               inSection:kApolloUserFlairOptionsSection];
    }

    id tappedOption = ApolloUserFlairCapturedOptionAtIndexPath((UIViewController *)self, effectiveIndexPath);
    %orig(tableNode, effectiveIndexPath);

    // When collapsed, the displayed row index differs from the real index Apollo
    // just selected, so the checkmark may land on the wrong (off-screen) row.
    // Reload so the visible rows recompute their checkmark from currentFlairID.
    if (model.active && [tableNode respondsToSelector:@selector(reloadData)]) {
        ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
    }

    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        ApolloUserFlairMaybePresentEditorForOption(strongController, tappedOption, strongController, @"row-select");
    });
}

%end

%hook RDKFlairOption

- (NSString *)identifier {
    NSString *identifier = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return identifier;
}

- (NSString *)textRepresentation {
    NSString *textRepresentation = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    if (tApolloUserFlairCustomRowOption && tApolloUserFlairCustomRowOption == self) {
        return kApolloUserFlairCustomRowText;
    }
    return textRepresentation;
}

- (BOOL)isEditable {
    BOOL editable = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return editable;
}

- (NSArray *)flairs {
    NSArray *flairs = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    if (tApolloUserFlairCustomRowOption && tApolloUserFlairCustomRowOption == self) {
        NSArray *synthetic = ApolloUserFlairCustomRowSyntheticFlairs();
        if (synthetic) return synthetic;
    }
    return flairs;
}

%end
