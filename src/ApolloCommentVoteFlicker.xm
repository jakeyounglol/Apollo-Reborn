// ApolloCommentVoteFlicker
//
// Fixes the one-frame "flicker" of a comment when it is up/down-voted (and on
// any other in-place model update): the whole comment body flashes blank for a
// single frame before redrawing, even though only the score digit + arrow tint
// actually change. Reported on both plain-text and media comments.
//
// ── Mechanism (measured in the sim, not inferred) ──────────────────────────
// A vote delivers the updated RDKComment via the
// "com.christianselig.ModelObjectUpdated" notification to the row's
// -[CommentSectionController modelObjectUpdatedNotificationReceived:], which
// reconfigures the cell in place (byline rebuild + -setNeedsLayout, re-running
// the cell's layoutSpecThatFits:). Texture then re-displays several of the
// cell's text/image nodes ASYNCHRONOUSLY. Instrumenting the display pipeline
// during a real vote showed one of those nodes being committed to screen with
// layer.contents == nil — i.e. the frame renders with that node BLANK, and the
// async redraw only lands on the next frame. That nil-contents commit is the
// flicker. (Whether a given node blanks depends on whether the reconfigure
// clears/replaces it — the byline usually survives, body/text nodes don't —
// but the fix below doesn't need to care which node it is.)
//
// ── Fix ────────────────────────────────────────────────────────────────────
// Make the voted cell finish its (re)display synchronously, inside the same
// frame, so there is never a nil-contents commit:
//   1. neverShowPlaceholders = YES on the cell — Texture then blocks the main
//      thread briefly to complete display of on-screen content instead of
//      committing a placeholder/blank and filling it in a frame later.
//   2. recursivelyEnsureDisplaySynchronously:YES right after the reconfigure,
//      and again on the next main-queue turn — flushes the display passes the
//      reconfigure scheduled (the -setNeedsLayout wave lands a turn later).
// Both selectors exist in Apollo's bundled Texture (verified in the binary).
//
// Scope: ONLY cells that actually receive a model-update notification while
// visible (votes, live edits). Cells never get touched during scrolling, so
// scroll perf is unaffected; the one-off synchronous draw of an already
// visible cell is a sub-millisecond text render on a tap — imperceptible.
//
// Covers both the comment rows (CommentSectionController) and the post header
// in the comments view (CommentsHeaderSectionController) — both flicker the
// same way when voted.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

@interface ASDisplayNode : NSObject
@property (nonatomic) BOOL neverShowPlaceholders;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)sync;
@end

// Weak set of comment/header cells currently on screen. Only consulted when a
// model-update notification arrives, so the bookkeeping cost is two hash-table
// ops per cell appearance.
static NSHashTable *sApolloVFVisibleCells = nil;

static void ApolloVFTrackCell(id cell, BOOL visible) {
    if (!sApolloVFVisibleCells) sApolloVFVisibleCells = [NSHashTable weakObjectsHashTable];
    if (visible) [sApolloVFVisibleCells addObject:cell];
    else [sApolloVFVisibleCells removeObject:cell];
}

static id ApolloVFIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
}

static NSString *ApolloVFFullName(id model) {
    if (!model || ![model respondsToSelector:@selector(fullName)]) return nil;
    @try {
        NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(model, @selector(fullName));
        return [fn isKindOfClass:[NSString class]] ? fn : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// The visible cell(s) whose model matches the updated one. A vote updates
// exactly one comment; matching by fullname keeps this surgical even when the
// notification fires for unrelated model updates.
static NSArray *ApolloVFCellsForUpdatedModel(id note) {
    id model = [note isKindOfClass:[NSNotification class]] ? [(NSNotification *)note object] : nil;
    NSString *fullName = ApolloVFFullName(model);
    if (fullName.length == 0) return @[];
    NSMutableArray *hits = [NSMutableArray array];
    for (id cell in sApolloVFVisibleCells.allObjects) {
        id m = ApolloVFIvar(cell, "comment") ?: ApolloVFIvar(cell, "link");
        if ([ApolloVFFullName(m) isEqualToString:fullName]) [hits addObject:cell];
    }
    return hits;
}

static void ApolloVFEnsureSynchronousDisplay(NSArray *cells, const char *stage) {
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
            if ([cell respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
                [cell recursivelyEnsureDisplaySynchronously:YES];
            }
        } @catch (__unused NSException *e) {}
    }
    if (cells.count > 0) {
        ApolloLog(@"[VoteFlicker] ensured synchronous display for %lu cell(s) (%s)",
                  (unsigned long)cells.count, stage);
    }
}

// Shared handler body for both section-controller hooks: arm the matching
// visible cell(s) before the reconfigure, flush the display wave right after,
// and once more on the next runloop turn (the -setNeedsLayout relayout lands
// there; its re-displays are what commit blank without this).
static void ApolloVFHandleModelUpdate(id note, void (^origCall)(void)) {
    NSArray *cells = ApolloVFCellsForUpdatedModel(note);
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
        } @catch (__unused NSException *e) {}
    }
    origCall();
    if (cells.count == 0) return;
    ApolloVFEnsureSynchronousDisplay(cells, "post-reconfigure");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloVFEnsureSynchronousDisplay(cells, "next-turn");
    });
}

%hook _TtC6Apollo15CommentCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

%hook _TtC6Apollo24CommentSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    ApolloVFHandleModelUpdate(note, ^{ %orig; });
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    ApolloVFHandleModelUpdate(note, ^{ %orig; });
}
%end
