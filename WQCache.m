//
//  WQCache.m
//  WQ Files cache cleaner
//  GPL-3.0-or-later.
//

#import "WQCache.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQTheme.h"
#import "WQMotion.h"
#import "WQGlobalSearch.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQCacheSafety.h"

#import <QuartzCore/QuartzCore.h>
#import <errno.h>
#import <stdatomic.h>
#import <sys/stat.h>

#pragma mark - Cache cleaner

static NSString *const kCrashLogsPath =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter";

@interface WQCacheTargetRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic) BOOL existed;
@property (nonatomic) BOOL identityKnown;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@property (nonatomic) mode_t mode;
@end
@implementation WQCacheTargetRecord
@end

@interface WQCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL cacheKnown;
@property (nonatomic) BOOL tempKnown;
@property (nonatomic) BOOL limited;
@property (nonatomic) BOOL crashLogs;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic) BOOL containerIdentityKnown;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) mode_t containerMode;
@property (nonatomic, copy) NSArray<WQCacheTargetRecord *> *targetRecords;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end
@implementation WQCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

static void WQCacheSelectionCategories(NSArray<WQCacheItem *> *items,
                                       BOOL *hasApps,
                                       BOOL *hasCrashLogs,
                                       NSUInteger *appCount)
{
    BOOL apps = NO, crashLogs = NO;
    NSUInteger count = 0;
    for (WQCacheItem *item in items) {
        if (item.crashLogs) {
            crashLogs = YES;
        } else {
            apps = YES;
            count++;
        }
    }
    if (hasApps) *hasApps = apps;
    if (hasCrashLogs) *hasCrashLogs = crashLogs;
    if (appCount) *appCount = count;
}

static NSString *WQCacheConfirmationScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    NSUInteger appCount = 0;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, &appCount);
    if (hasApps && hasCrashLogs) {
        return WQLocalizedFormat(appCount == 1
                ? @"Delete Library/Caches and tmp for %lu app, plus Crash Logs"
                : @"Delete Library/Caches and tmp for %lu apps, plus Crash Logs",
                (unsigned long)appCount);
    }
    if (hasApps) {
        return WQLocalizedFormat(appCount == 1
                ? @"Delete Library/Caches and tmp for %lu app"
                : @"Delete Library/Caches and tmp for %lu apps",
                (unsigned long)appCount);
    }
    if (hasCrashLogs) return WQLocalized(@"Delete Crash Logs");
    return WQLocalized(@"Delete the selected cache targets");
}

static NSString *WQCacheFooterScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, NULL);
    if (hasApps && hasCrashLogs) {
        return WQLocalized(@"Clears each selected app's Library/Caches and tmp, and deletes selected Crash Logs. Apps rebuild their caches as you use them; some keep offline content (music, maps, downloads) there and will download it again. No backup is kept.");
    }
    if (hasApps) {
        return WQLocalized(@"Clears each selected app's Library/Caches and tmp. Apps rebuild their caches as you use them; some keep offline content (music, maps, downloads) there and will download it again. No backup is kept.");
    }
    if (hasCrashLogs) return WQLocalized(@"Deletes selected Crash Logs. This cannot be undone. No backup is kept.");
    return WQLocalized(@"Select app caches or Crash Logs to see the deletion scope. No backup is kept.");
}

typedef NS_ENUM(NSInteger, WQCacheMeasurementState) {
    WQCacheMeasurementMissing,
    WQCacheMeasurementKnown,
    WQCacheMeasurementLimited,
    WQCacheMeasurementCancelled,
};

static WQCacheMeasurementState WQCacheMeasureDirectory(NSString *path,
                                                        WQScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
    unsigned long long total = 0;
    WQMeasureResult result = wq_measure_tree(path, cancellation, &total);
    switch (result) {
        case WQMeasureResultMissing:
            return WQCacheMeasurementMissing;
        case WQMeasureResultKnown:
            if (bytes) *bytes = total;
            return WQCacheMeasurementKnown;
        case WQMeasureResultCancelled:
            return WQCacheMeasurementCancelled;
        case WQMeasureResultLimited:
            wq_log(@"cache scan: limited tree measurement for %@", path);
            return WQCacheMeasurementLimited;
    }
    return WQCacheMeasurementLimited;
}

typedef NS_ENUM(NSInteger, WQCachePathState) {
    WQCachePathMissing,
    WQCachePathExisting,
    WQCachePathInaccessible,
};

static WQCachePathState WQCacheInspectPath(NSString *path, struct stat *st)
{
    if (wq_stat(path, st)) return WQCachePathExisting;
    struct stat direct = {0};
    if (lstat(path.fileSystemRepresentation, &direct) == 0) {
        if (st) *st = direct;
        return WQCachePathExisting;
    }
    if (errno == ENOENT || errno == ENOTDIR) return WQCachePathMissing;
    return WQCachePathInaccessible;
}

static WQCacheTargetRecord *WQCacheTargetRecordForPath(NSString *path, NSString *relativePath)
{
    WQCacheTargetRecord *record = [WQCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(path, &st);
    if (state == WQCachePathExisting) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st.st_dev;
        record.inode = st.st_ino;
        record.mode = st.st_mode & S_IFMT;
    }
    return record;
}

static void WQCacheCaptureContainerIdentity(WQCacheItem *item)
{
    struct stat st = {0};
    if (item.containerPath.length && wq_stat(item.containerPath, &st) && S_ISDIR(st.st_mode)) {
        item.containerIdentityKnown = YES;
        item.containerDevice = st.st_dev;
        item.containerInode = st.st_ino;
        item.containerMode = st.st_mode & S_IFMT;
    }
}

static BOOL WQCacheRecordIdentityMatches(WQCacheTargetRecord *record, NSString **reason)
{
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(record.path, &st);
    if (!record.existed) {
        if (state == WQCachePathMissing) return YES;
        if (reason) *reason = [NSString stringWithFormat:@"%@ appeared after the scan", record.path];
        return NO;
    }
    if (state != WQCachePathExisting || !record.identityKnown ||
        st.st_dev != record.device || st.st_ino != record.inode ||
        (st.st_mode & S_IFMT) != record.mode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", record.path];
        return NO;
    }
    return YES;
}

static BOOL WQCacheCrashPathIsSafe(NSString *path)
{
    NSString *expected = [kCrashLogsPath stringByStandardizingPath];
    return [[path stringByStandardizingPath] isEqualToString:expected] &&
           WQCacheSafetyHasNoSymlinkAncestry(path, YES) &&
           [WQCacheSafetyCanonicalPath(path) isEqualToString:expected];
}

