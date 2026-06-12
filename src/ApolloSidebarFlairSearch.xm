// ApolloSidebarFlairSearch.xm
//
// "Search by flair" in the subreddit sidebar (new-Reddit parity).
//
// Apollo's sidebar (SubredditSidebarViewController) renders only the
// old-Reddit sidebar markdown. New Reddit additionally has structured sidebar
// widgets — most usefully the post-flair widget ("Search by Flair" chips,
// e.g. r/soccer's Match Thread / FIFA WC Hub chips for finding live match
// threads). This module fetches /r/{sub}/api/widgets, renders the flair
// templates as colored tappable chips ABOVE the markdown (no scrolling past
// the sidebar text to reach them), and routes taps through Apollo's own URL
// handler as a flair_name:"..." search restricted to the subreddit, sorted by
// new — which opens Apollo's native search results screen.
//
// Layout: the sidebar's ASScrollNode uses a layoutSpecBlock with
// automaticallyManagesContentSize (verified at runtime), so the chips section
// is inserted by wrapping that block in a vertical stack — Texture then
// owns all sizing; no frame fighting, and contentSize follows automatically.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "ApolloCommon.h"
#import "ApolloState.h"

#pragma mark - Texture interfaces (runtime-bound, mirrors ApolloInlineImages.xm)

typedef NS_ENUM(unsigned char, ApolloSidebarASStackDirection) {
    ApolloSidebarASStackDirectionVertical = 0,
    ApolloSidebarASStackDirectionHorizontal = 1,
};

static const NSUInteger kApolloSidebarASControlEventTouchUpInside = 1 << 4;
static const NSUInteger kApolloSidebarASStackFlexWrapWrap = 1; // ASStackLayoutFlexWrapWrap

// ASSizeRange (named CDStruct_90e057aa in Apollo's class-dumped headers).
struct CDStruct_90e057aa { CGSize min; CGSize max; };

@class ASLayoutSpec;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (void)setNeedsLayout;
- (UIView *)view;
@property (nonatomic) BOOL automaticallyManagesSubnodes;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nullable, nonatomic, copy) ASLayoutSpec *(^layoutSpecBlock)(ASDisplayNode *node, struct CDStruct_90e057aa constrainedSize);
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASControlNode : ASDisplayNode
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)controlEvents;
@end

@interface ASButtonNode : ASControlNode
- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(NSUInteger)state;
@property (nonatomic) UIEdgeInsets contentEdgeInsets;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloSidebarASStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

#pragma mark - Swift ivar helpers (mirrors ApolloNativeActionMenus.xm)

static NSString *ApolloSidebarDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) {
        return nil;
    }

    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";

        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }

    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT,
            "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

static ptrdiff_t ApolloSidebarIvarOffset(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static id ApolloSidebarReadObjectIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSidebarIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    void *value = *(void **)(base + offset);
    return (__bridge id)value;
}

static NSString *ApolloSidebarReadSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSidebarIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return ApolloSidebarDecodeSwiftString(*(uint64_t *)(base + offset), *(uint64_t *)(base + offset + 0x08));
}

#pragma mark - Flair model

@interface ApolloSidebarFlairItem : NSObject
@property (nonatomic, copy) NSString *displayText; // emoji tokens stripped, for the chip label
@property (nonatomic, copy) NSString *searchText;  // raw template text, what reddit's flair_name search matches
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *textColor;
@end
@implementation ApolloSidebarFlairItem
@end

@interface ApolloSidebarFlairWidget : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<ApolloSidebarFlairItem *> *items;
@end
@implementation ApolloSidebarFlairWidget
@end

// Chip tap target: holds the subreddit + flair search text, routes the search
// URL through Apollo's URL handler (opens the native search results screen).
@interface ApolloSidebarFlairTapTarget : NSObject
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *searchText;
- (void)chipTapped:(id)sender;
@end

@implementation ApolloSidebarFlairTapTarget
- (void)chipTapped:(id)sender {
    if (self.subredditName.length == 0 || self.searchText.length == 0) return;
    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"https://www.reddit.com/r/%@/search", self.subredditName]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"flair_name:\"%@\"", self.searchText]],
        [NSURLQueryItem queryItemWithName:@"restrict_sr" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"new"],
    ];
    NSURL *url = components.URL;
    ApolloLog(@"[SidebarFlair] chip tapped flair=%@ -> %@", self.searchText, url.absoluteString);
    if (url) ApolloRouteResolvedURLViaApolloScheme(url);
}
@end

#pragma mark - Emoji token stripping

// Flair templates embed subreddit emoji as :token: (e.g. ":n_ball: Match
// Thread"). The chip shows clean text; the search query keeps the raw text
// because reddit's flair_name search matches the full flair string.
static NSString *ApolloSidebarFlairDisplayText(NSString *raw) {
    if (raw.length == 0) return raw;
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+-]+:" options:0 error:NULL];
    });
    NSString *stripped = [regex stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
    stripped = [stripped stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([stripped containsString:@"  "]) {
        stripped = [stripped stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return stripped.length > 0 ? stripped : raw;
}

static UIColor *ApolloSidebarColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 4) return nil;
    NSString *cleaned = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (cleaned.length != 6) return nil;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:cleaned] scanHexInt:&value]) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
}

