#import "ApolloBarkNotifications.h"
#import "ApolloCommon.h"
#import "ApolloNotificationBackend.h"
#import "ApolloPushNotifications.h"
#import "UserDefaultConstants.h"

#import <Security/Security.h>

// Cached config, mirroring ApolloNotificationBackend.m: NSURL/NSNumber are
// immutable so reads from any queue are safe; the cache is rebuilt lazily
// after NSUserDefaultsDidChangeNotification.
static NSURL *sCachedBarkPushURL = nil;
static BOOL sCachedBarkEnabled = NO;
static BOOL sBarkCacheValid = NO;

static NSURL *ApolloParseBarkPushURLFromDefaults(void) {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkPushURL];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return nil;

    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (trimmed.length == 0) return nil;

    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    if (url.host.length == 0) return nil;
    return url;
}

static void ApolloInvalidateBarkCache(void) {
    sBarkCacheValid = NO;
    sCachedBarkPushURL = nil;
    sCachedBarkEnabled = NO;
}

static void ApolloEnsureBarkCacheValid(void) {
    if (sBarkCacheValid) return;
    sCachedBarkEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBarkNotificationsEnabled];
    sCachedBarkPushURL = ApolloParseBarkPushURLFromDefaults();
    sBarkCacheValid = YES;
}

__attribute__((constructor))
static void ApolloBarkNotificationsInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull __unused note) {
        ApolloInvalidateBarkCache();
    }];
}

BOOL ApolloBarkConfigured(void) {
    ApolloEnsureBarkCacheValid();
    return sCachedBarkEnabled && sCachedBarkPushURL != nil;
}

NSURL *ApolloBarkPushURL(void) {
    ApolloEnsureBarkCacheValid();
    return sCachedBarkPushURL;
}

BOOL ApolloBarkModeActive(void) {
    // Deliberately entitlement-agnostic: Bark is an explicit user choice on
    // any build. Without a push entitlement it's the only delivery path (the
    // synthetic-token flow); with one, the real APNs token registers with
    // transport=bark and the backend flips the same device row between
    // transports on re-registration.
    return ApolloBarkConfigured()
        && ApolloIsNotificationBackendConfigured();
}

// MARK: - Synthetic device token

NSString *ApolloBarkSyntheticTokenHex(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *existing = [defaults stringForKey:UDKeyBarkSyntheticDeviceToken];
    if ([existing isKindOfClass:[NSString class]] && existing.length == 64) {
        return existing.lowercaseString;
    }

    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        // arc4random_buf never fails; only reachable if SecRandom does.
        arc4random_buf(bytes, sizeof(bytes));
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    [defaults setObject:hex forKey:UDKeyBarkSyntheticDeviceToken];
    ApolloLog(@"[Bark] Generated synthetic device token %@…", [hex substringToIndex:8]);
    return hex;
}

NSData *ApolloBarkSyntheticTokenData(void) {
    NSString *hex = ApolloBarkSyntheticTokenHex();
    if (hex.length != 64) return nil;

    NSMutableData *data = [NSMutableData dataWithCapacity:32];
    for (NSUInteger i = 0; i < 64; i += 2) {
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&byte]) {
            // Malformed persisted value — drop it so the next call regenerates.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyBarkSyntheticDeviceToken];
            return nil;
        }
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

// MARK: - Client-side test push

void ApolloBarkSendTestNotification(void (^completion)(BOOL ok, NSString *message)) {
    NSURL *pushURL = ApolloBarkPushURL();
    if (!pushURL) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"No valid Bark push URL is set.");
            });
        }
        return;
    }

    NSDictionary *body = @{
        @"title": @"Apollo Reborn",
        @"body": @"Bark delivery works! Notifications from your backend will arrive like this one.",
        @"url": @"apollo://reborn/settings",
        @"group": @"apollo",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:pushURL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    request.timeoutInterval = 10;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        NSString *message = nil;
        if (error) {
            message = [NSString stringWithFormat:@"Could not reach the Bark server: %@", error.localizedDescription];
        } else {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            // bark-server answers {"code":200} on success; a 200 with a
            // non-200 code (e.g. bad device key) is still a failure.
            NSInteger barkCode = 0;
            NSString *barkMessage = nil;
            if (data.length > 0) {
                NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    barkCode = [parsed[@"code"] respondsToSelector:@selector(integerValue)] ? [parsed[@"code"] integerValue] : 0;
                    barkMessage = [parsed[@"message"] isKindOfClass:[NSString class]] ? parsed[@"message"] : nil;
                }
            }
            if (status == 200 && barkCode == 200) {
                ok = YES;
                message = @"Test notification sent — check for a Bark notification, then tap it to reopen Apollo.";
            } else {
                message = [NSString stringWithFormat:@"Bark server answered HTTP %ld%@%@. Check the push URL / device key.",
                           (long)status,
                           barkMessage ? @": " : @"",
                           barkMessage ?: @""];
            }
        }
        ApolloLog(@"[Bark] Test notification result ok=%d message=%@", ok, message);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, message);
            });
        }
    }] resume];
}