static BOOL WQCacheValidateItem(WQCacheItem *item, NSString **reason)
{
    if (item.limited) {
        if (reason) *reason = WQLocalized(@"the scan had limited access");
        return NO;
    }
    if (item.crashLogs) {
        if (item.targetRecords.count != 1 || !WQCacheCrashPathIsSafe(item.targets.firstObject)) {
            if (reason) *reason = WQLocalized(@"the crash-log target is not the expected canonical directory");
            return NO;
        }
        return WQCacheRecordIdentityMatches(item.targetRecords.firstObject, reason);
    }
    if (item.targetRecords.count != 2 || item.targets.count != 2 ||
        ![item.targets[0] isEqualToString:item.targetRecords[0].path] ||
        ![item.targets[1] isEqualToString:item.targetRecords[1].path]) {
        if (reason) *reason = WQLocalized(@"the scanned cache targets are incomplete");
        return NO;
    }
    if (!item.containerIdentityKnown || !WQCacheSafetyHasNoSymlinkAncestry(item.containerPath, NO)) {
        if (reason) *reason = WQLocalized(@"the app container identity or ancestry is unavailable");
        return NO;
    }
    struct stat container = {0};
    if (WQCacheInspectPath(item.containerPath, &container) != WQCachePathExisting ||
        !S_ISDIR(container.st_mode) || container.st_dev != item.containerDevice ||
        container.st_ino != item.containerInode || (container.st_mode & S_IFMT) != item.containerMode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", item.name];
        return NO;
    }
    NSString *label = wq_container_label(item.containerPath);
    if (!item.bundleID.length || ![label isEqualToString:item.bundleID]) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ no longer has the scanned container identity", item.name];
        return NO;
    }
    for (WQCacheTargetRecord *record in item.targetRecords) {
        if (!WQCacheSafetyTargetMatchesContainer(record.path, item.containerPath, record.relativePath)) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ has unsafe path ancestry", record.path];
            return NO;
        }
        if (!WQCacheRecordIdentityMatches(record, reason)) return NO;
    }
    return YES;
}

#pragma mark - Custom targets (ported from upstream)

static NSString *const kWQCacheCustomTargetsPref = @"WQCleanerCustomTargets";

static NSArray<NSDictionary *> *wq_cache_custom_targets(void)
{
    NSMutableArray *out = [NSMutableArray new];
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kWQCacheCustomTargetsPref];
    if (![stored isKindOfClass:NSArray.class]) return out;
    for (id t in stored)
        if ([t isKindOfClass:NSDictionary.class] && [t[@"bundle"] isKindOfClass:NSString.class] &&
            [(NSString *)t[@"bundle"] length] && WQCacheCustomRelativeValid(t[@"path"])) [out addObject:t];
    return out;
}

BOOL wq_cache_custom_target_contains(NSString *bundleID, NSString *relative)
{
    for (NSDictionary *t in wq_cache_custom_targets())
        if ([t[@"bundle"] isEqualToString:bundleID] && [t[@"path"] isEqualToString:relative]) return YES;
    return NO;
}

NSDictionary *wq_cache_custom_target_for_path(NSString *path)
{
    NSString *container = nil;
    NSString *relative = WQCacheCustomRelativeForPath(path, &container);
    if (!relative) return nil;
    for (NSDictionary *t in wq_cache_custom_targets())
        if ([t[@"path"] isEqualToString:relative] && [t[@"container"] isEqual:container]) return t;
    return nil;
}

void wq_cache_custom_target_add(NSString *bundleID, NSString *appName, NSString *container, NSString *relative, BOOL isFile,
                                BOOL autoSelect)
{
    if (!bundleID.length || !WQCacheCustomRelativeValid(relative) || wq_cache_custom_target_contains(bundleID, relative)) return;
    NSMutableArray *targets = [wq_cache_custom_targets() mutableCopy];
    [targets addObject:@{@"bundle": bundleID, @"app": appName ?: bundleID, @"container": container ?: @"",
                         @"path": relative, @"file": @(isFile), @"auto": @(autoSelect)}];
    [NSUserDefaults.standardUserDefaults setObject:targets forKey:kWQCacheCustomTargetsPref];
    wq_log(@"cache cleaner: added %@ of %@", relative, bundleID);
}

void wq_cache_custom_target_set_auto_select(NSString *bundleID, NSString *relative, BOOL autoSelect)
{
    NSMutableArray *targets = [NSMutableArray new];
    for (NSDictionary *t in wq_cache_custom_targets()) {
        if ([t[@"bundle"] isEqualToString:bundleID] && [t[@"path"] isEqualToString:relative]) {
            NSMutableDictionary *changed = [t mutableCopy];
            changed[@"auto"] = @(autoSelect);
            [targets addObject:changed];
        } else [targets addObject:t];
    }
    [NSUserDefaults.standardUserDefaults setObject:targets forKey:kWQCacheCustomTargetsPref];
}

void wq_cache_custom_target_remove(NSString *bundleID, NSString *relative)
{
    NSMutableArray *targets = [NSMutableArray new];
    for (NSDictionary *t in wq_cache_custom_targets())
        if (!([t[@"bundle"] isEqualToString:bundleID] && [t[@"path"] isEqualToString:relative])) [targets addObject:t];
    [NSUserDefaults.standardUserDefaults setObject:targets forKey:kWQCacheCustomTargetsPref];
}

// Row: selection circle, icon, name with "cache · temp" below, size in a
// fixed right-hand column so long names never push it out.
@interface WQCleanerCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView, *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel, *sizeLabel;
@end

@implementation WQCleanerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.clipsToBounds = YES;
        self.contentView.clipsToBounds = YES;
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.textColor = wq_theme_primary_text();
        _nameLabel.numberOfLines = 2;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = wq_theme_secondary_text();
        _detailLabel.numberOfLines = 0;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textColor = wq_theme_primary_text();
        // Trailing edge in both layout directions.
        _sizeLabel.textAlignment = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:self.semanticContentAttribute]
            == UIUserInterfaceLayoutDirectionRightToLeft ? NSTextAlignmentLeft : NSTextAlignmentRight;
        for (UIView *v in @[_checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: reclaimable total, a bar for the selected share, status.
@interface WQSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel, *totalLabel, *statusLabel;
@property (nonatomic, strong) WQProgressBarView *bar;
@property (nonatomic, strong) WQProgressRingView *ring;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WQSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.clipsToBounds = YES;
        self.contentView.clipsToBounds = YES;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = wq_theme_secondary_text();
        _totalLabel = [UILabel new];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle]
                            scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
        _totalLabel.textColor = wq_theme_primary_text();
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[WQProgressBarView alloc] initWithFrame:CGRectZero];
        _ring = [[WQProgressRingView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
        _ring.lineWidth = 5;
        _ring.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_ring.widthAnchor constraintEqualToConstant:52],
            [_ring.heightAnchor constraintEqualToConstant:52],
        ]];
        UIView *ringSpacer = [UIView new];
        [ringSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *totalRow = [[UIStackView alloc] initWithArrangedSubviews:@[_totalLabel, ringSpacer, _ring]];
        totalRow.alignment = UIStackViewAlignmentCenter;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = wq_theme_secondary_text();
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _spinner]];
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[captionRow, totalRow, _bar, _statusLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:totalRow];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
        wq_motion_add_hud_brackets(self.contentView, 7, 10);
        wq_motion_add_scan_sweep(self.contentView, NO);
    }
    return self;
}

@end

@interface WQCacheCleanerViewController () <UISearchControllerDelegate>
@end

