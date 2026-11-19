//
//  WQGlobalSearch.m
//  WQ Glass Universal Spotlight Search Engine (iPhone Duo)
//  GPL-3.0-or-later.
//

#import "WQGlobalSearch.h"
#import "WQAccess.h"
#import "WQDir.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <sys/stat.h>

static NSString *const kWQGlobalSearchRecentsKey = @"WQGlobalSearchRecents";
static void (^gWQGlobalSearchCommandHandler)(NSString *commandID, UIViewController *host);

typedef NS_ENUM(NSInteger, WQSearchCategory) {
    WQSearchCategoryRecent = 0,
    WQSearchCategoryCommand,
    WQSearchCategoryApp,
    WQSearchCategoryFile,
    WQSearchCategoryCacheOrBackup,
};

@interface WQSpotlightResult : NSObject
@property (nonatomic) WQSearchCategory category;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *detailBadge;
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *commandID;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic) BOOL isDirectory;
@end

@implementation WQSpotlightResult
@end

@interface WQSpotlightCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *sizeLabel;
@end

@implementation WQSpotlightCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.clipsToBounds = YES;
        self.contentView.clipsToBounds = YES;
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8.0;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = wq_theme_primary_text();
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = wq_theme_secondary_text();
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _sizeLabel.textColor = wq_theme_detail_text();
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        for (UIView *v in @[_iconView, _titleLabel, _subtitleLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:34],
            [_iconView.heightAnchor constraintEqualToConstant:34],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9],
        ]];
    }
    return self;
}

@end

static NSArray<NSString *> *wq_spotlight_recents(void)
{
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kWQGlobalSearchRecentsKey];
    if (![saved isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *clean = [NSMutableArray new];
    for (id item in saved) {
        if ([item isKindOfClass:NSString.class] && [(NSString *)item length] > 0) [clean addObject:item];
    }
    return clean;
}

static void wq_spotlight_save_recent(NSString *query)
{
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length < 2) return;
    NSMutableArray<NSString *> *list = [wq_spotlight_recents() mutableCopy];
    [list removeObject:trimmed];
    [list insertObject:trimmed atIndex:0];
    while (list.count > 8) [list removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kWQGlobalSearchRecentsKey];
}

static NSArray<WQSpotlightResult *> *wq_spotlight_quick_commands(void)
{
    NSArray<NSArray<NSString *> *> *specs = @[
        @[@"Run Full Scan", @"Scan containers & permissions", @"arrow.triangle.2.circlepath", @"full_scan"],
        @[@"Quick Health Check", @"Verify sandbox access status", @"checkmark.shield.fill", @"quick_check"],
        @[@"Clean Selected Caches", @"Open Cache Cleaner to free space", @"sparkles", @"clean_caches"],
        @[@"Open Backups Vault", @"App backups, file backups & deleted", @"clock.arrow.circlepath", @"open_vault"],
        @[@"View System Logs", @"Inspect diagnostic activity log", @"doc.plaintext", @"open_logs"],
        @[@"Jump to Path", @"Navigate directly to any path", @"arrow.forward.circle", @"jump_path"],
    ];
    NSMutableArray<WQSpotlightResult *> *out = [NSMutableArray new];
    for (NSArray<NSString *> *s in specs) {
        WQSpotlightResult *r = [WQSpotlightResult new];
        r.category = WQSearchCategoryCommand;
        r.title = WQLocalized(s[0]);
        r.subtitle = WQLocalized(s[1]);
        r.symbolName = s[2];
        r.commandID = s[3];
        r.detailBadge = @"CMD";
        [out addObject:r];
    }
    return out;
}

// Cached app index so live typing stays instantaneous.
static NSMutableArray<WQSpotlightResult *> *gWQSpotlightAppCache;
static BOOL gWQSpotlightIndexWarm;

static void wq_spotlight_warm_apps_on_io(void)
{
    if (gWQSpotlightIndexWarm) return;
    gWQSpotlightIndexWarm = YES;
    if (!wq_display_names_loaded()) wq_load_display_names();
    NSMutableArray<WQSpotlightResult *> *apps = [NSMutableArray new];
    NSArray<NSString *> *roots = @[
        @"/private/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin",
    ];
    for (NSString *root in roots) {
        NSArray<NSString *> *containers = wq_enumerate(root, 0, nil, nil);
        for (NSString *c in containers) {
            NSString *bid = wq_container_label(c);
            NSString *name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
            WQSpotlightResult *item = [WQSpotlightResult new];
            item.category = WQSearchCategoryApp;
            item.title = name;
            item.subtitle = bid ?: c.lastPathComponent;
            item.path = c;
            item.bundleID = bid;
            item.symbolName = @"app.dashed";
            item.isDirectory = YES;
            item.detailBadge = [root.lastPathComponent isEqualToString:@"Application"] ? @"APP" : @"EXT";
            [apps addObject:item];
        }
    }
    @synchronized (NSNull.null) {
        gWQSpotlightAppCache = apps;
    }
}

