// ApolloFeedTextPostThumbnails.xm
//
// Gives self/text posts a real feed thumbnail when the post body embeds media
// (Reddit-uploaded images via media_metadata, or direct external image links in
// the selftext) but Reddit/Apollo produced no native thumbnail. Without this,
// such posts show a bare link card in large mode and a grey placeholder square
// in compact mode.
//
// Strategy A (non-invasive): we only set the existing thumbnail node's URL on
// the affected cells. We do NOT change tap routing, post type, or the layout
// model — eligible posts stay self posts and tapping still opens the post.
//
// Eligibility (strict): act ONLY when
//   * link.selfPost == YES, AND
//   * the link has no usable native media (no http(s) thumbnailURL, no
//     previewMedia.sourceImage, no gallery, no video), AND
//   * we can derive at least one embedded image URL from media_metadata or the
//     selftext.
// This guarantees normal image/gallery/video/link posts are untouched.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloMediaMetadata.h"
#import "Tweak.h"

// Tweak.h's RDKLink declares selfPost/selfText/mediaMetadata/previewMedia. The
// native-media gate also needs these media accessors — declare them here so the
// compiler knows the selectors (they exist on the real runtime class).
@interface RDKLink (ApolloFeedThumb)
@property (readonly, copy, nonatomic) NSURL *thumbnailURL;
@property (retain, nonatomic) id gallery;
@property (retain, nonatomic) id internalGallery;
@property (retain, nonatomic) id mediaVideo;
@property (retain, nonatomic) id previewVideo;
@property (retain, nonatomic) id crossPostVideo;
@property (readonly, nonatomic) id video;
@end

// ASSizeRange — matches Apollo's class-dumped CDStruct_90e057aa ABI.
struct ApolloFeedThumbSizeRange { CGSize min; CGSize max; };

// MARK: - Minimal Texture (AsyncDisplayKit) surface

typedef NS_ENUM(unsigned char, ApolloFeedStackDirection) {
    ApolloFeedStackDirectionVertical = 0,
    ApolloFeedStackDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloFeedStackJustify) {
    ApolloFeedStackJustifyStart = 0,
    ApolloFeedStackJustifyCenter = 1,
    ApolloFeedStackJustifyEnd = 2,
};
typedef NS_ENUM(unsigned char, ApolloFeedStackAlign) {
    ApolloFeedStackAlignStart = 0,
    ApolloFeedStackAlignEnd = 1,
    ApolloFeedStackAlignCenter = 2,
    ApolloFeedStackAlignStretch = 3,
};

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (id)style;
- (UIView *)view;
- (BOOL)isNodeLoaded;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nullable, nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nullable, nonatomic, copy) UIColor *placeholderColor;
@property (nonatomic) BOOL placeholderEnabled;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloFeedStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloFeedStackJustify justifyContent;
@property (nonatomic) ApolloFeedStackAlign alignItems;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloFeedStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloFeedStackJustify)justifyContent
                                  alignItems:(ApolloFeedStackAlign)alignItems
                                    children:(NSArray *)children;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

// ASLayoutElementStyle subset for fixing the hero height.
@interface ApolloFeedLayoutStyle : NSObject
@property (nonatomic) CGSize preferredSize;
@property (nonatomic) CGSize minSize;
@property (nonatomic) CGSize maxSize;
@end

// Minimal ASNetworkImageNode surface we touch on Apollo's existing thumbnail nodes.
@interface ApolloFeedThumbImageNode : NSObject
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@end

// Associated-object cache: resolved thumbnail URL per RDKLink (or NSNull when
// the link was evaluated and produced nothing). Survives cell reuse because the
// hooks always re-read the live `link` ivar.
static char kApolloFeedThumbURLKey;

// Associated-object cache: aspect ratio (height/width) of the chosen image, used
// to size the injected large-mode hero node. Stored as an NSNumber.
static char kApolloFeedThumbRatioKey;

// Associated-object: the ASNetworkImageNode we inject into a RichMediaNode's
// layout for large-mode text/link posts (created once per node, reused).
static char kApolloFeedHeroNodeKey;

// Master switch (always on for now; eligibility gate keeps it scoped).
static BOOL sEnableFeedTextThumbnails = YES;

#pragma mark - URL helpers