#pragma mark - Widgets fetch

static NSString *ApolloSidebarEscapedSubreddit(NSString *subredditName) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [subredditName stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: subredditName;
}

static NSCache<NSString *, ApolloSidebarFlairWidget *> *ApolloSidebarFlairCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    return cache;
}

static ApolloSidebarFlairWidget *ApolloSidebarFlairWidgetFromJSON(id json) {
    NSDictionary *items = [json isKindOfClass:[NSDictionary class]] ? json[@"items"] : nil;
    if (![items isKindOfClass:[NSDictionary class]]) return nil;
    for (NSDictionary *widget in items.allValues) {
        if (![widget isKindOfClass:[NSDictionary class]]) continue;
        NSString *kind = [widget[@"kind"] isKindOfClass:[NSString class]] ? widget[@"kind"] : @"";
        if (![kind isEqualToString:@"post-flair"]) continue;
        NSArray *order = [widget[@"order"] isKindOfClass:[NSArray class]] ? widget[@"order"] : nil;
        NSDictionary *templates = [widget[@"templates"] isKindOfClass:[NSDictionary class]] ? widget[@"templates"] : nil;
        if (order.count == 0 || templates.count == 0) continue;

        NSMutableArray<ApolloSidebarFlairItem *> *flairs = [NSMutableArray array];
        for (NSString *templateID in order) {
            NSDictionary *tpl = [templates[templateID] isKindOfClass:[NSDictionary class]] ? templates[templateID] : nil;
            NSString *text = [tpl[@"text"] isKindOfClass:[NSString class]] ? tpl[@"text"] : nil;
            if (text.length == 0) continue;
            ApolloSidebarFlairItem *item = [[ApolloSidebarFlairItem alloc] init];
            item.searchText = text;
            item.displayText = ApolloSidebarFlairDisplayText(text);
            UIColor *background = ApolloSidebarColorFromHex(tpl[@"backgroundColor"]);
            item.backgroundColor = background ?: [UIColor colorWithWhite:0.5 alpha:0.25];
            BOOL lightText = [tpl[@"textColor"] isKindOfClass:[NSString class]] && [tpl[@"textColor"] isEqualToString:@"light"];
            item.textColor = background
                ? (lightText ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0])
                : UIColor.labelColor;
            [flairs addObject:item];
        }
        if (flairs.count == 0) return nil;

        ApolloSidebarFlairWidget *result = [[ApolloSidebarFlairWidget alloc] init];
        NSString *shortName = [widget[@"shortName"] isKindOfClass:[NSString class]] ? widget[@"shortName"] : nil;
        result.title = shortName.length > 0 ? shortName : @"Search by Flair";
        result.items = flairs;
        return result;
    }
    return nil;
}

static void ApolloSidebarFlairFetchWidget(NSString *subredditName, void (^completion)(ApolloSidebarFlairWidget *widget)) {
    if (subredditName.length == 0) {
        completion(nil);
        return;
    }
    NSString *cacheKey = subredditName.lowercaseString;
    ApolloSidebarFlairWidget *cached = [ApolloSidebarFlairCache() objectForKey:cacheKey];
    if (cached) {
        completion(cached.items.count > 0 ? cached : nil);
        return;
    }

    NSString *escaped = ApolloSidebarEscapedSubreddit(subredditName);
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/widgets?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/api/widgets.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloSidebarFlair/1.0") forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        ApolloSidebarFlairWidget *widget = ApolloSidebarFlairWidgetFromJSON(json);
        ApolloLog(@"[SidebarFlair] widgets fetch r/%@ status=%ld flairs=%lu err=%@",
                  subredditName, (long)status, (unsigned long)widget.items.count, error.localizedDescription ?: @"nil");
        if (widget) {
            [ApolloSidebarFlairCache() setObject:widget forKey:cacheKey];
        } else if (status == 200) {
            // Subreddit has no flair widget — cache the miss so re-opening
            // the sidebar doesn't refetch.
            ApolloSidebarFlairWidget *miss = [[ApolloSidebarFlairWidget alloc] init];
            miss.items = @[];
            [ApolloSidebarFlairCache() setObject:miss forKey:cacheKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(widget);
        });
    }] resume];
}

#pragma mark - Section node construction

static char kApolloSidebarFlairInstalledKey;  // NSNumber(BOOL) on the VC
static char kApolloSidebarFlairTapTargetsKey; // NSArray<ApolloSidebarFlairTapTarget *> on the VC
static char kApolloSidebarFlairOrigBlockKey;  // original layoutSpecBlock, retained on the scroll node

