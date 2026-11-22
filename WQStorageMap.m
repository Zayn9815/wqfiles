//
//  WQStorageMap.m
//  WQ Glass Visual Storage Analyzer & Category Breakdown (DaisyDisk-Style)
//  GPL-3.0-or-later.
//

#import "WQStorageMap.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQDir.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <string.h>
#import <sys/stat.h>

typedef NS_ENUM(NSInteger, WQStorageCategory) {
    WQStorageCatVideos = 0,
    WQStorageCatImages,
    WQStorageCatDatabases,
    WQStorageCatArchives,
    WQStorageCatAudio,
    WQStorageCatCodeText,
    WQStorageCatOther,
    WQStorageCatCount
};

@interface WQStorageEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) NSUInteger fileCount;
@property (nonatomic) BOOL isDirectory;
@end

@implementation WQStorageEntry
@end

static WQStorageCategory wq_classify_ext(NSString *ext)
{
    NSString *e = ext.lowercaseString;
    if (!e.length) return WQStorageCatOther;
    static NSSet *vid, *img, *db, *arc, *aud, *txt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vid = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"avi", @"webm", @"ts", @"3gp"]];
        img = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"webp", @"bmp", @"tiff", @"tif", @"svg", @"raw", @"dng", @"ico"]];
        db  = [NSSet setWithArray:@[@"sqlite", @"sqlite3", @"db", @"db-wal", @"db-shm", @"realm", @"coredata", @"sqlitedb"]];
        arc = [NSSet setWithArray:@[@"zip", @"ipa", @"tar", @"gz", @"bz2", @"xz", @"7z", @"rar", @"dmg", @"pkg", @"wqenc"]];
        aud = [NSSet setWithArray:@[@"mp3", @"m4a", @"wav", @"aac", @"flac", @"ogg", @"caf", @"aiff", @"opus"]];
        txt = [NSSet setWithArray:@[@"txt", @"json", @"plist", @"xml", @"html", @"htm", @"css", @"js", @"ts", @"m", @"h", @"c", @"cpp", @"swift", @"py", @"sh", @"md", @"log", @"csv", @"yaml", @"yml", @"ini", @"conf", @"pdf"]];
    });
    if ([vid containsObject:e]) return WQStorageCatVideos;
    if ([img containsObject:e]) return WQStorageCatImages;
    if ([db containsObject:e]) return WQStorageCatDatabases;
    if ([arc containsObject:e]) return WQStorageCatArchives;
    if ([aud containsObject:e]) return WQStorageCatAudio;
    if ([txt containsObject:e]) return WQStorageCatCodeText;
    return WQStorageCatOther;
}

static NSString *wq_cat_name(WQStorageCategory c)
{
    switch (c) {
        case WQStorageCatVideos: return WQLocalized(@"Videos");
        case WQStorageCatImages: return WQLocalized(@"Images");
        case WQStorageCatDatabases: return WQLocalized(@"Databases & SQLite");
        case WQStorageCatArchives: return WQLocalized(@"Archives & Packages");
        case WQStorageCatAudio: return WQLocalized(@"Audio");
        case WQStorageCatCodeText: return WQLocalized(@"Documents, Code & Plists");
        default: return WQLocalized(@"Other & Caches");
    }
}

static UIColor *wq_cat_color(WQStorageCategory c)
{
    switch (c) {
        case WQStorageCatVideos: return [UIColor colorWithRed:0.32 green:0.65 blue:1.00 alpha:1.0];
        case WQStorageCatImages: return [UIColor colorWithRed:0.25 green:0.86 blue:0.78 alpha:1.0];
        case WQStorageCatDatabases: return [UIColor colorWithRed:0.68 green:0.52 blue:1.00 alpha:1.0];
        case WQStorageCatArchives: return [UIColor colorWithRed:1.00 green:0.68 blue:0.28 alpha:1.0];
        case WQStorageCatAudio: return [UIColor colorWithRed:1.00 green:0.44 blue:0.66 alpha:1.0];
        case WQStorageCatCodeText: return [UIColor colorWithRed:0.42 green:0.88 blue:0.46 alpha:1.0];
        default: return [UIColor colorWithRed:0.58 green:0.66 blue:0.76 alpha:1.0];
    }
}

