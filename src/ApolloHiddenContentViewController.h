#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

// Sheet-presented results list for the "Hidden & Deleted Posts/Comments" feature.
// Presents its own UINavigationController; call +presentForUsername:fromViewController:
// rather than instantiating directly.
@interface ApolloHiddenContentViewController : UITableViewController
+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter;
@end
