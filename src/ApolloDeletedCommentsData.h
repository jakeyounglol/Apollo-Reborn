#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const ApolloDeletedCommentsObservedThreadNotification;

typedef void (^ApolloDeletedCommentsURLSessionCompletion)(NSData *data, NSURLResponse *response, NSError *error);

void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source);
ApolloDeletedCommentsURLSessionCompletion ApolloDeletedCommentsMaybeWrapCompletion(NSURLRequest *request, ApolloDeletedCommentsURLSessionCompletion completion);
void ApolloDeletedCommentsInstallDelegateTransformerIfNeeded(NSURLSession *session, NSURLRequest *request);

#ifdef APOLLO_DELETED_COMMENTS_TESTING
NSString *ApolloDeletedCommentsTestLinkFullNameFromRedditURL(NSURL *url);
BOOL ApolloDeletedCommentsTestBodyLooksDeleted(NSString *body, NSString *bodyHTML);
NSUInteger ApolloDeletedCommentsTestPatchRedditJSONRoot(id root, NSDictionary<NSString *, NSDictionary *> *archivedComments);
#endif

#ifdef __cplusplus
}
#endif