// Builds the section node: title + wrapping chip cloud. All sizing is left to
// Texture (automaticallyManagesSubnodes + layoutSpecBlock on the container).
static ASDisplayNode *ApolloSidebarFlairBuildSection(ApolloSidebarFlairWidget *widget,
                                                     NSString *subredditName,
                                                     NSMutableArray *tapTargets) {
    Class displayNodeClass = objc_getClass("ASDisplayNode");
    Class textNodeClass = objc_getClass("ASTextNode");
    Class buttonNodeClass = objc_getClass("ASButtonNode");
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    Class insetClass = objc_getClass("ASInsetLayoutSpec");
    if (!displayNodeClass || !textNodeClass || !buttonNodeClass || !stackClass || !insetClass) return nil;

    ASTextNode *titleNode = [[textNodeClass alloc] init];
    titleNode.attributedText = [[NSAttributedString alloc] initWithString:widget.title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];

    NSMutableArray *chipNodes = [NSMutableArray array];
    for (ApolloSidebarFlairItem *item in widget.items) {
        ASButtonNode *chip = [[buttonNodeClass alloc] init];
        [chip setTitle:item.displayText
              withFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold]
             withColor:item.textColor
              forState:0 /* normal */];
        chip.backgroundColor = item.backgroundColor;
        chip.cornerRadius = 13.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(5.0, 12.0, 5.0, 12.0);

        ApolloSidebarFlairTapTarget *target = [[ApolloSidebarFlairTapTarget alloc] init];
        target.subredditName = subredditName;
        target.searchText = item.searchText;
        [tapTargets addObject:target];
        [chip addTarget:target action:@selector(chipTapped:) forControlEvents:kApolloSidebarASControlEventTouchUpInside];

        [chipNodes addObject:chip];
    }

    ASDisplayNode *container = [[displayNodeClass alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *node, struct CDStruct_90e057aa constrainedSize) {
        ASStackLayoutSpec *chipCloud = [stackClass stackLayoutSpecWithDirection:ApolloSidebarASStackDirectionHorizontal
                                                                        spacing:8.0
                                                                 justifyContent:0 /* start */
                                                                     alignItems:0 /* start */
                                                                       children:chipNodes];
        chipCloud.flexWrap = kApolloSidebarASStackFlexWrapWrap;
        chipCloud.lineSpacing = 8.0;
        return [stackClass stackLayoutSpecWithDirection:ApolloSidebarASStackDirectionVertical
                                                spacing:12.0
                                         justifyContent:0 /* start */
                                             alignItems:3 /* stretch */
                                               children:@[titleNode, chipCloud]];
    };
    return container;
}

#pragma mark - Sidebar hook

%hook _TtC6Apollo30SubredditSidebarViewController

- (void)viewDidLoad {
    %orig;
    if ([objc_getAssociatedObject(self, &kApolloSidebarFlairInstalledKey) boolValue]) return;
    objc_setAssociatedObject(self, &kApolloSidebarFlairInstalledKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *subredditName = ApolloSidebarReadSwiftStringIvar(self, "subredditName");
    if (subredditName.length == 0) return;

    __weak UIViewController *weakSelf = (UIViewController *)self;
    ApolloSidebarFlairFetchWidget(subredditName, ^(ApolloSidebarFlairWidget *widget) {
        UIViewController *vc = weakSelf;
        if (!vc || widget.items.count == 0) return;

        ASDisplayNode *scrollNode = (ASDisplayNode *)ApolloSidebarReadObjectIvar(vc, "scrollNode");
        if (!scrollNode || !scrollNode.layoutSpecBlock) {
            ApolloLog(@"[SidebarFlair] r/%@ no scroll node / layout block — skipping", subredditName);
            return;
        }

        NSMutableArray *tapTargets = [NSMutableArray array];
        ASDisplayNode *section = ApolloSidebarFlairBuildSection(widget, subredditName, tapTargets);
        if (!section) return;
        objc_setAssociatedObject(vc, &kApolloSidebarFlairTapTargetsKey, tapTargets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        ASLayoutSpec *(^origBlock)(ASDisplayNode *, struct CDStruct_90e057aa) = scrollNode.layoutSpecBlock;
        objc_setAssociatedObject(scrollNode, &kApolloSidebarFlairOrigBlockKey, origBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);

        Class stackClass = objc_getClass("ASStackLayoutSpec");
        Class insetClass = objc_getClass("ASInsetLayoutSpec");
        scrollNode.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *node, struct CDStruct_90e057aa constrainedSize) {
            ASLayoutSpec *origSpec = origBlock ? origBlock(node, constrainedSize) : nil;
            ASInsetLayoutSpec *inset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(25.0, 16.0, 0.0, 16.0) child:section];
            NSArray *children = origSpec ? @[inset, origSpec] : @[inset];
            return [stackClass stackLayoutSpecWithDirection:ApolloSidebarASStackDirectionVertical
                                                    spacing:0.0
                                             justifyContent:0 /* start */
                                                 alignItems:3 /* stretch */
                                                   children:children];
        };
        [scrollNode addSubnode:section];
        [scrollNode setNeedsLayout];
        ApolloLog(@"[SidebarFlair] r/%@ installed %lu flair chips", subredditName, (unsigned long)widget.items.count);
    });
}

%end