@implementation WQCacheCleanerViewController {
    NSArray<WQCacheItem *> *_items;
    NSArray<WQCacheItem *> *_visibleItems;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning, _scanLimited, _cleanRequiresRescan;
    // A refresh asked for while cleaning runs once the cleaning has ended:
    // a scan must not replace the list (or the Stop button) under it.
    BOOL _refreshAfterClean, _rescanAfterClean;
    WQScanCancellation *_scanCancellation;
    WQScanCancellation *_cleanCancellation;
    NSUInteger _scanGeneration;
    NSTimeInterval _lastScanFinished;
    float _scanProgress;   // 0…1 while scanning
    unsigned long long _scanBytes;   // found so far while scanning
    NSInteger _filterMode;   // 0 All, 1 Selected, 2 Large (50 MB+)
    NSMutableArray<UIButton *> *_filterPills;
    UIScrollView *_headerPillScroll;
    UIVisualEffectView *_cacheCornerRail;
    UIButton *_cleanPillButton;
    UIButton *_selectPillButton;
    BOOL _didCascade;
    BOOL _forceFreshNextScan;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Cache Cleaner");
    self.tabBarItem.title = WQLocalizedNullable(@"Clean");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    self.tableView.tableHeaderView = [self buildGlassCacheHeader];
    wq_install_header_shield(self);
    wq_theme_apply_scroll_insets(self.tableView, 156.0);
    [self buildCacheCornerRail];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.delegate = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = WQLocalizedNullable(@"Search apps");
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange) name:WQThemeDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelInFlightScan) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)themeDidChange
{
    [self syncFilterPills];
    [self updateButtons];
    [self.tableView reloadData];
}

- (void)buildCacheCornerRail
{
    __weak typeof(self) weakSelf = self;
    _cleanPillButton = wq_motion_dock_pill(WQLocalized(@"Clean"), @"sparkles", YES);
    [_cleanPillButton.widthAnchor constraintGreaterThanOrEqualToConstant:96.0].active = YES;
    wq_motion_add_hold_progress_ring(_cleanPillButton, 0.65, ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        if (me->_cleaning) [me stopClean]; else [me confirmClean];
    });

    _selectPillButton = wq_motion_dock_pill(WQLocalized(@"Select"), @"checklist", NO);
    _selectPillButton.showsMenuAsPrimaryAction = YES;
    wq_motion_add_interactive_hold(_selectPillButton, nil);

    UIButton *searchBtn = wq_global_search_dock_button(self);

    UIButton *rescanBtn = wq_motion_dock_button(nil, @"arrow.clockwise", WQLocalized(@"Rescan"));
    [rescanBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_impact(UIImpactFeedbackStyleLight);
        [weakSelf userRefresh];
    }] forControlEvents:UIControlEventTouchUpInside];
    wq_motion_add_interactive_hold(rescanBtn, nil);

    _cacheCornerRail = wq_motion_make_dock(@[_cleanPillButton, _selectPillButton, searchBtn, rescanBtn], 6);
    wq_motion_add_hud_brackets(_cacheCornerRail, 5, 8);
    wq_motion_install_corner_rail(_cacheCornerRail, self, self.tableView, 12.0);
}

- (UIView *)buildGlassCacheHeader
{
    CGFloat width = self.view.bounds.size.width ?: 360.0;
    UIView *strip = wq_device_header(width);
    CGFloat stripHeight = strip.frame.size.height;

    UIScrollView *pillScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, stripHeight, width, 46)];
    pillScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    pillScroll.showsHorizontalScrollIndicator = NO;
    pillScroll.alwaysBounceHorizontal = YES;
    pillScroll.contentInset = UIEdgeInsetsMake(0, 16, 0, 16);
    _headerPillScroll = pillScroll;
    wq_motion_attach_horizontal_detents(pillScroll, 76.0);

    UIStackView *pillStack = [UIStackView new];
    pillStack.translatesAutoresizingMaskIntoConstraints = NO;
    pillStack.axis = UILayoutConstraintAxisHorizontal;
    pillStack.spacing = 6;
    pillStack.alignment = UIStackViewAlignmentCenter;
    UIView *pillGroup = wq_theme_glass_container(pillStack, 6);
    [pillScroll addSubview:pillGroup];
    [NSLayoutConstraint activateConstraints:@[
        [pillGroup.topAnchor constraintEqualToAnchor:pillScroll.contentLayoutGuide.topAnchor constant:4],
        [pillGroup.bottomAnchor constraintEqualToAnchor:pillScroll.contentLayoutGuide.bottomAnchor constant:-6],
        [pillGroup.leadingAnchor constraintEqualToAnchor:pillScroll.contentLayoutGuide.leadingAnchor],
        [pillGroup.trailingAnchor constraintEqualToAnchor:pillScroll.contentLayoutGuide.trailingAnchor],
        [pillGroup.heightAnchor constraintEqualToConstant:34],
    ]];

    _filterPills = [NSMutableArray new];
    NSArray<NSString *> *titles = @[
        WQLocalized(@"All"),
        WQLocalized(@"Selected"),
        WQLocalized(@"50 MB+"),
    ];
    __weak typeof(self) weakSelf = self;
    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger idx, BOOL *__unused stop) {
        UIButton *pill = wq_theme_pill_button(title, (NSInteger)idx == self->_filterMode);
        pill.tag = (NSInteger)idx;
        __weak UIButton *weakPill = pill;
        [pill addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            UIButton *sender = weakPill;
            typeof(self) strongSelf = weakSelf;
            if (!sender || !strongSelf) return;
            wq_haptic_selection();
            strongSelf->_filterMode = sender.tag;
            [strongSelf syncFilterPills];
            [strongSelf rebuildVisibleItems];
            [strongSelf.tableView reloadData];
            [strongSelf.tableView layoutIfNeeded];
            wq_motion_cascade_visible(strongSelf.tableView);
            [strongSelf updateButtons];
        }] forControlEvents:UIControlEventTouchUpInside];
        [self->_filterPills addObject:pill];
        [pillStack addArrangedSubview:pill];
    }];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, stripHeight + 48)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:strip];
    [header addSubview:pillScroll];
    return header;
}

- (void)syncFilterPills
{
    for (UIButton *pill in _filterPills) {
        wq_motion_set_pill_active(pill, pill.tag == _filterMode);
    }
}

// Shared launch pre-warm cache & observer hub so Cache Cleaner opens
// instantaneously (0ms) when pre-warmed, or attaches live to an in-flight scan.
static NSObject *gWQCacheHubLock;
static BOOL gWQCacheHubInFlight;
static BOOL gWQCacheHubCompleted;
static NSTimeInterval gWQCacheHubFinishedAt;
static NSUInteger gWQCacheHubGeneration;
static NSArray<WQCacheItem *> *gWQCacheHubItems;
static BOOL gWQCacheHubLimited;
static NSString *gWQCacheHubNote;
static NSString *gWQCacheHubStatus;
static float gWQCacheHubProgress;
static unsigned long long gWQCacheHubFoundBytes;
static WQScanCancellation *gWQCacheHubCancellation;
static NSHashTable<WQCacheCleanerViewController *> *gWQCacheHubObservers;

static void wq_cache_hub_init(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWQCacheHubLock = [NSObject new];
        gWQCacheHubObservers = [NSHashTable weakObjectsHashTable];
    });
}

static NSArray<WQCacheCleanerViewController *> *wq_cache_hub_snapshot_observers(void)
{
    wq_cache_hub_init();
    @synchronized (gWQCacheHubLock) {
        return gWQCacheHubObservers.allObjects;
    }
}

- (void)applySharedCacheProgress:(NSString *)status progress:(float)progress bytes:(unsigned long long)bytes
{
    if (!_scanning || _cleaning) return;
    _scanBytes = bytes;
    [self setStatus:status progress:progress];
}