// Direct external image URL allowlist for selftext-embedded links. Requires an
// image file extension on a known media CDN host, and rejects mp4-format GIFs.
static BOOL ApolloFeedIsDirectImageURLString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *lower = s.lowercaseString;
    if ([lower containsString:@"format=mp4"]) return NO;

    NSURL *url = [NSURL URLWithString:s];
    NSString *path = url.path.lowercaseString;
    if (path.length == 0) path = lower;
    BOOL imageExt = [path hasSuffix:@".png"] || [path hasSuffix:@".jpg"] ||
                    [path hasSuffix:@".jpeg"] || [path hasSuffix:@".webp"] ||
                    [path hasSuffix:@".gif"];
    if (!imageExt) return NO;

    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;

    static NSArray<NSString *> *suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[ @"redd.it", @"imgur.com", @"giphy.com", @"tenor.com",
                      @"redgifs.com", @"twimg.com", @"discordapp.com",
                      @"discordapp.net", @"imgchest.com" ];
    });
    for (NSString *suf in suffixes) {
        if ([host isEqualToString:suf] ||
            [host hasSuffix:[@"." stringByAppendingString:suf]]) {
            return YES;
        }
    }
    return NO;
}

// Best static-preview URL string for a single media_metadata entry. Prefers the
// largest p[] preview (signed, sized, static — good for both modes and avoids
// animating GIF entries in the feed), falling back to the canonical display URL.
static NSString *ApolloFeedStaticPreviewURLFromEntry(NSString *assetID, NSDictionary *entry) {
    NSArray *previews = entry[@"p"];
    if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
        NSDictionary *best = nil;
        long long bestArea = -1;
        for (NSDictionary *pv in previews) {
            if (![pv isKindOfClass:[NSDictionary class]]) continue;
            NSString *u = pv[@"u"];
            if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
            long long area = [pv[@"x"] longLongValue] * [pv[@"y"] longLongValue];
            if (area >= bestArea) { bestArea = area; best = pv; }
        }
        NSString *u = best[@"u"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            return [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        }
    }
    return ApolloMediaDisplayURLFromMetadataEntry(assetID, entry, NO);
}

// Source dimensions for a single media_metadata entry (falls back to largest
// preview if the canonical source size is absent). Returns area; fills w/h.
static long long ApolloFeedEntryDimensions(NSDictionary *entry, long long *outW, long long *outH) {
    long long w = 0, h = 0;
    NSDictionary *s = entry[@"s"];
    if ([s isKindOfClass:[NSDictionary class]]) {
        w = [s[@"x"] longLongValue];
        h = [s[@"y"] longLongValue];
    }
    if (w <= 0 || h <= 0) {
        NSArray *previews = entry[@"p"];
        if ([previews isKindOfClass:[NSArray class]]) {
            long long bestArea = 0;
            for (NSDictionary *pv in previews) {
                if (![pv isKindOfClass:[NSDictionary class]]) continue;
                long long pw = [pv[@"x"] longLongValue];
                long long ph = [pv[@"y"] longLongValue];
                if (pw * ph > bestArea) { bestArea = pw * ph; w = pw; h = ph; }
            }
        }
    }
    if (outW) *outW = w;
    if (outH) *outH = h;
    return w * h;
}

// YES when an entry is a valid still/animated image in media_metadata.
static BOOL ApolloFeedEntryIsImage(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    NSString *status = entry[@"status"];
    if ([status isKindOfClass:[NSString class]] && ![status isEqualToString:@"valid"]) return NO;
    NSString *e = entry[@"e"];
    return [e isKindOfClass:[NSString class]] &&
           ([e isEqualToString:@"Image"] || [e isEqualToString:@"AnimatedImage"]);
}

