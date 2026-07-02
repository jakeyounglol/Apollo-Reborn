#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Bark notification delivery for free-account sideloads
//
// A build signed with a free Apple ID has no `aps-environment` entitlement,
// so APNs delivery can never work (see ApolloPushNotifications.h). Bark mode
// works around the missing *delivery* hop while reusing everything else:
//
//   1. The user installs the free "Bark - Custom Notifications" App Store app
//      and pastes its push URL (https://api.day.app/<device_key>) into
//      Settings > General > Custom API.
//   2. When Apollo's APNs registration fails with the entitlement error, the
//      tweak calls Apollo's own didRegisterForRemoteNotificationsWithDeviceToken:
//      with a synthetic 64-hex token — Apollo's entire native registration,
//      notification-settings, and watcher UI then works unmodified, with all
//      requests rewritten to the self-hosted backend as usual.
//   3. The rewrite layer augments POST /v1/device with transport=bark and the
//      Bark push URL; the backend POSTs each notification to Bark with an
//      apollo:// deep link that opens Apollo when the notification is tapped.

// YES when the Bark toggle is on and the push URL parses as http(s) with a
// host. Says nothing about entitlements or the backend — see
// ApolloBarkModeActive() for the full gate.
BOOL ApolloBarkConfigured(void);

// The full gate for every Bark behavior: configured (above) AND this build
// cannot receive real push (no aps-environment) AND a notification backend
// URL is set (without one there is nothing to register against). Never YES on
// a paid-cert build, so the stock APNs flow is untouched there.
BOOL ApolloBarkModeActive(void);

// Parsed Bark push URL from defaults (trimmed, trailing slashes dropped), or
// nil. Cached; invalidated on NSUserDefaultsDidChangeNotification.
NSURL *ApolloBarkPushURL(void);

// The persistent synthetic device token as a lowercase 64-hex string.
// Generated on first use (32 bytes via SecRandomCopyBytes) and stored in
// standard defaults. This is the device's identity on the backend — it
// appears in every /v1/device/{apns}/... path.
NSString *ApolloBarkSyntheticTokenHex(void);

// The same token as the raw 32 bytes, for feeding Apollo's
// didRegisterForRemoteNotificationsWithDeviceToken:. Apollo hex-encodes the
// NSData, round-tripping to exactly ApolloBarkSyntheticTokenHex(). Returns
// nil if the persisted hex is malformed (regenerates on next call).
NSData *ApolloBarkSyntheticTokenData(void);

// Client-side test: POSTs a hello notification (with an apollo:// click URL)
// directly to the Bark push URL, bypassing the backend, so the user can
// verify their Bark app + key before registration. Completion on main queue;
// `message` is suitable for a UIAlertController.
void ApolloBarkSendTestNotification(void (^completion)(BOOL ok, NSString *message));

// Fire-and-forget DELETE {backend}/v1/device/{tokenHex} — used when Bark is
// toggled off, and when a real APNs token replaces the synthetic one (paid
// re-sign), so the backend stops pushing to the stale Bark registration.
// No-op when no backend is configured or tokenHex is empty.
void ApolloBarkDeleteBackendDevice(NSString *tokenHex);

#ifdef __cplusplus
}
#endif