- (void)applySharedCacheResult:(NSArray<WQCacheItem *> *)items
                       limited:(BOOL)scanLimited
                          note:(NSString *)note
                    finishedAt:(NSTimeInterval)finishedAt
{
    if (_cleaning) return;
    _items = items;
    [self rebuildVisibleItems];
    _scanning = NO;
    _scanLimited = scanLimited;
    _status = note;
    _lastScanFinished = finishedAt;
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    UITableViewCell *summaryCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    if (summaryCell) wq_motion_trigger_scan_sweep(summaryCell.contentView);
    if (!_didCascade && self.visibleItems.count) {
        _didCascade = YES;
        wq_motion_cascade_visible(self.tableView);
    }
    [self updateButtons];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self syncFilterPills];
    wq_cache_hub_init();
    if (!_cleaning) {
        BOOL hubInFlight = NO;
        BOOL hubFresh = NO;
        NSArray<WQCacheItem *> *cachedItems = nil;
        BOOL cachedLimited = NO;
        NSString *cachedNote = nil;
        NSTimeInterval cachedAt = 0;
        NSString *liveStatus = nil;
        float liveProg = 0;
        unsigned long long liveBytes = 0;
        @synchronized (gWQCacheHubLock) {
            hubInFlight = gWQCacheHubInFlight;
            cachedAt = gWQCacheHubFinishedAt;
            hubFresh = gWQCacheHubCompleted && gWQCacheHubItems != nil &&
                       (NSDate.date.timeIntervalSinceReferenceDate - cachedAt <= 600.0);
            if (hubFresh) {
                cachedItems = gWQCacheHubItems;
                cachedLimited = gWQCacheHubLimited;
                cachedNote = gWQCacheHubNote;
            }
            liveStatus = gWQCacheHubStatus;
            liveProg = gWQCacheHubProgress;
            liveBytes = gWQCacheHubFoundBytes;
        }
        if (hubInFlight && !_items.count) {
            @synchronized (gWQCacheHubLock) { [gWQCacheHubObservers addObject:self]; }
            _scanning = YES;
            _scanBytes = liveBytes;
            _scanProgress = liveProg;
            [self updateButtons];
            [self setStatus:liveStatus ?: WQLocalizedNullable(@"Finding apps…") progress:liveProg];
            return;
        }
        if (hubFresh && (!_items || _lastScanFinished < cachedAt)) {
            [self applySharedCacheResult:cachedItems limited:cachedLimited note:cachedNote finishedAt:cachedAt];
            return;
        }
    }
    if (_scanning && _scanCancellation.isCancelled) {
        return;
    }
    // Cached for the session (10 min window) with zero disk I/O when switching back;
    // only rescan if the user returns after data has gone stale.
    if (!_scanning && !_cleaning && _lastScanFinished > 0 &&
        NSDate.date.timeIntervalSinceReferenceDate - _lastScanFinished > 600.0) {
        _forceFreshNextScan = YES;
        [self scan];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!_items && !_scanning && !_cleaning) {
        [self scan];
    }
}

- (void)cancelInFlightScan
{
    wq_cache_hub_init();
    @synchronized (gWQCacheHubLock) {
        [gWQCacheHubObservers removeObject:self];
        if (gWQCacheHubInFlight) {
            [gWQCacheHubCancellation cancel];
            gWQCacheHubInFlight = NO;
        }
    }
    if (_scanning) {
        [_scanCancellation cancel];
        _scanning = NO;
        [self setStatus:nil progress:0];
        [self updateButtons];
    }
    if (_cleaning) [_cleanCancellation cancel];
    [self.refreshControl endRefreshing];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self cancelInFlightScan];
}

- (NSArray<WQCacheItem *> *)visibleItems
{
    return _visibleItems ?: @[];
}

- (void)rebuildVisibleItems
{
    NSArray<WQCacheItem *> *filtered = _items ?: @[];
    if (_filterMode == 1) {
        filtered = [filtered filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
            return it.selected;
        }]];
    } else if (_filterMode == 2) {
        filtered = [filtered filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
            return it.bytes >= 50ull * 1000 * 1000;
        }]];
    }
    if (!_query.length) {
        _visibleItems = filtered;
        return;
    }
    _visibleItems = [filtered filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
        return [it.name localizedCaseInsensitiveContainsString:self->_query] ||
               (it.bundleID && [it.bundleID localizedCaseInsensitiveContainsString:self->_query]);
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleItems];
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)willPresentSearchController:(UISearchController *__unused)searchController
{
    if (_cacheCornerRail) wq_motion_set_visible(_cacheCornerRail, NO, YES);
}

- (void)willDismissSearchController:(UISearchController *__unused)searchController
{
    if (_cacheCornerRail) wq_motion_set_visible(_cacheCornerRail, YES, YES);
}

// While scanning, the bar shows how far the scan is; otherwise how much of
// the reclaimable space is selected.
- (void)setStatus:(NSString *)status progress:(float)progress
{
    _scanProgress = MAX(_scanProgress, MIN(1.0f, progress));
    [self setStatus:status];
}

- (void)configureSummaryCell:(WQSummaryCell *)cell animated:(BOOL)animated
{
    if (!cell) return;
    unsigned long long total = 0, selected = 0;
    NSUInteger n = 0;
    for (WQCacheItem *it in _items) { total += it.bytes; if (it.selected) { selected += it.bytes; n++; } }
    BOOL busy = _scanning || _cleaning;
    NSString *nextCaption = busy ? (_cleaning ? WQLocalized(@"Cleaning") : WQLocalized(@"Scanning")) : WQLocalized(@"Reclaimable");
    NSString *nextStatus = _status ?: _result
        ?: WQLocalizedFormat(n == 1 ? @"%@ selected in %lu item" : @"%@ selected in %lu items",
                             wq_size_text(selected), (unsigned long)n);

    BOOL crossDissolve = animated && !UIAccessibilityIsReduceMotionEnabled();
    if (crossDissolve && ![cell.captionLabel.text isEqualToString:nextCaption]) {
        [UIView transitionWithView:cell.captionLabel
                          duration:0.20
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:^{ cell.captionLabel.text = nextCaption; }
                        completion:nil];
    } else {
        cell.captionLabel.text = nextCaption;
    }

    if (busy) [cell.spinner startAnimating]; else [cell.spinner stopAnimating];
    // While the first scan runs, the total found so far rolls up smoothly.
    unsigned long long shownBytes = (_scanning && !_items.count) ? _scanBytes : total;
    wq_motion_rollup_bytes(cell.totalLabel, shownBytes, busy ? 0.16 : 0.36);

    float shown = _scanning ? _scanProgress : total ? (float)((double)selected / (double)total) : 0;
    [cell.bar setProgress:shown animated:YES];
    cell.bar.hidden = NO;
    // The ring follows the same value; after a clean it closes with a check.
    [cell.ring setProgress:shown animated:YES];
    if (!busy && _result.length && !_cleanRequiresRescan) [cell.ring showCheckmarkAnimated:YES]; else [cell.ring hideCheckmark];

    if (crossDissolve && ![cell.statusLabel.text isEqualToString:nextStatus]) {
        [UIView transitionWithView:cell.statusLabel
                          duration:0.20
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:^{ cell.statusLabel.text = nextStatus; }
                        completion:nil];
    } else {
        cell.statusLabel.text = nextStatus;
    }
}

