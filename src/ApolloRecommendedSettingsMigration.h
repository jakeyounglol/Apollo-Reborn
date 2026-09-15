#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloRecommendedSettingsMigrationVersionKey;
FOUNDATION_EXPORT NSInteger const ApolloRecommendedSettingsMigrationVersion;

/// Applies the Boneman recommended settings exactly once for each preferences
/// container. Credential stores and unrelated preferences are never enumerated
/// or rewritten.
#ifdef __cplusplus
extern "C" {
#endif
void ApolloApplyRecommendedSettingsMigration(NSUserDefaults *defaults);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
