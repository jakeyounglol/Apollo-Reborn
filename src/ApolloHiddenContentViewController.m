#import "ApolloHiddenContentViewController.h"
#import "ApolloCommon.h"

#pragma mark - Pill badge

// Plain UILabel cell accessory (not the Texture chip-image approach in
// ApolloDeletedCommentsUI.xm -- this is a plain UIKit table, no text node).
@interface ApolloHiddenContentPillLabel : UILabel
@end

@implementation ApolloHiddenContentPillLabel

- (instancetype)initWithText:(NSString *)text backgroundColor:(UIColor *)backgroundColor textColor:(UIColor *)textColor {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.text = text;
        self.font = [UIFont boldSystemFontOfSize:11.0];
        self.textColor = textColor;
        self.backgroundColor = backgroundColor;
        self.textAlignment = NSTextAlignmentCenter;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        [self sizeToFit];
        CGRect frame = self.frame;
        frame.size.width += 14.0;
        frame.size.height = 16.0;
        self.frame = frame;
    }
    return self;
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0, 7, 0, 7))];
}

@end

static UIColor *ApolloHiddenContentPillBackgroundColor(ApolloHiddenContentReason reason) {
    return reason == ApolloHiddenContentReasonDeleted
        ? [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0]   // salmon, matches deleted-comments chip
        : [UIColor colorWithRed:1.0 green:0.84 blue:0.55 alpha:1.0];  // amber, distinct "hidden" color
}

static UIColor *ApolloHiddenContentPillTextColor(ApolloHiddenContentReason reason) {
    return reason == ApolloHiddenContentReasonDeleted
        ? [UIColor colorWithRed:0.42 green:0.06 blue:0.06 alpha:1.0]
        : [UIColor colorWithRed:0.42 green:0.24 blue:0.02 alpha:1.0];
}

static NSString *ApolloHiddenContentPillLabelText(ApolloHiddenContentReason reason) {
    return reason == ApolloHiddenContentReasonDeleted ? @"DELETED" : @"HIDDEN";
}

#pragma mark - Cell

@interface ApolloHiddenContentCell : UITableViewCell
@end

@implementation ApolloHiddenContentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        self.textLabel.numberOfLines = 2;
        self.detailTextLabel.numberOfLines = 1;
        self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return self;
}

- (void)configureWithItem:(ApolloHiddenContentItem *)item {
    NSString *preview = item.title.length > 0 ? item.title : item.body;
    self.textLabel.text = preview.length > 0 ? preview : @"(no text)";

    NSMutableArray<NSString *> *subtitleParts = [NSMutableArray array];
    if (item.subreddit.length > 0) [subtitleParts addObject:[@"r/" stringByAppendingString:item.subreddit]];
    if (item.createdDate) {
        static NSDateFormatter *formatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterNoStyle;
        });
        [subtitleParts addObject:[formatter stringFromDate:item.createdDate]];
    }
    [subtitleParts addObject:item.kind == ApolloHiddenContentKindPost ? @"Post" : @"Comment"];
    self.detailTextLabel.text = [subtitleParts componentsJoinedByString:@" · "];

    self.accessoryView = [[ApolloHiddenContentPillLabel alloc] initWithText:ApolloHiddenContentPillLabelText(item.reason)
                                                              backgroundColor:ApolloHiddenContentPillBackgroundColor(item.reason)
                                                                    textColor:ApolloHiddenContentPillTextColor(item.reason)];
}

@end

#pragma mark - Deleted-item detail

// A deleted item has no live reddit.com page to open, so this shows the
// already-fetched archived title/body directly instead of a dead permalink.
@interface ApolloHiddenContentDetailViewController : UIViewController
@property (nonatomic, strong) ApolloHiddenContentItem *item;
@end

@implementation ApolloHiddenContentDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.item.kind == ApolloHiddenContentKindPost ? @"Deleted Post" : @"Deleted Comment";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                             target:self action:@selector(apollo_share)];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont systemFontOfSize:16.0];
    textView.textContainerInset = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    textView.text = [self apollo_archivedText];
    [self.view addSubview:textView];
}

- (NSString *)apollo_archivedText {
    NSMutableString *text = [NSMutableString string];
    if (self.item.subreddit.length > 0) [text appendFormat:@"r/%@\n\n", self.item.subreddit];
    if (self.item.title.length > 0) [text appendFormat:@"%@\n\n", self.item.title];
    [text appendString:self.item.body.length > 0 ? self.item.body : @"(no body text in the archive)"];
    return text;
}

- (void)apollo_share {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[self apollo_archivedText]]
                                                                             applicationActivities:nil];
    [self presentViewController:activity animated:YES completion:nil];
}

@end

#pragma mark - View controller

@interface ApolloHiddenContentViewController ()
@property (nonatomic, copy) NSString *username;
@property (nonatomic, assign) ApolloHiddenContentKind kind;
@property (nonatomic, copy) NSArray<ApolloHiddenContentItem *> *items;
@property (nonatomic, strong) UISegmentedControl *kindControl;
@property (nonatomic, strong) UIView *statusContainerView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@end