static NSString *wq_cat_symbol(WQStorageCategory c)
{
    switch (c) {
        case WQStorageCatVideos: return @"film.fill";
        case WQStorageCatImages: return @"photo.fill";
        case WQStorageCatDatabases: return @"cylinder.split.1x2.fill";
        case WQStorageCatArchives: return @"archivebox.fill";
        case WQStorageCatAudio: return @"waveform";
        case WQStorageCatCodeText: return @"doc.text.fill";
        default: return @"ellipsis.circle.fill";
    }
}

@implementation WQStorageMapViewController {
    NSString *_rootPath;
    NSString *_rootTitle;
    BOOL _scanning;
    WQScanCancellation *_cancel;
    NSString *_statusText;
    unsigned long long _totalBytes;
    NSUInteger _totalFiles;
    unsigned long long _catBytes[WQStorageCatCount];
    NSUInteger _catCounts[WQStorageCatCount];
    NSArray<WQStorageEntry *> *_topEntries;
    UIView *_barStrip;
    UILabel *_headerTotalLabel;
    UILabel *_headerSubLabel;
}

- (instancetype)initWithRootPath:(NSString *)rootPath title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _rootPath = [rootPath copy];
        _rootTitle = title.length ? [title copy] : (rootPath.lastPathComponent.length ? rootPath.lastPathComponent : @"/");
        self.title = WQLocalized(@"Storage Analyzer");
        self.hidesBottomBarWhenPushed = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    wq_theme_apply_scroll_insets(self.tableView, 40.0);
    [self installHeaderCard];
    [self updateNavButtons];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopScan) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self startScan];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self stopScan];
}

- (void)dealloc
{
    [_cancel cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)updateNavButtons
{
    if (_scanning) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Stop")
                                                                                  style:UIBarButtonItemStylePlain
                                                                                 target:self
                                                                                 action:@selector(stopScan)];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                               target:self
                                                                                               action:@selector(startScan)];
    }
}

- (void)installHeaderCard
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 126)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIVisualEffectView *card = wq_theme_make_glass_card(22.0, NO);
    [box addSubview:card];

    _headerTotalLabel = [UILabel new];
    _headerTotalLabel.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightHeavy];
    _headerTotalLabel.textColor = wq_theme_primary_text();
    _headerTotalLabel.text = WQLocalized(@"Analyzing…");

    _headerSubLabel = [UILabel new];
    _headerSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _headerSubLabel.textColor = wq_theme_secondary_text();
    _headerSubLabel.text = _rootTitle;

    _barStrip = [UIView new];
    _barStrip.translatesAutoresizingMaskIntoConstraints = NO;
    _barStrip.backgroundColor = wq_theme_hairline();
    _barStrip.layer.cornerRadius = 7.0;
    _barStrip.clipsToBounds = YES;
    [_barStrip.heightAnchor constraintEqualToConstant:14.0].active = YES;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_headerTotalLabel, _headerSubLabel, _barStrip]];
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 8;
    [card.contentView addSubview:col];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [card.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [col.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:14],
        [col.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-14],
        [col.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
    ]];
    self.tableView.tableHeaderView = box;
}

- (void)rebuildStackedBar
{
    for (UIView *sub in _barStrip.subviews) [sub removeFromSuperview];
    if (_totalBytes == 0) return;
    UIStackView *row = [UIStackView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 1.5;
    row.distribution = UIStackViewDistributionFill;
    [_barStrip addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:_barStrip.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_barStrip.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_barStrip.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_barStrip.trailingAnchor],
    ]];
    UIView *firstBar = nil;
    double firstFrac = 0;
    for (NSInteger i = 0; i < WQStorageCatCount; i++) {
        if (_catBytes[i] == 0) continue;
        double frac = (double)_catBytes[i] / (double)_totalBytes;
        if (frac < 0.015) continue;
        UIView *seg = [UIView new];
        seg.backgroundColor = wq_cat_color((WQStorageCategory)i);
        [row addArrangedSubview:seg];
        if (!firstBar) {
            firstBar = seg;
            firstFrac = frac;
        } else if (firstFrac > 0) {
            [seg.widthAnchor constraintEqualToAnchor:firstBar.widthAnchor multiplier:(CGFloat)(frac / firstFrac)].active = YES;
        }
    }
}

- (void)stopScan
{
    [_cancel cancel];
    if (_scanning) {
        _scanning = NO;
        _statusText = nil;
        [self updateNavButtons];
    }
}