- (void)setStatus:(NSString *)status
{
    _status = status;
    NSIndexPath *summaryPath = [NSIndexPath indexPathForRow:0 inSection:0];
    WQSummaryCell *cell = (WQSummaryCell *)[self.tableView cellForRowAtIndexPath:summaryPath];
    if ([cell isKindOfClass:WQSummaryCell.class]) {
        [self configureSummaryCell:cell animated:YES];
    } else if (self.isViewLoaded && self.view.window) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)updateButtons
{
    // Stop stays while cleaning, whatever else happens.
    // The floating bottom action dock morphs into Stop, so no duplicate top-right bar button is needed.
    if (_cleaning) {
        self.navigationItem.rightBarButtonItems = nil;
        if (_cleanPillButton) {
            wq_theme_style_primary_button(_cleanPillButton, WQLocalizedNullable(@"Stop"), @"stop.fill");
            [_cleanPillButton removeTarget:self action:NULL forControlEvents:UIControlEventTouchUpInside];
            [_cleanPillButton addTarget:self action:@selector(stopClean) forControlEvents:UIControlEventTouchUpInside];
            _cleanPillButton.enabled = YES;
        }
        _selectPillButton.enabled = NO;
        return;
    }
    if (_scanning) {
        self.navigationItem.rightBarButtonItems = nil;
        if (_cleanPillButton) {
            wq_theme_style_primary_button(_cleanPillButton, WQLocalizedNullable(@"Clean"), @"sparkles");
            [_cleanPillButton removeTarget:self action:NULL forControlEvents:UIControlEventTouchUpInside];
            _cleanPillButton.enabled = NO;
        }
        _selectPillButton.enabled = NO;
        return;
    }
    NSUInteger n = 0;
    for (WQCacheItem *it in _items) if (it.selected) n++;
    BOOL cleanEnabled = n > 0 && !_cleanRequiresRescan;
    NSArray *visible = self.visibleItems;
    BOOL allVisible = visible.count > 0;
    for (WQCacheItem *it in visible) if (it.limited || !it.selected) { allVisible = NO; break; }
    __weak typeof(self) weakSelf = self;
    UIAction *__unused all = [UIAction actionWithTitle:WQLocalizedNullable(@"Select All") image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return YES; }]; }];
    UIAction *none = [UIAction actionWithTitle:WQLocalizedNullable(@"Select None") image:[UIImage systemImageNamed:@"circle"]
                                    identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return NO; }]; }];
    UIAction *large = [UIAction actionWithTitle:WQLocalizedNullable(@"Select Large Caches (50 MB+)") image:[UIImage systemImageNamed:@"arrow.up.circle"]
                                     identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return it.bytes >= 50ull * 1000 * 1000; }];
    }];
    all.state = allVisible ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIMenu *selectMenu = [UIMenu menuWithChildren:@[all, none, large]];
    // Controls float in the bottom-trailing Glacier corner pill cluster.
    self.navigationItem.rightBarButtonItems = nil;
    if (_cleanPillButton) {
        wq_theme_style_primary_button(_cleanPillButton, WQLocalizedNullable(@"Clean"), @"sparkles");
        [_cleanPillButton removeTarget:self action:NULL forControlEvents:UIControlEventTouchUpInside];
        [_cleanPillButton addTarget:self action:@selector(confirmClean) forControlEvents:UIControlEventTouchUpInside];
        _cleanPillButton.enabled = cleanEnabled;
    }
    if (_selectPillButton) {
        _selectPillButton.menu = selectMenu;
        _selectPillButton.enabled = visible.count > 0;
    }
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    if (_cleaning) {
        _refreshAfterClean = YES;
        [self.refreshControl endRefreshing];
        return;
    }
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    _forceFreshNextScan = YES;
    [self scan];
}

// The one refresh after cleaning: the pull to refresh that came in during
// it, a rescan asked for meanwhile, or the rescan the result needs. YES when
// a scan was started.
- (BOOL)rescanAfterClean:(BOOL)needed
{
    BOOL user = _refreshAfterClean, queued = _rescanAfterClean;
    _refreshAfterClean = NO;
    _rescanAfterClean = NO;
    if (!needed && !user && !queued) return NO;
    if (user) {
        wq_enumerate_invalidate();
        wq_display_names_reset_miss();
    }
    _forceFreshNextScan = YES;
    [self scan];
    return YES;
}

