//
//  WQDuplicates.m
//  WQ Glass Smart 3-Stage Duplicate File Hunter (QOS_CLASS_UTILITY)
//  GPL-3.0-or-later.
//

#import "WQDuplicates.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

static const unsigned long long kWQDuplicateMinBytes = 128ULL * 1024ULL;   // 128 KB threshold

@interface WQDupFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic) unsigned long long size;
@property (nonatomic) NSTimeInterval modified;
@property (nonatomic) BOOL selectedForDelete;
@end
@implementation WQDupFile
@end

@interface WQDupGroup : NSObject
@property (nonatomic, copy) NSString *sha256;
@property (nonatomic) unsigned long long fileSize;
@property (nonatomic, strong) NSMutableArray<WQDupFile *> *files;
@end
@implementation WQDupGroup
@end

static NSString *_Nullable wq_dup_hash_file(NSString *path, size_t maxBytes, WQScanCancellation *cancel)
{
    int fd = wq_open_for_reading(path);
    if (fd < 0) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[64 * 1024];
    size_t remaining = maxBytes;
    BOOL ok = YES;
    for (;;) {
        if (cancel.isCancelled) { ok = NO; break; }
        size_t want = (maxBytes > 0 && remaining < sizeof(buf)) ? remaining : sizeof(buf);
        if (maxBytes > 0 && want == 0) break;
        ssize_t n = read(fd, buf, want);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = NO; break; }
        if (n == 0) break;
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
        if (maxBytes > 0) remaining -= (size_t)n;
    }
    close(fd);
    if (!ok) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

@implementation WQDuplicatesViewController {
    NSString *_rootPath;
    NSArray<WQDupGroup *> *_groups;
    NSString *_statusText;
    BOOL _scanning;
    WQScanCancellation *_cancellation;
}

- (instancetype)initWithRootPath:(NSString *)rootPath title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _rootPath = [rootPath copy];
        self.title = title ?: WQLocalized(@"Duplicate Hunter");
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
    wq_theme_apply_scroll_insets(self.tableView, 48.0);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelScan)
                                               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self startScan];
}

- (void)dealloc
{
    [_cancellation cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self cancelScan];
}

- (void)cancelScan
{
    [_cancellation cancel];
    if (_scanning) {
        _scanning = NO;
        _statusText = WQLocalized(@"Scan stopped.");
        [self updateNavButtons];
        [self.tableView reloadData];
    }
}

- (unsigned long long)selectedReclaimableBytes
{
    unsigned long long sum = 0;
    for (WQDupGroup *g in _groups) {
        for (WQDupFile *f in g.files) {
            if (f.selectedForDelete) sum += f.size;
        }
    }
    return sum;
}

- (void)updateNavButtons
{
    if (_scanning) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:WQLocalized(@"Stop") style:UIBarButtonItemStylePlain target:self action:@selector(cancelScan)];
        return;
    }
    if (!_groups.count) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(startScan)];
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:WQLocalized(@"Keep Newest (Select Older)") image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf autoSelectKeepNewest:YES];
        }],
        [UIAction actionWithTitle:WQLocalized(@"Keep Oldest (Select Newer)") image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf autoSelectKeepNewest:NO];
        }],
        [UIAction actionWithTitle:WQLocalized(@"Delete Selected Duplicates…") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf confirmDeleteSelected];
        }],
        [UIAction actionWithTitle:WQLocalized(@"Rescan") image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf startScan];
        }],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
}

- (void)autoSelectKeepNewest:(BOOL)keepNewest
{
    for (WQDupGroup *g in _groups) {
        [g.files sortUsingComparator:^NSComparisonResult(WQDupFile *a, WQDupFile *b) {
            if (a.modified == b.modified) return [a.path compare:b.path];
            return keepNewest
                ? (a.modified > b.modified ? NSOrderedAscending : NSOrderedDescending)
                : (a.modified < b.modified ? NSOrderedAscending : NSOrderedDescending);
        }];
        for (NSUInteger i = 0; i < g.files.count; i++) {
            g.files[i].selectedForDelete = (i > 0);
        }
    }
    wq_haptic_selection();
    [self.tableView reloadData];
}

