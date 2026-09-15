#import <Foundation/Foundation.h>

#import "ApolloNotificationBackendPath.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"NotificationBackendPathTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

static void RequireEqual(NSString *actual, NSString *expected, NSString *message) {
    Require((actual == nil && expected == nil) || [actual isEqualToString:expected], message);
}

static void TestRepairsAccountScopedNotificationPaths(void) {
    NSArray<NSDictionary<NSString *, NSString *> *> *cases = @[
        @{@"method": @"GET", @"input": @"/v1/device/device-token/account//notifications", @"expected": @"/v1/device/device-token/account/1a2b3/notifications"},
        @{@"method": @"PATCH", @"input": @"/v1/device/device-token/account//notifications", @"expected": @"/v1/device/device-token/account/1a2b3/notifications"},
        @{@"method": @"POST", @"input": @"/v1/device/device-token/account//watcher", @"expected": @"/v1/device/device-token/account/1a2b3/watcher"},
        @{@"method": @"DELETE", @"input": @"/v1/device/device-token/account//watcher/42", @"expected": @"/v1/device/device-token/account/1a2b3/watcher/42"},
        @{@"method": @"PATCH", @"input": @"/v1/device/device-token/account//watcher/42", @"expected": @"/v1/device/device-token/account/1a2b3/watcher/42"},
        @{@"method": @"GET", @"input": @"/v1/device/device-token/account//watchers", @"expected": @"/v1/device/device-token/account/1a2b3/watchers"},
    ];

    for (NSDictionary<NSString *, NSString *> *testCase in cases) {
        RequireEqual(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(
                         testCase[@"input"], testCase[@"method"], @"1a2b3"),
                     testCase[@"expected"],
                     [@"repairs " stringByAppendingString:testCase[@"input"]]);
    }
}

static void TestPreservesUnaffectedPaths(void) {
    NSArray<NSString *> *paths = @[
        @"/v1/device/device-token/account/1a2b3/notifications",
        @"/v1/device//test",
        @"/api/req_v2",
    ];

    for (NSString *path in paths) {
        RequireEqual(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", nil),
                     path,
                     [@"preserves " stringByAppendingString:path]);
    }
}

static void TestFailsClosedWithoutAValidIdentifier(void) {
    NSString *path = @"/v1/device/device-token/account//notifications";
    NSArray *invalidIdentifiers = @[
        @"",
        @"abc",
        @"abcdefghij",
        @"abc-1",
        @"abc_1",
        @"abc/1",
        @"abc 1",
        @"abcé1",
    ];

    Require(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", nil) == nil,
            @"missing identifier fails closed");
    for (NSString *identifier in invalidIdentifiers) {
        Require(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", identifier) == nil,
                [@"invalid identifier fails closed: " stringByAppendingString:identifier]);
    }
}

static void TestAcceptsIdentifierBoundaries(void) {
    NSString *path = @"/v1/device/device-token/account//watchers";
    RequireEqual(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", @"a1b2"),
                 @"/v1/device/device-token/account/a1b2/watchers",
                 @"four-character base36 identifier is accepted");
    RequireEqual(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", @"123abc789"),
                 @"/v1/device/device-token/account/123abc789/watchers",
                 @"nine-character base36 identifier is accepted");
    RequireEqual(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(path, @"GET", @"AB12"),
                 @"/v1/device/device-token/account/AB12/watchers",
                 @"uppercase ASCII base36 identifier is accepted");
}

static void TestPreservesQueryAndFragmentWhenAppliedToURLComponents(void) {
    NSURLComponents *components = [NSURLComponents componentsWithString:
        @"https://example.test/v1/device/device-token/account//notifications?cursor=a%2Fb#section"];
    NSString *repaired = ApolloNotificationBackendPathByRepairingEmptyAccountComponent(
        components.percentEncodedPath,
        @"GET",
        @"1a2b3"
    );
    Require(repaired != nil, @"URL path repair succeeds");
    components.percentEncodedPath = repaired;
    RequireEqual(components.URL.absoluteString,
                 @"https://example.test/v1/device/device-token/account/1a2b3/notifications?cursor=a%2Fb#section",
                 @"query and fragment remain byte-for-byte intact");
}

static void TestRejectsUnsupportedMalformedRoutes(void) {
    NSArray<NSDictionary<NSString *, NSString *> *> *cases = @[
        @{@"method": @"POST", @"path": @"/v1/device/device-token/account//notifications"},
        @{@"method": @"DELETE", @"path": @"/v1/device/device-token/account//watchers"},
        @{@"method": @"GET", @"path": @"/v1/device/device-token/account//watcher"},
        @{@"method": @"GET", @"path": @"/foo/account//notifications"},
        @{@"method": @"GET", @"path": @"/v1/device//account//notifications"},
        @{@"method": @"GET", @"path": @"/v1/device/device-token/account///notifications"},
        @{@"method": @"GET", @"path": @"/v1/device/device-token/account//notifications/"},
        @{@"method": @"GET", @"path": @"/v1/device/device-token/account//notifications/extra"},
        @{@"method": @"DELETE", @"path": @"/v1/device/device-token/account//watcher/not-a-number"},
        @{@"method": @"GET", @"path": @"/v1/device/device%2Ftoken/account//notifications"},
        @{@"method": @"GET", @"path": @"/v1/device/device%5Ctoken/account//notifications"},
        @{@"method": @"GET", @"path": @"/v1/device/device-token/account//notifications/account//watchers"},
    ];

    for (NSDictionary<NSString *, NSString *> *testCase in cases) {
        Require(ApolloNotificationBackendPathByRepairingEmptyAccountComponent(
                    testCase[@"path"], testCase[@"method"], @"1a2b3") == nil,
                [@"unsupported malformed route fails closed: " stringByAppendingString:testCase[@"path"]]);
    }
}

int main(void) {
    @autoreleasepool {
        TestRepairsAccountScopedNotificationPaths();
        TestPreservesUnaffectedPaths();
        TestFailsClosedWithoutAValidIdentifier();
        TestAcceptsIdentifierBoundaries();
        TestPreservesQueryAndFragmentWhenAppliedToURLComponents();
        TestRejectsUnsupportedMalformedRoutes();
        NSLog(@"notification_backend_path_tests passed");
    }
    return 0;
}