static void wq_cache_start_shared_scan(BOOL forceFresh)
{
    wq_cache_hub_init();
    WQScanCancellation *cancellation = nil;
    NSUInteger generation = 0;
    @synchronized (gWQCacheHubLock) {
        if (!forceFresh) {
            if (gWQCacheHubInFlight) return;
            if (gWQCacheHubCompleted && gWQCacheHubItems != nil &&
                NSDate.date.timeIntervalSinceReferenceDate - gWQCacheHubFinishedAt <= 600.0) {
                return;
            }
        }
        [gWQCacheHubCancellation cancel];
        cancellation = [WQScanCancellation new];
        gWQCacheHubCancellation = cancellation;
        generation = ++gWQCacheHubGeneration;
        gWQCacheHubInFlight = YES;
        gWQCacheHubStatus = WQLocalizedNullable(@"Finding apps…");
        gWQCacheHubProgress = 0.0f;
        gWQCacheHubFoundBytes = 0;
    }

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_async(q, ^{
        __block CFTimeInterval lastUIPush = 0;
        NSObject *uiThrottleLock = [NSObject new];
        void (^broadcastProgress)(NSString *, float, unsigned long long, BOOL) = ^(NSString *msg, float prog, unsigned long long bytes, BOOL force) {
            CFTimeInterval now = CACurrentMediaTime();
            @synchronized (uiThrottleLock) {
                if (!force && (now - lastUIPush) < 0.05) return;
                lastUIPush = now;
            }
            @synchronized (gWQCacheHubLock) {
                if (generation != gWQCacheHubGeneration || cancellation.isCancelled) return;
                gWQCacheHubStatus = msg;
                gWQCacheHubProgress = MAX(gWQCacheHubProgress, MIN(1.0f, prog));
                gWQCacheHubFoundBytes = bytes;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cancellation.isCancelled) return;
                for (WQCacheCleanerViewController *vc in wq_cache_hub_snapshot_observers()) {
                    [vc applySharedCacheProgress:msg progress:prog bytes:bytes];
                }
            });
        };

        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        __block BOOL scanLimited = NO;
        __block NSUInteger failedEnumerations = 0;
        __block NSUInteger limitedContainers = 0;
        __block NSUInteger limitedMeasurements = 0;
        __block NSUInteger missingIdentities = 0;
        NSUInteger checkedContainers = 0;
        _Atomic uint64_t atomicFoundBytesVal = 0;
        _Atomic uint64_t *atomicFoundBytesPtr = &atomicFoundBytesVal;
        NSObject *aggLock = [NSObject new];

        NSUInteger maxWorkers = 2;
        dispatch_semaphore_t workerLimit = dispatch_semaphore_create((long)maxWorkers);

        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            if (cancellation.isCancelled) break;
            float share = 1.0f / (float)roots.count, base = (float)[roots indexOfObject:root] * share;
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"apps" : @"extensions";
            NSArray *containers = wq_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                broadcastProgress(WQLocalizedFormat(@"Finding %@… %lld%%", kind, total ? (long long)(done * 100 / total) : 0),
                                  base + share * 0.1f * (total ? (float)done / (float)total : 0),
                                  (unsigned long long)atomic_load(atomicFoundBytesPtr),
                                  NO);
            });
            if (!containers) {
                if (cancellation.isCancelled) break;
                scanLimited = YES;
                failedEnumerations++;
                wq_log(@"cache scan: %@ container enumeration failed", kind);
                continue;
            }
            if (!cancellation.isCancelled && !wq_display_names_loaded()) {
                broadcastProgress(WQLocalizedNullable(@"Reading app names…"), base + share * 0.1f, (unsigned long long)atomic_load(atomicFoundBytesPtr), YES);
                wq_load_display_names();
            }
            if (!containers.count) [emptyRoots addObject:kind];
            NSUInteger count = containers.count;
            checkedContainers += count;
            if (!count) continue;

            _Atomic uint64_t doneInRootVal = 0;
            _Atomic uint64_t *doneInRootPtr = &doneInRootVal;
            dispatch_apply(count, q, ^(size_t idx) {
                if (cancellation.isCancelled) return;
                dispatch_semaphore_wait(workerLimit, DISPATCH_TIME_FOREVER);
                @autoreleasepool {
                    if (!cancellation.isCancelled) {
                        NSString *c = containers[idx];
                        BOOL safeContainer = WQCacheSafetyHasNoSymlinkAncestry(c, NO);
                        BOOL granted = safeContainer && wq_grant(c);  // one token for the whole container
                        NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                        NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                        unsigned long long cacheBytes = 0, tempBytes = 0;
                        BOOL safeCaches = safeContainer &&
                            WQCacheSafetyTargetMatchesContainer(caches, c, @"Library/Caches");
                        BOOL safeTmp = safeContainer &&
                            WQCacheSafetyTargetMatchesContainer(tmp, c, @"tmp");
                        WQCacheMeasurementState cacheState = granted && safeCaches
                            ? WQCacheMeasureDirectory(caches, cancellation, &cacheBytes)
                            : WQCacheMeasurementLimited;
                        if (cacheState != WQCacheMeasurementCancelled) {
                            WQCacheMeasurementState tempState = granted && safeTmp
                                ? WQCacheMeasureDirectory(tmp, cancellation, &tempBytes)
                                : WQCacheMeasurementLimited;
                            if (tempState != WQCacheMeasurementCancelled) {
                                BOOL cacheKnown = cacheState != WQCacheMeasurementLimited;
                                BOOL tempKnown = tempState != WQCacheMeasurementLimited;
                                unsigned long long added = cacheBytes + tempBytes;
                                unsigned long long soFar = (unsigned long long)atomic_fetch_add(atomicFoundBytesPtr, (uint64_t)added) + added;
                                NSUInteger stepNum = (NSUInteger)atomic_fetch_add(doneInRootPtr, 1) + 1;
                                broadcastProgress(WQLocalizedFormat(@"Measuring %@ %lu of %lu…", kind,
                                                  (unsigned long)stepNum, (unsigned long)count),
                                                  base + share * (0.1f + 0.9f * (float)stepNum / (float)count),
                                                  soFar,
                                                  stepNum == count);

                                WQCacheItem *built = nil;
                                BOOL missingId = NO;
                                if (!(cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024)) {
                                    WQCacheItem *item = [WQCacheItem new];
                                    NSString *bid = granted ? wq_container_label(c) : nil;
                                    item.bundleID = bid;
                                    if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                                    item.name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
                                    item.targets = @[caches, tmp];
                                    item.cacheBytes = cacheBytes;
                                    item.tempBytes = tempBytes;
                                    item.cacheKnown = cacheKnown;
                                    item.tempKnown = tempKnown;
                                    item.limited = !cacheKnown || !tempKnown;
                                    item.containerPath = c;
                                    item.targetRecords = @[
                                        WQCacheTargetRecordForPath(caches, @"Library/Caches"),
                                        WQCacheTargetRecordForPath(tmp, @"tmp"),
                                    ];
                                    WQCacheCaptureContainerIdentity(item);
                                    if (!bid.length || !item.containerIdentityKnown) {
                                        item.limited = YES;
                                        missingId = YES;
                                    }
                                    item.selected = !item.limited;
                                    built = item;
                                }
                                @synchronized (aggLock) {
                                    if (!granted || !safeContainer) {
                                        scanLimited = YES;
                                        limitedContainers++;
                                        wq_log(@"cache scan: %@ (%@) %@", c.lastPathComponent, wq_bundle_id_for_container(c) ?: @"unknown app",
                                               safeContainer ? @"refused access" : @"failed the path safety check");
                                    }
                                    if (cacheState == WQCacheMeasurementLimited || tempState == WQCacheMeasurementLimited) {
                                        scanLimited = YES;
                                        limitedMeasurements++;
                                    }
                                    if (missingId) {
                                        scanLimited = YES;
                                        missingIdentities++;
                                    }
                                    if (built) [items addObject:built];
                                }
                            }
                        }
                    }
                }
                dispatch_semaphore_signal(workerLimit);
            });
        }
        if (cancellation.isCancelled) {
            @synchronized (gWQCacheHubLock) {
                if (generation == gWQCacheHubGeneration) gWQCacheHubInFlight = NO;
            }
            return;
        }

        unsigned long long crash = 0;
        // Crash logs are in a system group, which worse_query reaches on iOS 27
        // only. On iOS 26 the section is left out instead of reported as limited.
        BOOL crashReachable = wq_system_areas_reachable();
        BOOL safeCrashPath = crashReachable && WQCacheCrashPathIsSafe(kCrashLogsPath);
        WQCacheMeasurementState crashState = !crashReachable ? WQCacheMeasurementMissing
            : safeCrashPath ? WQCacheMeasureDirectory(kCrashLogsPath, cancellation, &crash)
                            : WQCacheMeasurementLimited;
        if (crashState == WQCacheMeasurementCancelled) {
            @synchronized (gWQCacheHubLock) {
                if (generation == gWQCacheHubGeneration) gWQCacheHubInFlight = NO;
            }
            return;
        }
        BOOL crashLimited = crashState == WQCacheMeasurementLimited;
        if (crashLimited) scanLimited = YES;
        if (crashState == WQCacheMeasurementLimited || crash > 0) {
            WQCacheItem *logs = [WQCacheItem new];
            logs.name = WQLocalized(@"Crash Logs");
            logs.targets = @[kCrashLogsPath];
            logs.cacheBytes = crash;
            logs.cacheKnown = crashState != WQCacheMeasurementLimited;
            logs.crashLogs = YES;
            logs.limited = crashState == WQCacheMeasurementLimited;
            logs.targetRecords = @[WQCacheTargetRecordForPath(kCrashLogsPath, nil)];
            logs.selected = !logs.limited;
            [items addObject:logs];
        }
        [items sortUsingComparator:^NSComparisonResult(WQCacheItem *a, WQCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (failedEnumerations) {
            [notes addObject:WQLocalizedFormat(failedEnumerations == 1
                ? @"%lu container enumeration failed" : @"%lu container enumerations failed",
                (unsigned long)failedEnumerations)];
        }
        if (limitedContainers) {
            [notes addObject:WQLocalizedFormat(limitedContainers == 1
                ? @"%lu container had limited access" : @"%lu containers had limited access",
                (unsigned long)limitedContainers)];
        }
        if (limitedMeasurements) {
            [notes addObject:WQLocalizedFormat(limitedMeasurements == 1
                ? @"%lu cache tree measurement was limited" : @"%lu cache tree measurements were limited",
                (unsigned long)limitedMeasurements)];
        }
        if (missingIdentities) {
            [notes addObject:WQLocalizedFormat(missingIdentities == 1
                ? @"%lu container had no identifier or identity" : @"%lu containers had no identifier or identity",
                (unsigned long)missingIdentities)];
        }
        NSString *note = nil;
        // No containers at all matters more than one limited measurement.
        if (scanLimited && emptyRoots.count) {
            NSString *empty = WQLocalizedFormat(emptyRoots.count == 1 ? @"No %@ container found." : @"No %@ containers found.",
                                                [emptyRoots componentsJoinedByString:@" or "]);
            [notes insertObject:[empty stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".。"]] atIndex:0];
        }
        NSUInteger appRows = 0;
        for (WQCacheItem *item in items) if (!item.crashLogs) appRows++;
        NSMutableArray<NSString *> *sentences = [NSMutableArray new];
        if (!appRows && checkedContainers && !failedEnumerations && !limitedContainers)
            [sentences addObject:WQLocalizedFormat(@"%lu apps and extensions checked: none has 64 KB or more in its caches and temporary files.",
                                                   (unsigned long)checkedContainers)];
        if (notes.count) {
            [notes addObject:WQLocalized(@"limited rows are excluded; the remaining rows can still be cleaned")];
            [sentences addObject:WQLocalizedFormat(@"Scan incomplete: %@. See Log.", [notes componentsJoinedByString:@"; "])];
        } else if (emptyRoots.count) {
            [sentences addObject:WQLocalizedFormat(emptyRoots.count == 1 ? @"No %@ container found." : @"No %@ containers found.",
                                                   [emptyRoots componentsJoinedByString:@" or "])];
        }
        if (crashLimited) [sentences addObject:WQLocalized(@"Crash Logs can't be fully measured on this device.")];
        if (sentences.count) note = [sentences componentsJoinedByString:@" "];
        unsigned long long totalFoundBytes = (unsigned long long)atomic_load(atomicFoundBytesPtr);
        wq_log(@"cache scan: %lu containers checked, %lu rows, %@ found%@", (unsigned long)checkedContainers, (unsigned long)appRows,
               wq_size_text(totalFoundBytes), crashLimited ? @", Crash Logs limited" : @"");

        NSTimeInterval finishedAt = NSDate.date.timeIntervalSinceReferenceDate;
        @synchronized (gWQCacheHubLock) {
            if (generation != gWQCacheHubGeneration || cancellation.isCancelled) return;
            gWQCacheHubInFlight = NO;
            gWQCacheHubCompleted = YES;
            gWQCacheHubFinishedAt = finishedAt;
            gWQCacheHubItems = items;
            gWQCacheHubLimited = scanLimited;
            gWQCacheHubNote = note;
            gWQCacheHubStatus = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (WQCacheCleanerViewController *vc in wq_cache_hub_snapshot_observers()) {
                [vc applySharedCacheResult:items limited:scanLimited note:note finishedAt:finishedAt];
            }
        });
    });
}