- (void)confirmDeleteSelected
{
    if (wq_refuse_if_deleting_off(self)) return;
    NSMutableArray<WQDupFile *> *targets = [NSMutableArray new];
    unsigned long long total = 0;
    for (WQDupGroup *g in _groups) {
        NSUInteger kept = 0;
        for (WQDupFile *f in g.files) if (!f.selectedForDelete) kept++;
        if (kept == 0) {
            wq_alert(self, WQLocalized(@"Keep at Least One Copy"),
                     WQLocalized(@"Every duplicate group must keep at least one copy unselected."));
            return;
        }
        for (WQDupFile *f in g.files) {
            if (f.selectedForDelete) { [targets addObject:f]; total += f.size; }
        }
    }
    if (!targets.count) {
        wq_alert(self, WQLocalized(@"Nothing Selected"), WQLocalized(@"Tap duplicates to select them or use Keep Newest / Keep Oldest from the menu."));
        return;
    }
    NSString *msg = WQLocalizedFormat(@"Delete %lu duplicate files (%@)? Each deleted file is backed up to Recently Deleted first.",
                                      (unsigned long)targets.count, wq_size_text(total));
    __weak typeof(self) weakSelf = self;
    wq_present_glass_confirm(self, @"Delete Duplicates?", msg, @"Delete", YES, ^{
        [weakSelf performDeleteTargets:targets];
    });
}

- (void)performDeleteTargets:(NSArray<WQDupFile *> *)targets
{
    _statusText = WQLocalized(@"Deleting duplicates…");
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUInteger deleted = 0, failed = 0;
        unsigned long long freed = 0;
        for (WQDupFile *f in targets) {
            NSString *err = nil;
            if (wq_delete(f.path, &err)) { deleted++; freed += f.size; }
            else failed++;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDuplicatesViewController *me = weakSelf;
            if (!me) return;
            wq_haptic_notify(failed ? UINotificationFeedbackTypeWarning : UINotificationFeedbackTypeSuccess);
            wq_alert(me, WQLocalized(@"Duplicates Removed"),
                     WQLocalizedFormat(@"Removed %lu files (%@).%@", (unsigned long)deleted, wq_size_text(freed),
                                       failed ? WQLocalizedFormat(@" %lu could not be deleted.", (unsigned long)failed) : @""));
            [me startScan];
        });
    });
}