@interface WQSpotlightViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, weak) UIViewController *hostVC;
@property (nonatomic) BOOL showRecentsFirst;
@end

@implementation WQSpotlightViewController {
    UIVisualEffectView *_backdrop;
    UIVisualEffectView *_panel;
    UITextField *_searchField;
    UITableView *_tableView;
    UILabel *_hintLabel;
    NSArray<NSString *> *_sectionTitles;
    NSArray<NSArray<WQSpotlightResult *> *> *_sections;
    NSUInteger _searchGeneration;
}

- (instancetype)initWithHost:(UIViewController *)host showRecentsFirst:(BOOL)showRecentsFirst
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _hostVC = host;
        _showRecentsFirst = showRecentsFirst;
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    _backdrop = [[UIVisualEffectView alloc] initWithEffect:UIAccessibilityIsReduceTransparencyEnabled() ? nil : blur];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithRed:0.035 green:0.039 blue:0.051 alpha:0.78];
    _backdrop.alpha = 0.0;
    [self.view addSubview:_backdrop];

    _panel = wq_theme_make_glass_card(28.0, NO);
    _panel.layer.borderWidth = 0.5;
    _panel.layer.borderColor = wq_theme_rim().CGColor;
    _panel.alpha = 0.0;
    _panel.transform = wq_motion_reduced() ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.94, 0.94);
    [self.view addSubview:_panel];

    // Top Spotlight search capsule wrapped in UIGlassContainerEffect.
    UIImageView *mag = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    mag.tintColor = wq_theme_accent();
    mag.contentMode = UIViewContentModeScaleAspectFit;
    mag.translatesAutoresizingMaskIntoConstraints = NO;

    _searchField = [UITextField new];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _searchField.textColor = wq_theme_primary_text();
    _searchField.tintColor = wq_theme_accent();
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.delegate = self;
    _searchField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:WQLocalized(@"Search files, apps, caches, commands…")
            attributes:@{NSForegroundColorAttributeName: wq_theme_secondary_text()}];
    [_searchField addTarget:self action:@selector(queryChanged) forControlEvents:UIControlEventEditingChanged];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *closeCfg = [UIButtonConfiguration plainButtonConfiguration];
    closeCfg.title = WQLocalized(@"Done");
    closeCfg.baseForegroundColor = wq_theme_accent();
    closeCfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
    closeBtn.configuration = closeCfg;
    [closeBtn addTarget:self action:@selector(dismissSpotlight) forControlEvents:UIControlEventTouchUpInside];
    wq_motion_add_interactive_hold(closeBtn, nil);

    UIStackView *searchRow = [[UIStackView alloc] initWithArrangedSubviews:@[mag, _searchField, closeBtn]];
    searchRow.axis = UILayoutConstraintAxisHorizontal;
    searchRow.alignment = UIStackViewAlignmentCenter;
    searchRow.spacing = 10;
    searchRow.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 8);
    searchRow.layoutMarginsRelativeArrangement = YES;

    UIView *searchCapsule = wq_theme_glass_container(searchRow, 6);
    searchCapsule.backgroundColor = [UIColor colorWithRed:0.086 green:0.098 blue:0.125 alpha:0.65];
    searchCapsule.layer.cornerRadius = 22.0;
    searchCapsule.layer.cornerCurve = kCACornerCurveContinuous;
    searchCapsule.layer.borderWidth = 0.5;
    searchCapsule.layer.borderColor = wq_theme_rim().CGColor;
    searchCapsule.clipsToBounds = YES;

    _hintLabel = [UILabel new];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hintLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _hintLabel.textColor = wq_theme_secondary_text();
    _hintLabel.text = _showRecentsFirst
        ? WQLocalized(@"RECENT SEARCHES & QUICK COMMANDS")
        : WQLocalized(@"SPOTLIGHT · FILES · APPS · CACHES · COMMANDS");

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorColor = wq_theme_hairline();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.clipsToBounds = YES;
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 36, 0);
    [_tableView registerClass:WQSpotlightCell.class forCellReuseIdentifier:@"spot"];

    [_panel.contentView addSubview:searchCapsule];
    [_panel.contentView addSubview:_hintLabel];
    [_panel.contentView addSubview:_tableView];

    wq_motion_install_edge_blur(_tableView, _tableView);

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_panel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [_panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [mag.widthAnchor constraintEqualToConstant:18],
        [mag.heightAnchor constraintEqualToConstant:18],
        [searchCapsule.topAnchor constraintEqualToAnchor:_panel.contentView.topAnchor constant:12],
        [searchCapsule.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor constant:12],
        [searchCapsule.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor constant:-12],
        [_hintLabel.topAnchor constraintEqualToAnchor:searchCapsule.bottomAnchor constant:8],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor constant:18],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor constant:-18],
        [_tableView.topAnchor constraintEqualToAnchor:_hintLabel.bottomAnchor constant:4],
        [_tableView.bottomAnchor constraintEqualToAnchor:_panel.contentView.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor],
    ]];

    [self loadEmptyState];
    dispatch_async(wq_io(), ^{ wq_spotlight_warm_apps_on_io(); });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    BOOL reduced = wq_motion_reduced();
    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.28 dampingRatio:reduced ? 1.0 : 0.84 animations:^{
        self->_backdrop.alpha = 1.0;
        self->_panel.alpha = 1.0;
        self->_panel.transform = CGAffineTransformIdentity;
    }];
    [anim startAnimation];
    if (!_showRecentsFirst) [_searchField becomeFirstResponder];
}