+ (void)wq_prewarmOnLaunch
{
    // Disabled for zero launch battery/CPU overhead; Cache Cleaner loads lazily on first visit.
}

- (void)scan
{
    if (_cleaning) {
        _rescanAfterClean = YES;
        [self.refreshControl endRefreshing];
        return;
    }
    BOOL forceFresh = _forceFreshNextScan;
    _forceFreshNextScan = NO;
    wq_cache_hub_init();
    _scanGeneration++;
    _cleanRequiresRescan = NO;
    _result = nil;

    if (!forceFresh) {
        BOOL hubFresh = NO;
        NSArray<WQCacheItem *> *cachedItems = nil;
        BOOL cachedLimited = NO;
        NSString *cachedNote = nil;
        NSTimeInterval cachedAt = 0;
        BOOL hubInFlight = NO;
        NSString *liveStatus = nil;
        float liveProg = 0;
        unsigned long long liveBytes = 0;
        @synchronized (gWQCacheHubLock) {
            cachedAt = gWQCacheHubFinishedAt;
            hubFresh = gWQCacheHubCompleted && gWQCacheHubItems != nil &&
                       (NSDate.date.timeIntervalSinceReferenceDate - cachedAt <= 600.0);
            if (hubFresh) {
                cachedItems = gWQCacheHubItems;
                cachedLimited = gWQCacheHubLimited;
                cachedNote = gWQCacheHubNote;
            }
            hubInFlight = gWQCacheHubInFlight;
            liveStatus = gWQCacheHubStatus;
            liveProg = gWQCacheHubProgress;
            liveBytes = gWQCacheHubFoundBytes;
            [gWQCacheHubObservers addObject:self];
            _scanCancellation = gWQCacheHubCancellation;
        }
        if (hubFresh) {
            [self applySharedCacheResult:cachedItems limited:cachedLimited note:cachedNote finishedAt:cachedAt];
            return;
        }
        if (hubInFlight) {
            _scanning = YES;
            _scanProgress = liveProg;
            _scanBytes = liveBytes;
            [self updateButtons];
            [self setStatus:liveStatus ?: WQLocalizedNullable(@"Finding apps…") progress:liveProg];
            return;
        }
    } else {
        [_scanCancellation cancel];
        @synchronized (gWQCacheHubLock) {
            [gWQCacheHubObservers addObject:self];
        }
    }

    _scanning = YES;
    _scanProgress = 0;
    _scanBytes = 0;
    _scanLimited = NO;
    [self updateButtons];
    [self setStatus:WQLocalizedNullable(@"Finding apps…")];
    wq_cache_start_shared_scan(forceFresh);
    @synchronized (gWQCacheHubLock) {
        _scanCancellation = gWQCacheHubCancellation;
    }
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)self.visibleItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSUInteger shown = self.visibleItems.count;
    NSUInteger appCount = 0;
    for (WQCacheItem *item in _items) if (!item.crashLogs) appCount++;
    if (!appCount) return WQLocalized(@"Crash Logs");
    return _query.length ? WQLocalizedFormat(@"%lu of %lu", (unsigned long)shown, (unsigned long)_items.count)
                         : WQLocalizedFormat(@"%lu apps and extensions", (unsigned long)appCount);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"selected == YES"]];
    return [WQCacheFooterScope(selected) stringByAppendingString:WQLocalized(@" Close running apps first.")];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        WQSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"]
            ?: [[WQSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"summary"];
        [self configureSummaryCell:cell animated:NO];
        return cell;
    }
    WQCleanerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[WQCleanerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.nameLabel.text = item.name;
    if (item.crashLogs) {
        cell.detailLabel.text = item.cacheKnown ? WQLocalized(@"Crash Logs · osanalytics") : WQLocalized(@"Crash Logs · access limited");
    } else {
        NSString *cache = item.cacheKnown ? wq_size_text(item.cacheBytes) : WQLocalized(@"unknown");
        NSString *temp = item.tempKnown ? wq_size_text(item.tempBytes) : WQLocalized(@"unknown");
        cell.detailLabel.text = WQLocalizedFormat(@"cache %@ · temp %@%@", cache, temp,
                                 item.limited ? WQLocalized(@" · access limited") : @"");
    }
    cell.sizeLabel.text = wq_size_text(item.bytes);
    NSString *fallbackSymbol = item.crashLogs ? @"doc.text.magnifyingglass"
                             : (item.bundleID ? @"app.dashed" : @"exclamationmark.triangle");
    cell.iconView.image = wq_app_icon(item.bundleID) ?: wq_glacier_symbol_badge(fallbackSymbol, 36.0);
    cell.iconView.tintColor = wq_theme_secondary_text();
    cell.checkView.image = [UIImage systemImageNamed:item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? wq_theme_accent() : [wq_theme_secondary_text() colorWithAlphaComponent:0.55];
    cell.checkView.layer.shadowColor = item.selected ? wq_theme_accent().CGColor : nil;
    cell.checkView.layer.shadowRadius = item.selected ? 6.0 : 0.0;
    cell.checkView.layer.shadowOpacity = item.selected ? 0.65f : 0.0f;
    cell.checkView.layer.shadowOffset = CGSizeZero;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || _scanning || _cleaning) return;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    if (item.limited) {
        wq_alert(self, @"Not cleanable",
                 @"This row has incomplete access or identity information. Scan again while the app is closed, or use its file browser entry to inspect it.");
        return;
    }
    item.selected = !item.selected;
    wq_haptic_selection();
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    WQSummaryCell *summary = (WQSummaryCell *)[tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    if ([summary isKindOfClass:WQSummaryCell.class]) {
        [self configureSummaryCell:summary animated:YES];
    }
    WQCleanerCell *updated = (WQCleanerCell *)[tableView cellForRowAtIndexPath:indexPath];
    if ([updated isKindOfClass:WQCleanerCell.class]) wq_motion_pop(updated.checkView);
    [self updateButtons];
}

- (void)openFolder:(NSString *)path title:(NSString *)title
{
    [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:title] animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    // Not during a scan or clean: the browser would show a tree that changes underneath it.
    if (indexPath.section == 0 || _scanning || _cleaning) return nil;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (item.crashLogs) {
            NSString *root = item.targets.firstObject;
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Show Crash Logs in File Browser") image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) { [weakSelf openFolder:root title:WQLocalizedNullable(@"Crash Logs")]; }]];
        } else {
            NSString *caches = item.targets[0], *tmp = item.targets[1];
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Show Caches in File Browser") image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches title:[item.name stringByAppendingString:WQLocalized(@" · Caches")]];
            }]];
            if (item.tempBytes > 0)
                [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Show tmp in File Browser") image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    [weakSelf openFolder:tmp title:[item.name stringByAppendingString:WQLocalized(@" · tmp")]];
                }]];
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Show App Data in File Browser") image:[UIImage systemImageNamed:@"folder.badge.gearshape"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent title:item.name];
            }]];
        }
        return [UIMenu menuWithTitle:item.name children:actions];
    }];
}

