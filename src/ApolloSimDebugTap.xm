// Simulator-only debug bridge: synthesize a real UITouch tap inside the app.
//
// idb_companion 1.1.8's HID events are silently dropped by Xcode 27's iOS-27
// simulators, so there is currently no external way to tap the sim from
// scripts. This module lets the host drive taps through the injected tweak
// instead: write "x y" (screen points) to /tmp/apollofix-tap.txt, then post
// the Darwin notification:
//
//   echo "200 560" > /tmp/apollofix-tap.txt
//   xcrun simctl spawn <UDID> notifyutil -p apollofix.debugtap
//
// The synthesized touch goes through -[UIApplication sendEvent:], so it
// exercises genuine hit-testing, responder-chain bubbling, gesture
// recognizers, and ASControlNode tracking — unlike calling handlers directly.
// Never compiled into device builds.
#if APOLLO_SIM_BUILD

#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
#import <objc/message.h>

@interface UITouch (ApolloSimDebugTap)
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)first;
@end

@interface UIEvent (ApolloSimDebugTap)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@interface UIApplication (ApolloSimDebugTap)
- (UIEvent *)_touchesEvent;
@end

static NSString *const kApolloSimTapFile = @"/tmp/apollofix-tap.txt";

static void ApolloSimDebugSendTouch(UITouch *touch) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_touchesEvent)]) return;
    UIEvent *event = [app _touchesEvent];
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    if ([event respondsToSelector:@selector(_setTimestamp:)]) {
        [event _setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    [event _clearTouches];
    [event _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:event];
}

static void ApolloSimDebugPerformTap(CGPoint point) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for (%.0f, %.0f)", point.x, point.y);
        return;
    }
    ApolloLog(@"[SimDebugTap] tapping (%.0f, %.0f) hit=%@", point.x, point.y,
              NSStringFromClass(hitView.class));

    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) {
        ApolloLog(@"[SimDebugTap] UITouch private setters unavailable on this runtime");
        return;
    }
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] tap delivered");
    });
}

static UIResponder *ApolloSimDebugFirstResponder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *responder = ApolloSimDebugFirstResponder(subview);
        if (responder) return responder;
    }
    return nil;
}

// "text <string>" command: insert into the focused field through UIKeyInput,
// which fires the same editing events as typing.
static void ApolloSimDebugTypeText(NSString *text) {
    UIResponder *responder = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        responder = ApolloSimDebugFirstResponder(window);
        if (responder) break;
    }
    if (![responder conformsToProtocol:@protocol(UIKeyInput)]) {
        ApolloLog(@"[SimDebugTap] no key-input first responder for text command");
        return;
    }
    [(id<UIKeyInput>)responder insertText:text];
    ApolloLog(@"[SimDebugTap] typed %lu chars into %@",
              (unsigned long)text.length, NSStringFromClass(responder.class));
}

static void ApolloSimDebugTapNotification(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *contents = [NSString stringWithContentsOfFile:kApolloSimTapFile
                                                       encoding:NSUTF8StringEncoding error:nil];
        if ([contents hasPrefix:@"text "]) {
            NSString *payload = [[contents substringFromIndex:5] stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            ApolloSimDebugTypeText(payload);
            return;
        }
        NSArray<NSString *> *parts = [contents componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray<NSString *> *numbers = [NSMutableArray array];
        for (NSString *part in parts) if (part.length > 0) [numbers addObject:part];
        if (numbers.count < 2) {
            ApolloLog(@"[SimDebugTap] malformed tap file: %@", contents ?: @"(missing)");
            return;
        }
        ApolloSimDebugPerformTap(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue));
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        ApolloSimDebugTapNotification, CFSTR("apollofix.debugtap"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ApolloLog(@"[SimDebugTap] listening for apollofix.debugtap");
}

#endif