@implementation ApolloHiddenContentViewController

+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter {
    if (username.length == 0 || !presenter) return;
    ApolloHiddenContentViewController *sheet = [[ApolloHiddenContentViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    sheet.username = username;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sc = nav.sheetPresentationController;
        if (sc) {
            sc.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
            sc.prefersGrabberVisible = YES;
        }
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden & Deleted";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                             target:self action:@selector(apollo_close)];
    [self.tableView registerClass:[ApolloHiddenContentCell class] forCellReuseIdentifier:@"Cell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;

    self.kind = ApolloHiddenContentKindPost;
    self.kindControl = [[UISegmentedControl alloc] initWithItems:@[@"Posts", @"Comments"]];
    self.kindControl.selectedSegmentIndex = 0;
    [self.kindControl addTarget:self action:@selector(apollo_kindChanged) forControlEvents:UIControlEventValueChanged];
    self.kindControl.frame = CGRectMake(0, 0, 220, 32);
    self.navigationItem.titleView = self.kindControl;

    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(apollo_refreshTriggered) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    // tableView.backgroundView rather than a plain subview of self.view: it's a
    // fixed, non-scrolling layer UIKit keeps sized to the table view's bounds.
    self.statusContainerView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.statusContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundView = self.statusContainerView;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
        | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = CGPointMake(CGRectGetMidX(self.statusContainerView.bounds), CGRectGetMidY(self.statusContainerView.bounds));
    [self.statusContainerView addSubview:self.spinner];
    [self.spinner startAnimating];

    [self apollo_fetchForceRefresh:NO];
}

- (void)apollo_kindChanged {
    self.kind = self.kindControl.selectedSegmentIndex == 0 ? ApolloHiddenContentKindPost : ApolloHiddenContentKindComment;
    self.items = @[];
    [self.tableView reloadData];
    [self.emptyStateLabel removeFromSuperview];
    [self.spinner startAnimating];
    [self apollo_fetchForceRefresh:NO];
}

- (void)apollo_refreshTriggered {
    [self apollo_fetchForceRefresh:YES];
}

- (void)apollo_fetchForceRefresh:(BOOL)forceRefresh {
    [self.emptyStateLabel removeFromSuperview];
    ApolloHiddenContentKind requestedKind = self.kind;
    __weak __typeof(self) weakSelf = self;
    ApolloHiddenContentFetch(self.username, requestedKind, forceRefresh, ^(NSArray<ApolloHiddenContentItem *> *items, NSString *errorMessage) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // The user may have flipped the segmented control again while this
        // request was in flight -- don't clobber a newer selection's UI state.
        if (strongSelf.kind != requestedKind) return;
        [strongSelf.spinner stopAnimating];
        [strongSelf.tableView.refreshControl endRefreshing];
        if (errorMessage) {
            [strongSelf apollo_showError:errorMessage];
            return;
        }
        strongSelf.items = items ?: @[];
        [strongSelf.tableView reloadData];
        if (strongSelf.items.count == 0) {
            [strongSelf apollo_showEmptyState];
        }
    });
}

- (void)apollo_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Fetch Hidden Content"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak __typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf apollo_close];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)apollo_showEmptyState {
    if (!self.emptyStateLabel) {
        self.emptyStateLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.statusContainerView.bounds, 32.0, 0)];
        self.emptyStateLabel.numberOfLines = 0;
        self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
        self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
        self.emptyStateLabel.font = [UIFont systemFontOfSize:15.0];
        self.emptyStateLabel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
            | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    }
    NSString *kindName = self.kind == ApolloHiddenContentKindPost ? @"posts" : @"comments";
    self.emptyStateLabel.text = [NSString stringWithFormat:@"No hidden or deleted %@ found in the archive for this account.", kindName];
    self.emptyStateLabel.center = CGPointMake(CGRectGetMidX(self.statusContainerView.bounds), CGRectGetMidY(self.statusContainerView.bounds));
    [self.statusContainerView addSubview:self.emptyStateLabel];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloHiddenContentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    [cell configureWithItem:self.items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ApolloHiddenContentItem *item = self.items[indexPath.row];

    if (item.reason == ApolloHiddenContentReasonDeleted) {
        ApolloHiddenContentDetailViewController *detail = [ApolloHiddenContentDetailViewController new];
        detail.item = item;
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    // Route through the apollo:// scheme so it opens natively instead of
    // Safari. This screen is itself a modal sheet, so it dismisses first --
    // pushing while the sheet is still up would land the destination inside
    // the sheet's own nav stack instead of the app's normal one.
    if (item.permalink.length == 0) return;
    NSURL *url = [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:item.permalink]];
    if (!url) return;

    UINavigationController *presentingNav = self.navigationController;
    [presentingNav dismissViewControllerAnimated:YES completion:^{
        if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }];
}

@end