- (void)startScan
{
    [_cancel cancel];
    WQScanCancellation *cancel = [WQScanCancellation new];
    _cancel = cancel;
    _scanning = YES;
    _statusText = WQLocalized(@"Scanning folders & file categories…");
    _totalBytes = 0;
    _totalFiles = 0;
    memset(_catBytes, 0, sizeof(_catBytes));
    memset(_catCounts, 0, sizeof(_catCounts));
    _topEntries = @[];
    _headerTotalLabel.text = WQLocalized(@"Analyzing…");
    _headerSubLabel.text = _statusText;
    [self rebuildStackedBar];
    [self updateNavButtons];
    [self.tableView reloadData];

    NSString *root = _rootPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static NSSet<NSString *> *containerParents;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            containerParents = [NSSet setWithArray:@[
                @"/private/var/mobile/Containers/Data/Application",
                @"/private/var/mobile/Containers/Shared/AppGroup",
                @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                @"/private/var/mobile/Containers/Data/InternalDaemon",
            ]];
        });
        BOOL isContainerParent = [containerParents containsObject:root];
        if (isContainerParent && !wq_display_names_loaded()) wq_load_display_names();

        typedef struct {
            unsigned long long bytes[WQStorageCatCount];
            NSUInteger counts[WQStorageCatCount];
        } WQStorageCatTotals;
        WQStorageCatTotals totals;
        memset(&totals, 0, sizeof(totals));
        NSMutableArray<WQStorageEntry *> *topBuckets = [NSMutableArray new];
        unsigned long long grandBytes = 0;
        NSUInteger grandFiles = 0;
        NSUInteger visited = 0;
        CFAbsoluteTime lastPing = 0;

        NSArray<NSString *> *directChildren = nil;
        if (isContainerParent) {
            directChildren = wq_enumerate(root, 0, nil, nil) ?: @[];
        } else {
            wq_grant(root);
            NSArray<NSString *> *names = wq_list(root, NULL) ?: @[];
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:names.count];
            for (NSString *n in names) [paths addObject:[root stringByAppendingPathComponent:n]];
            directChildren = paths;
        }

        for (NSString *childPath in directChildren) {
            if (cancel.isCancelled || visited >= 300000) break;
            if (isContainerParent) wq_grant(childPath);
            struct stat st;
            if (!wq_stat(childPath, &st)) continue;

            WQStorageEntry *entry = [WQStorageEntry new];
            entry.path = childPath;
            entry.isDirectory = S_ISDIR(st.st_mode);
            if (isContainerParent) {
                NSString *bid = wq_container_label(childPath);
                entry.displayName = wq_display_name(bid) ?: bid ?: childPath.lastPathComponent;
            } else {
                entry.displayName = childPath.lastPathComponent;
            }

            if (S_ISREG(st.st_mode)) {
                unsigned long long sz = (unsigned long long)MAX(0LL, st.st_size);
                entry.bytes = sz;
                entry.fileCount = 1;
                WQStorageCategory cat = wq_classify_ext(childPath.pathExtension);
                totals.bytes[cat] += sz;
                totals.counts[cat] += 1;
                grandBytes += sz;
                grandFiles += 1;
                visited++;
            } else if (S_ISDIR(st.st_mode)) {
                NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:childPath];
                while (stack.count && !cancel.isCancelled && visited < 300000) {
                    @autoreleasepool {
                        NSString *dir = stack.lastObject;
                        [stack removeLastObject];
                        NSArray<NSString *> *names = wq_list(dir, NULL);
                        for (NSString *n in names) {
                            if (cancel.isCancelled) break;
                            NSString *p = [dir stringByAppendingPathComponent:n];
                            struct stat cst;
                            if (lstat(p.fileSystemRepresentation, &cst) != 0) {
                                if (!wq_stat(p, &cst)) continue;
                            }
                            if (S_ISLNK(cst.st_mode)) continue;
                            visited++;
                            if (S_ISDIR(cst.st_mode)) {
                                [stack addObject:p];
                            } else if (S_ISREG(cst.st_mode)) {
                                unsigned long long sz = (unsigned long long)MAX(0LL, cst.st_size);
                                entry.bytes += sz;
                                entry.fileCount += 1;
                                WQStorageCategory cat = wq_classify_ext(n.pathExtension);
                                totals.bytes[cat] += sz;
                                totals.counts[cat] += 1;
                                grandBytes += sz;
                                grandFiles += 1;
                            }
                        }
                        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                        if (now - lastPing > 0.35) {
                            lastPing = now;
                            unsigned long long snapB = grandBytes;
                            NSUInteger snapF = grandFiles;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                WQStorageMapViewController *me = weakSelf;
                                if (!me || cancel.isCancelled) return;
                                me->_headerTotalLabel.text = wq_size_text(snapB);
                                me->_headerSubLabel.text = WQLocalizedFormat(@"Scanning… %lu files analyzed", (unsigned long)snapF);
                            });
                        }
                    }
                }
            }
            if (entry.bytes > 0) [topBuckets addObject:entry];
        }

        [topBuckets sortUsingComparator:^NSComparisonResult(WQStorageEntry *a, WQStorageEntry *b) {
            if (a.bytes > b.bytes) return NSOrderedAscending;
            if (a.bytes < b.bytes) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSArray<WQStorageEntry *> *trimmed = topBuckets.count > 40 ? [topBuckets subarrayWithRange:NSMakeRange(0, 40)] : topBuckets;

        dispatch_async(dispatch_get_main_queue(), ^{
            WQStorageMapViewController *me = weakSelf;
            if (!me) return;
            me->_scanning = NO;
            me->_statusText = nil;
            me->_totalBytes = grandBytes;
            me->_totalFiles = grandFiles;
            memcpy(me->_catBytes, totals.bytes, sizeof(me->_catBytes));
            memcpy(me->_catCounts, totals.counts, sizeof(me->_catCounts));
            me->_topEntries = trimmed;
            me->_headerTotalLabel.text = wq_size_text(grandBytes);
            me->_headerSubLabel.text = WQLocalizedFormat(@"%@ · %lu files%@", me->_rootTitle, (unsigned long)grandFiles,
                                                         cancel.isCancelled ? WQLocalized(@" (stopped)") : @"");
            [me rebuildStackedBar];
            [me updateNavButtons];
            [me.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return WQStorageCatCount;
    return MAX(1, (NSInteger)_topEntries.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Category Breakdown");
    return WQLocalized(@"Largest Folders & Files (Tap Folder to Drill Down)");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"smap-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"smap-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];

    if (indexPath.section == 0) {
        WQStorageCategory cat = (WQStorageCategory)indexPath.row;
        unsigned long long b = _catBytes[cat];
        double pct = _totalBytes > 0 ? ((double)b * 100.0 / (double)_totalBytes) : 0.0;
        c.text = wq_cat_name(cat);
        c.secondaryText = [NSString stringWithFormat:@"%@ · %.1f%% (%lu files)", wq_size_text(b), pct, (unsigned long)_catCounts[cat]];
        c.image = [UIImage systemImageNamed:wq_cat_symbol(cat)];
        c.imageProperties.tintColor = wq_cat_color(cat);
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (!_topEntries.count) {
        c.text = _scanning ? WQLocalized(@"Analyzing storage…") : WQLocalized(@"No files measured");
        c.secondaryText = nil;
        c.image = nil;
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    WQStorageEntry *e = _topEntries[(NSUInteger)indexPath.row];
    double pct = _totalBytes > 0 ? ((double)e.bytes * 100.0 / (double)_totalBytes) : 0.0;
    c.text = e.displayName;
    c.secondaryText = e.isDirectory
        ? [NSString stringWithFormat:@"%@ · %.1f%% · %lu files", wq_size_text(e.bytes), pct, (unsigned long)e.fileCount]
        : [NSString stringWithFormat:@"%@ · %.1f%%", wq_size_text(e.bytes), pct];
    c.image = [UIImage systemImageNamed:e.isDirectory ? @"folder.fill" : @"doc.fill"];
    c.imageProperties.tintColor = e.isDirectory ? wq_theme_accent() : wq_theme_secondary_text();
    cell.contentConfiguration = c;
    cell.accessoryType = e.isDirectory ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || !_topEntries.count) return;
    WQStorageEntry *e = _topEntries[(NSUInteger)indexPath.row];
    wq_haptic_selection();
    if (e.isDirectory) {
        UIAlertController *sheet = wq_alert_controller(WQVerbatim(e.displayName), wq_size_text(e.bytes), UIAlertControllerStyleActionSheet);
        [sheet addAction:wq_alert_action(WQLocalized(@"Drill Down in Storage Analyzer"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            WQStorageMapViewController *sub = [[WQStorageMapViewController alloc] initWithRootPath:e.path title:e.displayName];
            [self.navigationController pushViewController:sub animated:YES];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Open Folder in Browser"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:e.path title:e.displayName];
            [self.navigationController pushViewController:dir animated:YES];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
    } else {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:e.path.stringByDeletingLastPathComponent title:nil];
        [self.navigationController pushViewController:dir animated:YES];
    }
}

@end