- (void)dismissWithCompletion:(void (^_Nullable)(void))completion
{
    [_searchField resignFirstResponder];
    if (wq_motion_reduced()) {
        [self dismissViewControllerAnimated:NO completion:completion];
        return;
    }
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_backdrop.alpha = 0.0;
        self->_panel.alpha = 0.0;
        self->_panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL __unused finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (void)dismissSpotlight
{
    wq_haptic_impact(UIImpactFeedbackStyleLight);
    [self dismissWithCompletion:nil];
}

- (void)loadEmptyState
{
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    NSMutableArray<NSArray<WQSpotlightResult *> *> *secs = [NSMutableArray new];

    NSArray<NSString *> *recents = wq_spotlight_recents();
    if (recents.count) {
        NSMutableArray<WQSpotlightResult *> *rows = [NSMutableArray new];
        for (NSString *q in recents) {
            WQSpotlightResult *r = [WQSpotlightResult new];
            r.category = WQSearchCategoryRecent;
            r.title = q;
            r.subtitle = WQLocalized(@"Recent search");
            r.symbolName = @"clock";
            [rows addObject:r];
        }
        [titles addObject:WQLocalized(@"Recent Searches")];
        [secs addObject:rows];
    }

    [titles addObject:WQLocalized(@"Quick Commands")];
    [secs addObject:wq_spotlight_quick_commands()];

    _sectionTitles = titles;
    _sections = secs;
    [_tableView reloadData];
}

- (void)queryChanged
{
    NSString *q = [_searchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger gen = ++_searchGeneration;
    if (!q.length) {
        [self loadEmptyState];
        return;
    }
    dispatch_async(wq_io(), ^{
        wq_spotlight_warm_apps_on_io();
        NSMutableArray<WQSpotlightResult *> *cmds = [NSMutableArray new];
        for (WQSpotlightResult *c in wq_spotlight_quick_commands()) {
            if ([c.title localizedCaseInsensitiveContainsString:q] || [c.subtitle localizedCaseInsensitiveContainsString:q]) {
                [cmds addObject:c];
            }
        }

        NSMutableArray<WQSpotlightResult *> *apps = [NSMutableArray new];
        NSMutableArray<WQSpotlightResult *> *cachesAndBackups = [NSMutableArray new];
        NSArray<WQSpotlightResult *> *cachedApps = nil;
        @synchronized (NSNull.null) {
            cachedApps = [gWQSpotlightAppCache copy];
        }
        for (WQSpotlightResult *app in cachedApps) {
            if ([app.title localizedCaseInsensitiveContainsString:q] ||
                (app.bundleID && [app.bundleID localizedCaseInsensitiveContainsString:q]) ||
                [app.path.lastPathComponent localizedCaseInsensitiveContainsString:q]) {
                if (apps.count < 24) [apps addObject:app];
                if (cachesAndBackups.count < 12 && app.path.length) {
                    NSString *cacheDir = [app.path stringByAppendingPathComponent:@"Library/Caches"];
                    WQSpotlightResult *c = [WQSpotlightResult new];
                    c.category = WQSearchCategoryCacheOrBackup;
                    c.title = [NSString stringWithFormat:@"%@ · Caches", app.title];
                    c.subtitle = cacheDir;
                    c.path = cacheDir;
                    c.bundleID = app.bundleID;
                    c.symbolName = @"sparkles";
                    c.isDirectory = YES;
                    c.detailBadge = @"CACHE";
                    [cachesAndBackups addObject:c];
                }
            }
        }

        // Saved backups in File Backups & App Backups.
        NSString *fileBackups = wq_backup_root();
        NSString *appBackups = [fileBackups.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"App Backups"];
        for (NSString *bRoot in @[fileBackups, appBackups]) {
            NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bRoot error:nil];
            for (NSString *entry in entries) {
                if (![entry localizedCaseInsensitiveContainsString:q]) continue;
                NSString *full = [bRoot stringByAppendingPathComponent:entry];
                BOOL isDir = NO;
                [NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir];
                WQSpotlightResult *b = [WQSpotlightResult new];
                b.category = WQSearchCategoryCacheOrBackup;
                b.title = entry;
                b.subtitle = bRoot.lastPathComponent;
                b.path = full;
                b.symbolName = @"clock.arrow.circlepath";
                b.isDirectory = isDir;
                b.detailBadge = @"BACKUP";
                [cachesAndBackups addObject:b];
                if (cachesAndBackups.count >= 24) break;
            }
        }

        // Fast indexed search across Favorites, Recent folder, and permitted paths.
        NSMutableArray<NSString *> *searchRoots = [NSMutableArray new];
        NSArray *favs = [NSUserDefaults.standardUserDefaults arrayForKey:@"WQFavorites"];
        if ([favs isKindOfClass:NSArray.class]) {
            for (id f in favs) if ([f isKindOfClass:NSString.class]) [searchRoots addObject:f];
        }
        NSString *lastFolder = [NSUserDefaults.standardUserDefaults stringForKey:@"WQLastFolder"];
        if (lastFolder.length && ![searchRoots containsObject:lastFolder]) [searchRoots addObject:lastFolder];
        for (WQSpotlightResult *a in apps) {
            if (searchRoots.count >= 8) break;
            if (a.path.length && ![searchRoots containsObject:a.path]) [searchRoots addObject:a.path];
        }

        NSMutableArray<WQSpotlightResult *> *files = [NSMutableArray new];
        NSMutableSet<NSString *> *seen = [NSMutableSet new];
        for (NSString *root in searchRoots) {
            if (files.count >= 30) break;
            NSArray<NSString *> *items = wq_list(root, NULL);
            for (NSString *name in items) {
                if (files.count >= 30) break;
                NSString *full = [root stringByAppendingPathComponent:name];
                if ([seen containsObject:full]) continue;
                if ([name localizedCaseInsensitiveContainsString:q]) {
                    [seen addObject:full];
                    struct stat st;
                    BOOL ok = (lstat(full.fileSystemRepresentation, &st) == 0);
                    BOOL isDir = ok && S_ISDIR(st.st_mode);
                    WQSpotlightResult *r = [WQSpotlightResult new];
                    r.category = WQSearchCategoryFile;
                    r.title = name;
                    r.subtitle = root;
                    r.path = full;
                    r.isDirectory = isDir;
                    r.symbolName = isDir ? @"folder.fill" : @"doc.fill";
                    r.detailBadge = (!isDir && ok) ? wq_size_text((unsigned long long)st.st_size) : @"DIR";
                    [files addObject:r];
                }
            }
        }

        NSMutableArray<NSString *> *titles = [NSMutableArray new];
        NSMutableArray<NSArray<WQSpotlightResult *> *> *secs = [NSMutableArray new];
        if (cmds.count) { [titles addObject:WQLocalized(@"Quick Commands")]; [secs addObject:cmds]; }
        if (apps.count) { [titles addObject:WQLocalized(@"Apps & Extensions")]; [secs addObject:apps]; }
        if (files.count) { [titles addObject:WQLocalized(@"Files & Folders")]; [secs addObject:files]; }
        if (cachesAndBackups.count) { [titles addObject:WQLocalized(@"Caches & Backups")]; [secs addObject:cachesAndBackups]; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_searchGeneration) return;
            self->_sectionTitles = titles;
            self->_sections = secs;
            [self->_tableView reloadData];
        });
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    wq_spotlight_save_recent(textField.text ?: @"");
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView
{
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    return _sectionTitles[(NSUInteger)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    WQSpotlightCell *cell = [tableView dequeueReusableCellWithIdentifier:@"spot" forIndexPath:indexPath];
    WQSpotlightResult *r = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    cell.titleLabel.text = r.title;
    cell.subtitleLabel.text = r.subtitle;
    cell.sizeLabel.text = r.detailBadge ?: @"";
    if (r.bundleID.length) {
        cell.iconView.image = wq_app_icon(r.bundleID) ?: wq_glacier_symbol_badge(r.symbolName, 34.0);
    } else {
        cell.iconView.image = wq_glacier_symbol_badge(r.symbolName, 34.0);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    WQSpotlightResult *r = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    if (r.category == WQSearchCategoryRecent) {
        _searchField.text = r.title;
        [self queryChanged];
        return;
    }
    if (_searchField.text.length) wq_spotlight_save_recent(_searchField.text);
    UIViewController *host = _hostVC;
    [self dismissWithCompletion:^{
        if (!host) return;
        if (r.category == WQSearchCategoryCommand && r.commandID.length) {
            if (gWQGlobalSearchCommandHandler) gWQGlobalSearchCommandHandler(r.commandID, host);
            return;
        }
        if (r.path.length) {
            NSString *targetDir = r.isDirectory ? r.path : r.path.stringByDeletingLastPathComponent;
            NSString *title = r.isDirectory ? r.title : targetDir.lastPathComponent;
            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:targetDir title:title];
            UINavigationController *nav = host.navigationController ?: ([host isKindOfClass:UINavigationController.class] ? (UINavigationController *)host : nil);
            if (nav) [nav pushViewController:dir animated:YES];
        }
    }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    wq_motion_apply_scroll_wave(scrollView);
    wq_motion_update_edge_blur(scrollView, scrollView);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    wq_motion_settle_edge_blur(scrollView, scrollView);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate) wq_motion_settle_edge_blur(scrollView, scrollView);
}

@end

void wq_global_search_register_command_handler(void (^handler)(NSString *commandID, UIViewController *host))
{
    gWQGlobalSearchCommandHandler = [handler copy];
}

void wq_global_search_present(UIViewController *host, BOOL showRecentsFirst)
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    WQSpotlightViewController *spot = [[WQSpotlightViewController alloc] initWithHost:host showRecentsFirst:showRecentsFirst];
    [host presentViewController:spot animated:NO completion:nil];
}

UIButton *wq_global_search_pill_button(UIViewController *host)
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold];
    cfg.image = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:sym];
    cfg.title = WQLocalized(@"Search");
    cfg.imagePadding = 5.0;
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.baseBackgroundColor = wq_theme_glass_tint();
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 11);
    cfg.background.strokeColor = wq_theme_rim();
    cfg.background.strokeWidth = 0.5;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *inAttr) {
        NSMutableDictionary *outAttr = [inAttr mutableCopy] ?: [NSMutableDictionary new];
        outAttr[NSFontAttributeName] = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        return outAttr;
    };
    btn.configuration = cfg;
    btn.accessibilityLabel = WQLocalized(@"Universal Search");

    __weak UIViewController *weakHost = host;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_impact(UIImpactFeedbackStyleLight);
        UIViewController *h = weakHost;
        if (h) wq_global_search_present(h, NO);
    }] forControlEvents:UIControlEventTouchUpInside];

    // Press-and-hold immediately opens Recent Searches & Quick Commands with progressive haptics.
    wq_motion_add_interactive_hold(btn, ^{
        UIViewController *h = weakHost;
        if (h) wq_global_search_present(h, YES);
    });
    return btn;
}

UIButton *wq_global_search_dock_button(UIViewController *host)
{
    UIButton *btn = wq_motion_dock_button(nil, @"magnifyingglass", WQLocalized(@"Universal Search"));
    __weak UIViewController *weakHost = host;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_impact(UIImpactFeedbackStyleLight);
        UIViewController *h = weakHost;
        if (h) wq_global_search_present(h, NO);
    }] forControlEvents:UIControlEventTouchUpInside];

    wq_motion_add_interactive_hold(btn, ^{
        UIViewController *h = weakHost;
        if (h) wq_global_search_present(h, YES);
    });
    return btn;
}
