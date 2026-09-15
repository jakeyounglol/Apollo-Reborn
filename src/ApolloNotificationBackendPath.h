#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns percentEncodedPath unchanged when it has no literal `/account//`
// component. For the exact notification/watcher route shapes and methods the
// backend supports, fills that empty component from accountIdentifier. Returns
// nil when a malformed component is present but the route/method is unsupported
// or the identifier is not a 4-9 character ASCII base36 value.
FOUNDATION_EXPORT NSString * _Nullable ApolloNotificationBackendPathByRepairingEmptyAccountComponent(
    NSString *percentEncodedPath,
    NSString *HTTPMethod,
    NSString * _Nullable accountIdentifier
);

NS_ASSUME_NONNULL_END
