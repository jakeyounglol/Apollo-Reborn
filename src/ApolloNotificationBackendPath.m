#import "ApolloNotificationBackendPath.h"

static BOOL ApolloNotificationBackendAccountIdentifierIsValid(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length < 4 || identifier.length > 9) {
        return NO;
    }

    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar character = [identifier characterAtIndex:index];
        BOOL isDigit = character >= '0' && character <= '9';
        BOOL isLowercaseLetter = character >= 'a' && character <= 'z';
        BOOL isUppercaseLetter = character >= 'A' && character <= 'Z';
        if (!isDigit && !isLowercaseLetter && !isUppercaseLetter) {
            return NO;
        }
    }
    return YES;
}

static BOOL ApolloNotificationBackendWatcherIdentifierIsValid(NSString *identifier) {
    if (identifier.length == 0) return NO;
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar character = [identifier characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
    }
    return YES;
}

static BOOL ApolloNotificationBackendMalformedRouteIsSupported(NSArray<NSString *> *parts,
                                                                NSString *HTTPMethod) {
    if (parts.count < 7
        || ![parts[0] isEqualToString:@""]
        || ![parts[1] isEqualToString:@"v1"]
        || ![parts[2] isEqualToString:@"device"]
        || parts[3].length == 0
        || ![parts[4] isEqualToString:@"account"]
        || parts[5].length != 0) {
        return NO;
    }

    NSString *method = HTTPMethod.uppercaseString;
    if (parts.count == 7 && [parts[6] isEqualToString:@"notifications"]) {
        return [method isEqualToString:@"GET"] || [method isEqualToString:@"PATCH"];
    }
    if (parts.count == 7 && [parts[6] isEqualToString:@"watchers"]) {
        return [method isEqualToString:@"GET"];
    }
    if (parts.count == 7 && [parts[6] isEqualToString:@"watcher"]) {
        return [method isEqualToString:@"POST"];
    }
    if (parts.count == 8
        && [parts[6] isEqualToString:@"watcher"]
        && ApolloNotificationBackendWatcherIdentifierIsValid(parts[7])) {
        return [method isEqualToString:@"DELETE"] || [method isEqualToString:@"PATCH"];
    }
    return NO;
}

NSString *ApolloNotificationBackendPathByRepairingEmptyAccountComponent(
    NSString *percentEncodedPath,
    NSString *HTTPMethod,
    NSString * _Nullable accountIdentifier
) {
    NSRange malformedComponent = [percentEncodedPath rangeOfString:@"/account//"];
    if (malformedComponent.location == NSNotFound) {
        return percentEncodedPath;
    }
    NSString *lowercasePath = percentEncodedPath.lowercaseString;
    if ([lowercasePath containsString:@"%2f"] || [lowercasePath containsString:@"%5c"]) {
        return nil;
    }

    NSMutableArray<NSString *> *parts = [[percentEncodedPath componentsSeparatedByString:@"/"] mutableCopy];
    if (!ApolloNotificationBackendMalformedRouteIsSupported(parts, HTTPMethod)) {
        return nil;
    }
    if (!ApolloNotificationBackendAccountIdentifierIsValid(accountIdentifier)) {
        return nil;
    }

    parts[5] = accountIdentifier;
    return [parts componentsJoinedByString:@"/"];
}