// MARK: - Direct transport sync

void ApolloBarkSyncBackendDeviceTransport(void) {
    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) return;

    // The device's backend identity: the token from the most recent
    // registration Apollo completed (real APNs token on entitled builds, the
    // synthetic one on free sideloads — stashed by the didRegister hook). A
    // free sideload that hasn't registered yet falls back to the synthetic
    // token it WILL register with, so the row it creates stays valid.
    NSString *tokenHex = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyLastDeviceTokenHex];
    if (tokenHex.length == 0 && !ApolloPushNotificationsSupported()) {
        tokenHex = ApolloBarkSyntheticTokenHex();
    }
    if (tokenHex.length == 0) {
        // Entitled build that has never registered this install — there is no
        // device row to flip; Apollo's next registration carries the current
        // transport in its headers anyway.
        ApolloLog(@"[Bark] Transport sync skipped — no device registration seen yet; the current mode applies when Apollo next registers.");
        return;
    }

    BOOL bark = ApolloBarkModeActive();
    // Body matches the stock client's shape ({"apnsToken","sandbox"} — the
    // backend's Go decoder matches field names case-insensitively). sandbox
    // reflects this build's actual aps-environment ("development" profile =
    // sandbox APNs gateway); the backend's APPLE_APNS_SANDBOX still overrides
    // it, same as for Apollo's own registrations.
    NSDictionary *body = @{
        @"apnsToken": tokenHex,
        @"sandbox": @(ApolloAPSEnvironmentIsDevelopment()),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!json) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[base URLByAppendingPathComponent:@"v1/device"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    request.timeoutInterval = 10;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *registrationToken = ApolloNotificationBackendRegistrationToken();
    if (registrationToken.length > 0) {
        [request setValue:registrationToken forHTTPHeaderField:@"X-Registration-Token"];
    }
    // Same authoritative transport channel the rewrite layer uses for
    // Apollo's own registrations (headers win over the body server-side).
    [request setValue:(bark ? @"bark" : @"apns") forHTTPHeaderField:@"X-Apollo-Transport"];
    if (bark) {
        [request setValue:ApolloBarkPushURL().absoluteString forHTTPHeaderField:@"X-Apollo-Transport-Endpoint"];
    }

    NSString *prefix = [tokenHex substringToIndex:MIN((NSUInteger)8, tokenHex.length)];
    ApolloLog(@"[Bark] Syncing backend device %@… to transport=%@", prefix, bark ? @"bark" : @"apns");
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData * __unused data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[Bark] Transport sync failed: %@", error.localizedDescription);
        } else {
            ApolloLog(@"[Bark] Transport sync answered HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]);
        }
    }] resume];
}

// MARK: - Backend device cleanup

void ApolloBarkDeleteBackendDevice(NSString *tokenHex) {
    if (tokenHex.length == 0) return;
    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) return;

    NSURL *url = [base URLByAppendingPathComponent:[NSString stringWithFormat:@"v1/device/%@", tokenHex]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"DELETE";
    request.timeoutInterval = 10;

    ApolloLog(@"[Bark] Deleting backend device registration %@…", [tokenHex substringToIndex:MIN((NSUInteger)8, tokenHex.length)]);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData * __unused data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[Bark] Backend device delete failed: %@", error.localizedDescription);
        } else {
            ApolloLog(@"[Bark] Backend device delete answered HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]);
        }
    }] resume];
}