- (void)startScan
{
    [_cancellation cancel];
    WQScanCancellation *cancel = [WQScanCancellation new];
    _cancellation = cancel;
    _scanning = YES;
    _groups = @[];
    _statusText = WQLocalized(@"Stage 1/3: Scanning file sizes…");
    [self updateNavButtons];
    [self.tableView reloadData];

    NSString *root = _rootPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        void (^pushStatus)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WQDuplicatesViewController *me = weakSelf;
                if (!me || cancel.isCancelled) return;
                me->_statusText = s;
                [me.tableView reloadData];
            });
        };

        NSMutableArray<NSString *> *pending = [NSMutableArray new];
        NSMutableDictionary<NSString *, NSString *> *appNames = [NSMutableDictionary new];
        NSString *last = root.lastPathComponent;
        BOOL isContainerParent = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:last];
        if (isContainerParent) {
            if (!wq_display_names_loaded()) wq_load_display_names();
            NSArray<NSString *> *containers = wq_enumerate(root, 0, cancel, nil);
            for (NSString *c in containers) {
                if (cancel.isCancelled) break;
                if (wq_grant(c)) {
                    [pending addObject:c];
                    NSString *bid = wq_container_label(c);
                    appNames[c.lastPathComponent] = bid.length ? (wq_display_name(bid) ?: bid) : c.lastPathComponent;
                }
            }
        } else {
            (void)wq_grant(root);
            [pending addObject:root];
        }

        // Stage 1: Group files >= 128 KB by exact byte size.
        NSMutableDictionary<NSNumber *, NSMutableArray<WQDupFile *> *> *bySize = [NSMutableDictionary new];
        NSUInteger walked = 0;
        CFTimeInterval lastPush = CACurrentMediaTime();
        while (pending.count && !cancel.isCancelled && walked < 250000) {
            @autoreleasepool {
                NSString *dir = pending.lastObject;
                [pending removeLastObject];
                NSArray<NSString *> *names = wq_list(dir, NULL);
                for (NSString *n in names) {
                    if (cancel.isCancelled) break;
                    walked++;
                    CFTimeInterval now = CACurrentMediaTime();
                    if (now - lastPush > 0.25) {
                        lastPush = now;
                        pushStatus(WQLocalizedFormat(@"Stage 1/3: %lu files checked…", (unsigned long)walked));
                    }
                    NSString *full = [dir stringByAppendingPathComponent:n];
                    struct stat st;
                    if (!wq_stat(full, &st)) continue;
                    if (S_ISDIR(st.st_mode)) {
                        [pending addObject:full];
                    } else if (S_ISREG(st.st_mode) && (unsigned long long)st.st_size >= kWQDuplicateMinBytes) {
                        WQDupFile *df = [WQDupFile new];
                        df.path = full;
                        df.size = (unsigned long long)st.st_size;
                        df.modified = (NSTimeInterval)st.st_mtimespec.tv_sec;
                        if (isContainerParent) {
                            NSUInteger pref = [root hasSuffix:@"/"] ? root.length : root.length + 1;
                            NSString *rel = full.length > pref ? [full substringFromIndex:pref] : full;
                            NSString *uuid = rel.pathComponents.firstObject;
                            NSString *app = uuid.length ? appNames[uuid] : nil;
                            df.subtitle = app.length ? [NSString stringWithFormat:@"%@ · %@", app, full.stringByDeletingLastPathComponent.lastPathComponent]
                                                     : full.stringByDeletingLastPathComponent.lastPathComponent;
                        } else {
                            df.subtitle = full.stringByDeletingLastPathComponent;
                        }
                        NSNumber *key = @(df.size);
                        NSMutableArray *bucket = bySize[key];
                        if (!bucket) { bucket = [NSMutableArray new]; bySize[key] = bucket; }
                        [bucket addObject:df];
                    }
                }
            }
        }
        if (cancel.isCancelled) return;

        // Stage 2: Partial 8 KB SHA-256 hash on same-size buckets.
        pushStatus(WQLocalized(@"Stage 2/3: Fast 8 KB fingerprint…"));
        NSMutableDictionary<NSString *, NSMutableArray<WQDupFile *> *> *byHead = [NSMutableDictionary new];
        for (NSNumber *szKey in bySize) {
            if (cancel.isCancelled) break;
            NSArray<WQDupFile *> *bucket = bySize[szKey];
            if (bucket.count < 2) continue;
            for (WQDupFile *f in bucket) {
                if (cancel.isCancelled) break;
                @autoreleasepool {
                    NSString *head = wq_dup_hash_file(f.path, 8192, cancel);
                    if (!head.length) continue;
                    NSString *hk = [NSString stringWithFormat:@"%@:%@", szKey, head];
                    NSMutableArray *hb = byHead[hk];
                    if (!hb) { hb = [NSMutableArray new]; byHead[hk] = hb; }
                    [hb addObject:f];
                }
            }
        }
        if (cancel.isCancelled) return;

        // Stage 3: Full SHA-256 verification for head-hash collisions.
        pushStatus(WQLocalized(@"Stage 3/3: Verifying SHA-256…"));
        NSMutableDictionary<NSString *, NSMutableArray<WQDupFile *> *> *byFull = [NSMutableDictionary new];
        for (NSString *hk in byHead) {
            if (cancel.isCancelled) break;
            NSArray<WQDupFile *> *hb = byHead[hk];
            if (hb.count < 2) continue;
            for (WQDupFile *f in hb) {
                if (cancel.isCancelled) break;
                @autoreleasepool {
                    NSString *fullHash = wq_dup_hash_file(f.path, 0, cancel);
                    if (!fullHash.length) continue;
                    NSMutableArray *fb = byFull[fullHash];
                    if (!fb) { fb = [NSMutableArray new]; byFull[fullHash] = fb; }
                    [fb addObject:f];
                }
            }
        }
        if (cancel.isCancelled) return;

        NSMutableArray<WQDupGroup *> *groups = [NSMutableArray new];
        for (NSString *hash in byFull) {
            NSMutableArray<WQDupFile *> *files = byFull[hash];
            if (files.count < 2) continue;
            [files sortUsingComparator:^NSComparisonResult(WQDupFile *a, WQDupFile *b) {
                return a.modified > b.modified ? NSOrderedAscending : (a.modified < b.modified ? NSOrderedDescending : [a.path compare:b.path]);
            }];
            for (NSUInteger i = 0; i < files.count; i++) files[i].selectedForDelete = (i > 0);
            WQDupGroup *g = [WQDupGroup new];
            g.sha256 = hash;
            g.fileSize = files.firstObject.size;
            g.files = files;
            [groups addObject:g];
        }
        [groups sortUsingComparator:^NSComparisonResult(WQDupGroup *a, WQDupGroup *b) {
            unsigned long long wa = a.fileSize * (a.files.count - 1);
            unsigned long long wb = b.fileSize * (b.files.count - 1);
            return wa > wb ? NSOrderedAscending : (wa < wb ? NSOrderedDescending : NSOrderedSame);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            WQDuplicatesViewController *me = weakSelf;
            if (!me || cancel.isCancelled) return;
            me->_scanning = NO;
            me->_groups = groups;
            me->_statusText = groups.count
                ? WQLocalizedFormat(@"Found %lu duplicate sets · %@ reclaimable (files >= 128 KB).",
                                    (unsigned long)groups.count, wq_size_text([me selectedReclaimableBytes]))
                : WQLocalized(@"No duplicate files >= 128 KB found.");
            [me updateNavButtons];
            [me.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView
{
    return _groups.count ? (NSInteger)_groups.count : 1;
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (!_groups.count) return 1;
    return (NSInteger)_groups[(NSUInteger)section].files.count;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (!_groups.count) return WQLocalized(@"Duplicate File Hunter");
    WQDupGroup *g = _groups[(NSUInteger)section];
    return WQLocalizedFormat(@"%@ × %lu copies (Save %@)",
        wq_size_text(g.fileSize), (unsigned long)g.files.count,
        wq_size_text(g.fileSize * (g.files.count - 1)));
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 0 ? _statusText : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dup-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dup-cell"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_groups.count) {
        c.text = _statusText ?: WQLocalized(@"Ready");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    WQDupFile *f = _groups[(NSUInteger)indexPath.section].files[(NSUInteger)indexPath.row];
    c.text = f.path.lastPathComponent;
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryText = f.subtitle;
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    c.secondaryTextProperties.numberOfLines = 2;
    c.image = [UIImage systemImageNamed:f.selectedForDelete ? @"trash.circle.fill" : @"checkmark.shield.fill"];
    c.imageProperties.tintColor = f.selectedForDelete ? UIColor.systemRedColor : wq_theme_aurora_teal();
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_groups.count) return;
    WQDupFile *f = _groups[(NSUInteger)indexPath.section].files[(NSUInteger)indexPath.row];
    f.selectedForDelete = !f.selectedForDelete;
    wq_haptic_selection();
    _statusText = WQLocalizedFormat(@"%lu duplicate sets · %@ selected to remove.",
                                    (unsigned long)_groups.count, wq_size_text([self selectedReclaimableBytes]));
    [tableView reloadData];
}

@end