#pragma mark Actions

// Applies to the rows the current search shows.
- (void)selectWhere:(BOOL (^)(WQCacheItem *item))rule
{
    for (WQCacheItem *it in self.visibleItems) it.selected = !it.limited && rule(it);
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)stopClean
{
    [_cleanCancellation cancel];
    [self setStatus:WQLocalizedNullable(@"Stopping after the current item…")];
}

- (void)confirmClean
{
    if (wq_refuse_if_deleting_off(self)) return;
    NSMutableArray<WQCacheItem *> *selected = [NSMutableArray new];
    unsigned long long sel = 0;
    for (WQCacheItem *item in _items) {
        if (!item.selected) continue;
        [selected addObject:item];
        sel += item.bytes;
    }
    if (!selected.count) return;
    NSString *msg = WQLocalizedFormat(@"%@, about %@? This cannot be undone. Close the selected apps first; you can stop between items.", WQCacheConfirmationScope(selected), wq_size_text(sel));
    __weak typeof(self) weakSelf = self;
    wq_present_glass_confirm(self, @"Clean caches?", msg, @"Clean", YES, ^{ [weakSelf clean]; });
}

- (void)clean
{
    if (_scanning || _cleaning) return;
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _cleanCancellation = cancellation;
    _cleaning = YES;
    [self updateButtons];
    [self setStatus:WQLocalizedNullable(@"Cleaning…")];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        BOOL allOk = YES;
        BOOL cancelled = NO;
        NSString *validationFailure = nil;
        for (WQCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            NSString *reason = nil;
            if (!WQCacheValidateItem(item, &reason)) {
                allOk = NO;
                validationFailure = validationFailure ?: [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];
                wq_log(@"clean: refusing %@ because %@", item.name, reason ?: @"identity validation failed");
            }
        }
        if (validationFailure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_cleaning = NO;
                self->_cleanCancellation = nil;
                self->_scanLimited = YES;
                self->_cleanRequiresRescan = YES;
                self->_status = nil;
                BOOL rescanned = [self rescanAfterClean:NO];
                self->_result = WQLocalizedFormat(@"Clean cancelled: %@. Scan again before retrying.", validationFailure);
                if (rescanned) return;
                [self.tableView reloadData];
                [self updateButtons];
            });
            return;
        }
        NSUInteger i = 0;
        CFTimeInterval lastCleanPush = 0;
        for (WQCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            i++;
            CFTimeInterval now = CACurrentMediaTime();
            if (i == 1 || i == selected.count || (now - lastCleanPush) >= 0.033) {
                lastCleanPush = now;
                NSUInteger idxSnapshot = i;
                NSString *nameSnapshot = item.name;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setStatus:WQLocalizedFormat(@"Cleaning %lu of %lu: %@", (unsigned long)idxSnapshot, (unsigned long)selected.count, nameSnapshot)];
                });
            }
            for (WQCacheTargetRecord *record in item.targetRecords) {
                if (cancellation.isCancelled) { cancelled = YES; break; }
                NSString *reason = nil;
                if (!WQCacheValidateItem(item, &reason)) {
                    allOk = NO;
                    validationFailure = [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];
                    wq_log(@"clean: stopped before %@ because %@", record.path, reason ?: @"identity validation failed");
                    break;
                }
                if (!wq_purge_contents_cancellable(record.path, &freed, cancellation)) {
                    allOk = NO;
                    if (cancellation.isCancelled) { cancelled = YES; break; }
                }
            }
            if (validationFailure || cancelled) break;
        }
        wq_log(@"clean: freed %llu bytes, allOk=%d cancelled=%d", freed, allOk, cancelled);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_cleaning = NO;
            self->_cleanCancellation = nil;
            if (cancelled) {
                self->_status = nil;
                [self rescanAfterClean:YES];
                self->_result = WQLocalizedFormat(@"Stopped. Freed %@.%@", wq_size_text(freed),
                                 allOk ? @"" : WQLocalized(@" Some items could not be removed (see Log)."));
                return;
            }
            if (validationFailure) {
                self->_scanLimited = YES;
                self->_cleanRequiresRescan = YES;
                self->_status = nil;
                BOOL rescanned = [self rescanAfterClean:NO];
                self->_result = WQLocalizedFormat(@"Clean stopped: %@. Scan again before retrying.", validationFailure);
                if (rescanned) return;
                [self.tableView reloadData];
                [self updateButtons];
            } else {
                self->_status = nil;
                [self rescanAfterClean:YES];
                self->_result = WQLocalizedFormat(@"Freed %@.%@", wq_size_text(freed),
                                 allOk ? @"" : WQLocalized(@" Some items could not be removed (see Log)."));
                UITableViewCell *summaryCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
                if (summaryCell) wq_motion_trigger_scan_sweep(summaryCell.contentView);
            }
        });
    });
}

- (void)scrollViewDidScroll:(UIScrollView *__unused)scrollView
{
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *__unused)scrollView
{
}

- (void)scrollViewDidEndDragging:(UIScrollView *__unused)scrollView willDecelerate:(BOOL __unused)decelerate
{
}

@end
