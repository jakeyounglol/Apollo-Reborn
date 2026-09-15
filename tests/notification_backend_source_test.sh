#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$repo_root/src/ApolloNotificationBackend.m"

fail() {
    printf 'notification_backend_source_test: %s\n' "$1" >&2
    exit 1
}

# Every request that reaches the rewrite routine has already passed the legacy
# host and configured-backend checks. The token block must therefore occur
# outside the POST-only compatibility block, making it universal for DELETE,
# PATCH, GET, receipt, and diagnostic rewrites while preserving the existing
# POST-only body augmentation below.
token_line=$(awk '/if \(sCachedRegistrationToken\.length > 0\)/ { print NR; exit }' "$source_file")
path_repair_line=$(awk '/ApolloNotificationBackendPathByRepairingEmptyAccountComponent\(/ { print NR; exit }' "$source_file")
rewritten_url_line=$(awk '/mutable\.URL = rewrittenURL;/ { print NR; exit }' "$source_file")
method_line=$(awk '/NSString \*method = request\.HTTPMethod\.uppercaseString/ { print NR; exit }' "$source_file")
post_augmentation_line=$(awk '/if \(\[method isEqualToString:@"POST"\]\)/ { print NR; exit }' "$source_file")

[ -n "$token_line" ] || fail 'missing configured-token guard'
[ -n "$path_repair_line" ] || fail 'missing empty-account path repair'
[ -n "$rewritten_url_line" ] || fail 'missing rewritten request assignment'
[ -n "$method_line" ] || fail 'missing request method handling'
[ -n "$post_augmentation_line" ] || fail 'missing POST body augmentation guard'
[ "$method_line" -lt "$path_repair_line" ] || fail 'request method is unavailable to the route-scoped account repair'
[ "$path_repair_line" -lt "$rewritten_url_line" ] || fail 'account path is repaired after the rewritten request is constructed'
[ "$rewritten_url_line" -lt "$token_line" ] || fail 'token can be added to a request that was not rewritten'
[ "$token_line" -lt "$post_augmentation_line" ] || fail 'token injection occurs after POST-only compatibility work'

header_write_count=$(grep -Fc '[mutable setValue:sCachedRegistrationToken forHTTPHeaderField:@"X-Registration-Token"];' "$source_file" || true)
[ "$header_write_count" -eq 1 ] || fail 'configured token is not written exactly once inside the universal rewrite path'

if grep -Fq 'ApolloPathRequiresRegistrationToken' "$source_file"; then
    fail 'obsolete registration-route token classifier still restricts authentication'
fi

grep -Fq 'ApolloActiveAccountClient()' "$source_file" || fail 'repair does not resolve Apollo live active account client'
grep -Fq 'valueForKey:@"currentUser"' "$source_file" || fail 'repair does not read the active client currentUser'
grep -Fq 'valueForKey:@"identifier"' "$source_file" || fail 'repair does not read the Reddit account identifier'
if grep -Fq 'ApolloActiveAccountUsername()' "$source_file"; then
    fail 'repair incorrectly substitutes the Reddit username for the account identifier'
fi
if grep -Fq 'requestURL.absoluteString, rewrittenURL.absoluteString' "$source_file"; then
    fail 'rewrite diagnostic leaks account/device path values'
fi

# The length guard is the explicit unset-token behavior: no header write occurs
# when the setting is empty. Because the guarded write is outside the POST-only
# compatibility block, it covers DELETE, PATCH, GET, and diagnostic rewrites.

printf 'notification_backend_source_test passed\n'