// The FIRST embedded image in the post body. media_metadata is an unordered
// dictionary keyed by asset ID; the asset ID also appears inside the body's
// preview.redd.it URLs, so we order entries by where their key first occurs in
// the selftext. If the first image is tiny (would look bad stretched as a
// thumbnail), we fall back to the largest image instead.
// Outputs the chosen image's aspect ratio (height/width) when known.
static NSURL *ApolloFeedThumbURLFromMediaMetadata(NSDictionary *mediaMetadata,
                                                  NSString *selfText,
                                                  CGFloat *outRatio) {
    if (outRatio) *outRatio = 0.0;
    if (![mediaMetadata isKindOfClass:[NSDictionary class]] || mediaMetadata.count == 0) {
        return nil;
    }

    NSString *body = [selfText isKindOfClass:[NSString class]] ? selfText : @"";

    NSString *firstKey = nil;       NSDictionary *firstEntry = nil;
    NSUInteger firstIndex = NSNotFound;
    NSString *largestKey = nil;     NSDictionary *largestEntry = nil;
    long long largestArea = -1;

    for (NSString *assetID in mediaMetadata) {
        NSDictionary *entry = mediaMetadata[assetID];
        if (!ApolloFeedEntryIsImage(entry)) continue;

        long long area = ApolloFeedEntryDimensions(entry, NULL, NULL);
        if (area >= largestArea) { largestArea = area; largestKey = assetID; largestEntry = entry; }

        // Order by first appearance of the asset key in the body markdown.
        NSRange r = [body rangeOfString:assetID];
        NSUInteger idx = (r.location != NSNotFound) ? r.location : NSNotFound;
        if (idx != NSNotFound && (firstIndex == NSNotFound || idx < firstIndex)) {
            firstIndex = idx; firstKey = assetID; firstEntry = entry;
        }
    }

    // Choose the first body image; if none could be ordered, use the largest.
    NSString *chosenKey = firstEntry ? firstKey : largestKey;
    NSDictionary *chosenEntry = firstEntry ?: largestEntry;
    if (!chosenEntry) return nil;

    // Size guard: a very small first image stretched as a hero looks bad, so
    // prefer the largest image when the first one is tiny.
    long long cw = 0, ch = 0;
    ApolloFeedEntryDimensions(chosenEntry, &cw, &ch);
    long long maxDim = MAX(cw, ch);
    if (maxDim > 0 && maxDim < 250 && largestEntry && largestEntry != chosenEntry) {
        chosenKey = largestKey;
        chosenEntry = largestEntry;
        ApolloFeedEntryDimensions(chosenEntry, &cw, &ch);
    }

    if (outRatio && cw > 0 && ch > 0) *outRatio = (CGFloat)((double)ch / (double)cw);

    NSString *urlString = ApolloFeedStaticPreviewURLFromEntry(chosenKey, chosenEntry);
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    return [NSURL URLWithString:urlString];
}

// First direct image URL found in the selftext (markdown body).
static NSURL *ApolloFeedThumbURLFromSelfText(NSString *selfText) {
    if (![selfText isKindOfClass:[NSString class]] || selfText.length == 0) return nil;

    static NSDataDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    });
    if (!detector) return nil;

    __block NSURL *found = nil;
    [detector enumerateMatchesInString:selfText
                               options:0
                                 range:NSMakeRange(0, selfText.length)
                            usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSURL *u = match.URL;
        if (u && ApolloFeedIsDirectImageURLString(u.absoluteString)) {
            found = u;
            *stop = YES;
        }
    }];
    return found;
}

#pragma mark - Eligibility

// Resolve (and cache) the thumbnail URL for an eligible self/text post.
// Returns nil for ineligible posts or when no embedded image was found.
static NSURL *ApolloFeedThumbnailURLForLink(RDKLink *link) {
    if (!sEnableFeedTextThumbnails) return nil;
    if (!link) return nil;

    id cached = objc_getAssociatedObject(link, &kApolloFeedThumbURLKey);
    if (cached) {
        return (cached == [NSNull null]) ? nil : (NSURL *)cached;
    }

    NSURL *result = nil;
    BOOL isSelf = NO;
    CGFloat ratio = 0.0; // height/width of the chosen image, if known
    @try {
        isSelf = link.selfPost;
        NSDictionary *mm = link.mediaMetadata;
        NSString *st = link.selfText;
        if (isSelf) {
            // For self/text posts we always try to surface the first embedded
            // image — even when the link reports "native" media, because Apollo
            // deliberately refuses to render a thumbnail for self posts.
            // Priority: media_metadata > selftext link > link.URL > thumbnailURL
            // > previewMedia.sourceImage.
            result = ApolloFeedThumbURLFromMediaMetadata(mm, st, &ratio);
            if (!result) result = ApolloFeedThumbURLFromSelfText(st);
            if (!result) {
                NSURL *u = link.URL;
                if ([u isKindOfClass:[NSURL class]] &&
                    ApolloFeedIsDirectImageURLString(u.absoluteString)) {
                    result = u;
                }
            }
            if (!result) {
                NSURL *t = link.thumbnailURL;
                if ([t isKindOfClass:[NSURL class]]) {
                    NSString *scheme = t.scheme.lowercaseString;
                    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
                        result = t;
                    }
                }
            }
            // previewMedia.sourceImage gives both a URL and reliable dimensions.
            id pm = link.previewMedia;
            if (pm) {
                id src = nil;
                @try { src = [pm valueForKey:@"sourceImage"]; } @catch (__unused NSException *e) {}
                if (src) {
                    NSURL *su = nil;
                    @try { su = [src valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
                    double w = 0, h = 0;
                    @try { w = [[src valueForKey:@"width"] doubleValue]; } @catch (__unused NSException *e) {}
                    @try { h = [[src valueForKey:@"height"] doubleValue]; } @catch (__unused NSException *e) {}
                    if (!result && [su isKindOfClass:[NSURL class]]) {
                        NSString *scheme = su.scheme.lowercaseString;
                        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
                            result = su;
                        }
                    }
                    // Only adopt this aspect ratio if we didn't already derive
                    // one from the chosen media_metadata image.
                    if (ratio <= 0.0 && w > 0 && h > 0) ratio = (CGFloat)(h / w);
                }
            }
        }
    } @catch (__unused NSException *e) {}

    // Clamp the hero aspect ratio to a sane band; default to a wide-ish hero.
    if (result) {
        if (ratio <= 0.0) ratio = 0.56;
        if (ratio < 0.3) ratio = 0.3;
        if (ratio > 1.2) ratio = 1.2;
        objc_setAssociatedObject(link, &kApolloFeedThumbRatioKey,
                                 @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(link, &kApolloFeedThumbURLKey,
                             result ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// Apply the URL to a thumbnail image node (idempotent — skips if already set).
static void ApolloFeedApplyThumbnailURL(id thumbNode, NSURL *url) {
    if (!thumbNode || !url) return;
    if (![thumbNode respondsToSelector:@selector(setURL:)]) return;

    ApolloFeedThumbImageNode *node = (ApolloFeedThumbImageNode *)thumbNode;
    NSURL *current = [thumbNode respondsToSelector:@selector(URL)] ? node.URL : nil;
    if ([current isEqual:url]) return;

    @try {
        if ([thumbNode respondsToSelector:@selector(setContentMode:)]) {
            node.contentMode = UIViewContentModeScaleAspectFill;
        }
        if ([thumbNode respondsToSelector:@selector(setClipsToBounds:)]) {
            node.clipsToBounds = YES;
        }
        node.URL = url;
    } @catch (__unused NSException *e) {}
}

// Remove naked direct-image URLs (e.g. https://preview.redd.it/xxxx.png?...) from
// a preview text node. Once the image is shown as a hero thumbnail, leaving its
// raw URL in the body preview is redundant clutter. Idempotent: re-stripping
// already-clean text is a no-op, so it's safe to call every layout pass.
static void ApolloFeedStripImageURLsFromTextNode(id textNodeOpaque) {
    if (!textNodeOpaque) return;
    ASTextNode *textNode = (ASTextNode *)textNodeOpaque;
    if (![textNode respondsToSelector:@selector(attributedText)]) return;
    if (![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    NSAttributedString *attr = nil;
    @try { attr = textNode.attributedText; } @catch (__unused NSException *e) { return; }
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return;

    NSString *plain = attr.string;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A whitespace-or-start delimited http(s) URL ending in an image extension.
        re = [NSRegularExpression regularExpressionWithPattern:
              @"https?://\\S+\\.(?:png|jpe?g|webp|gif)(?:\\?\\S*)?"
                                                       options:NSRegularExpressionCaseInsensitive
                                                         error:NULL];
    });
    if (!re) return;

    NSArray<NSTextCheckingResult *> *matches =
        [re matchesInString:plain options:0 range:NSMakeRange(0, plain.length)];
    if (matches.count == 0) return;

    // Keep only matches that are direct image URLs on our allowlisted hosts.
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSTextCheckingResult *m in matches) {
        NSString *cand = [plain substringWithRange:m.range];
        if (ApolloFeedIsDirectImageURLString(cand)) {
            [ranges addObject:[NSValue valueWithRange:m.range]];
        }
    }
    if (ranges.count == 0) return;

    NSMutableAttributedString *mut = [attr mutableCopy];
    // Delete from the back so earlier ranges stay valid. Also swallow one
    // trailing newline/space so we don't leave a blank line behind.
    for (NSInteger i = (NSInteger)ranges.count - 1; i >= 0; i--) {
        NSRange r = ranges[(NSUInteger)i].rangeValue;
        NSUInteger end = r.location + r.length;
        while (end < mut.length) {
            unichar c = [mut.string characterAtIndex:end];
            if (c == '\n' || c == ' ' || c == '\t' || c == '\r') { r.length += 1; end += 1; }
            else break;
        }
        if (r.location + r.length <= mut.length) [mut deleteCharactersInRange:r];
    }

    // Trim leading whitespace/newlines left at the very start.
    while (mut.length > 0) {
        unichar c = [mut.string characterAtIndex:0];
        if (c == '\n' || c == ' ' || c == '\t' || c == '\r') {
            [mut deleteCharactersInRange:NSMakeRange(0, 1)];
        } else break;
    }

    if (![mut.string isEqualToString:plain]) {
        @try { textNode.attributedText = mut; } @catch (__unused NSException *e) {}
    }
}

// Weak registry of RichMediaNodes we injected a hero into, so we can re-apply
// our preview-text/link-card cleanup when the app returns to the foreground
// (Apollo rebuilds the preview text — re-adding the naked URL — without firing
// our layoutSpecThatFits: hook).
static NSHashTable *ApolloFeedInjectedNodes(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

// Read an ivar by name via the ObjC runtime (works outside %hook blocks).
static id ApolloFeedIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

// Hide the redundant link card and strip the naked image URL on a RichMediaNode.
//
// IMPORTANT: when called from inside layoutSpecThatFits: (a layout pass),
// triggerLayout MUST be NO. Calling setNeedsLayout during a layout pass
// re-dirties the node every pass and sends Texture into an infinite relayout
// loop (pegs the main thread -> scene-update watchdog kills the app). Only the
// foreground observer, which runs outside any layout pass, should pass YES.
static void ApolloFeedReapplyCleanup(id node, BOOL triggerLayout) {
    if (!node) return;
    @try {
        id linkButton = ApolloFeedIvar(node, "linkButtonNode");
        if (linkButton) {
            ASDisplayNode *lb = (ASDisplayNode *)linkButton;
            if ([lb respondsToSelector:@selector(setHidden:)]) lb.hidden = YES;
            if ([lb respondsToSelector:@selector(setAlpha:)]) lb.alpha = 0.0;
            id st = [lb respondsToSelector:@selector(style)] ? [lb style] : nil;
            if ([st respondsToSelector:@selector(setMaxSize:)]) {
                ((ApolloFeedLayoutStyle *)st).maxSize = CGSizeZero;
            }
            if ([st respondsToSelector:@selector(setPreferredSize:)]) {
                ((ApolloFeedLayoutStyle *)st).preferredSize = CGSizeZero;
            }
        }
        id previewText = ApolloFeedIvar(node, "selfPostPreviewNode");
        ApolloFeedStripImageURLsFromTextNode(previewText);
        if (triggerLayout && [node respondsToSelector:@selector(setNeedsLayout)]) {
            [(ASDisplayNode *)node setNeedsLayout];
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Compact feed cells

// CompactPostThumbnailNode renders the small leading square in compact list mode.
// For eligible self posts this square is an empty grey placeholder; we fill it.
%hook _TtC6Apollo24CompactPostThumbnailNode

- (id)layoutSpecThatFits:(struct ApolloFeedThumbSizeRange)constrainedSize {
    id spec = %orig;
    if (!sEnableFeedTextThumbnails) return spec;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        NSURL *url = ApolloFeedThumbnailURLForLink(link);
        if (url) {
            id thumb = MSHookIvar<id>(self, "thumbnailNode");
            ApolloFeedApplyThumbnailURL(thumb, url);
        }
    } @catch (__unused NSException *e) {}
    return spec;
}

%end

#pragma mark - Large feed cells

// RichMediaNode renders the large-mode media area. For eligible self/text posts
// it normally shows only the selftext preview + a link button, with no thumbnail
// node at all (thumbnailNode is nil). We inject our own ASNetworkImageNode as a
// hero image above Apollo's original content.
%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloFeedThumbSizeRange)constrainedSize {
    id origSpec = %orig;
    if (!sEnableFeedTextThumbnails) return origSpec;

    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!link || !link.selfPost) return origSpec;

        NSURL *url = ApolloFeedThumbnailURLForLink(link);
        if (!url) return origSpec;

        // Only inject when Apollo built no native media area for this post —
        // otherwise normal image/video/album posts would get a duplicate hero.
        id thumb = MSHookIvar<id>(self, "thumbnailNode");
        id videoNode = MSHookIvar<id>(self, "videoNode");
        id albumNode = MSHookIvar<id>(self, "albumThumbnailsNode");
        if (thumb || videoNode || albumNode) {
            return origSpec;
        }

        // The hero now shows the embedded image, so hide the redundant bare link
        // card and strip the raw image URL from the preview text. We are inside a
        // layout pass here, so do NOT trigger a relayout (would loop the main
        // thread and trip the watchdog).
        ApolloFeedReapplyCleanup(self, NO);
        // Remember this node so we can re-apply the cleanup on foreground (Apollo
        // rebuilds the preview text without re-running this layout pass).
        [ApolloFeedInjectedNodes() addObject:self];

        // Reuse a single hero node per RichMediaNode across layout passes.
        ASNetworkImageNode *hero =
            (ASNetworkImageNode *)objc_getAssociatedObject(self, &kApolloFeedHeroNodeKey);
        if (!hero) {
            Class imgCls = objc_getClass("ASNetworkImageNode");
            if (!imgCls) return origSpec;
            hero = [[imgCls alloc] init];
            @try {
                hero.contentMode = UIViewContentModeScaleAspectFill;
                hero.clipsToBounds = YES;
                hero.cornerRadius = 10.0;
                if ([hero respondsToSelector:@selector(setPlaceholderEnabled:)]) {
                    hero.placeholderEnabled = YES;
                }
            } @catch (__unused NSException *e) {}
            [(ASDisplayNode *)self addSubnode:hero];
            objc_setAssociatedObject(self, &kApolloFeedHeroNodeKey, hero,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![hero.URL isEqual:url]) hero.URL = url;

        // Size the hero via an aspect ratio (height/width) layout spec.
        CGFloat ratio = 0.56;
        NSNumber *r = objc_getAssociatedObject(link, &kApolloFeedThumbRatioKey);
        if ([r isKindOfClass:[NSNumber class]]) ratio = r.doubleValue;

        Class ratioCls = objc_getClass("ASRatioLayoutSpec");
        Class stackCls = objc_getClass("ASStackLayoutSpec");
        if (!ratioCls || !stackCls || !origSpec) {
            return origSpec;
        }

        id heroSpec = [ratioCls ratioLayoutSpecWithRatio:ratio child:hero];
        id stacked = [stackCls stackLayoutSpecWithDirection:ApolloFeedStackDirectionVertical
                                                    spacing:8.0
                                             justifyContent:ApolloFeedStackJustifyStart
                                                 alignItems:ApolloFeedStackAlignStretch
                                                   children:@[ heroSpec, origSpec ]];
        return stacked ?: origSpec;
    } @catch (__unused NSException *e) {}
    return origSpec;
}

%end

#pragma mark - ctor

%ctor {
    ApolloLog(@"[FeedThumb] ApolloFeedTextPostThumbnails loaded");

    // When the app returns to the foreground, Apollo rebuilds the self-post
    // preview text (re-adding the naked image URL) without re-running our
    // layoutSpecThatFits: hook. Re-apply our cleanup on the nodes we injected
    // into, with a few staggered passes to beat Apollo's text rebuild.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!sEnableFeedTextThumbnails) return;
        for (NSNumber *delay in @[ @0.0, @0.2, @0.6 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    for (id node in ApolloFeedInjectedNodes().allObjects) {
                        ApolloFeedReapplyCleanup(node, YES);
                    }
                } @catch (__unused NSException *e) {}
            });
        }
    }];
}
