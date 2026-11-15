//
//  WQPosterBoard.m
//  WQ Glass PosterBoard & Wallpaper Studio
//  GPL-3.0-or-later.
//

#import "WQPosterBoard.h"
#import "WQTheme.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQArchive.h"
#import "WQLaunchServices.h"
#import "WQDir.h"
#import "WQLocalization.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>

static NSString *const kPosterBoardBundleID = @"com.apple.PosterBoard";
static NSString *const kPosterStoreRelPath = @"Library/Application Support/PRBPosterExtensionDataStore";

typedef NS_ENUM(NSInteger, WQPosterPickerMode) {
    WQPosterPickerTendies = 1,
    WQPosterPickerPhotoFile = 2,
};

#pragma mark - Container & backup helpers

static NSString *_Nullable wq_pb_docs_backup_root(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return docs.length ? [docs stringByAppendingPathComponent:@"PosterBoardBackups"] : nil;
}

static NSString *_Nullable wq_pb_ls_container(void)
{
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return nil;
    SEL defaultSel = sel_registerName("defaultWorkspace");
    if (![wsClass respondsToSelector:defaultSel]) return nil;
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass, defaultSel);
    if (!ws) return nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySel = sel_registerName("applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySel]) {
        id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(proxyClass, proxySel, kPosterBoardBundleID);
        SEL urlSel = sel_registerName("dataContainerURL");
        if (proxy && [proxy respondsToSelector:urlSel]) {
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, urlSel);
            if ([url isKindOfClass:NSURL.class] && url.path.length) return url.path;
        }
    }
    return nil;
}

static NSString *_Nullable wq_pb_find_container(void)
{
    // 1. Direct container paths from LaunchServices database snapshot.
    NSArray<NSString *> *paths = wq_ls_container_paths(nil);
    for (NSString *path in paths) {
        NSString *bid = wq_bundle_id_for_container(path) ?: wq_container_label(path);
        if ([bid isEqualToString:kPosterBoardBundleID]) return path;
    }

    // 2. Live LSApplicationProxy lookup.
    NSString *lsPath = wq_pb_ls_container();
    if (lsPath.length) {
        wq_grant(lsPath);
        return lsPath;
    }

    // 3. Worse-query enumeration of Data/Application fallback.
    NSArray<NSString *> *enumerated = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
    for (NSString *path in enumerated) {
        NSString *label = wq_container_label(path);
        if ([label isEqualToString:kPosterBoardBundleID]) return path;
    }
    return nil;
}

static NSArray<NSString *> *wq_pb_list_backups(void)
{
    NSString *root = wq_pb_docs_backup_root();
    if (!root.length) return @[];
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    if (!items.count) return @[];
    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        NSString *full = [root stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [dirs addObject:name];
        }
    }
    [dirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    return dirs;
}

// Copies a container folder locally to dstLocalDir through WQAccess.
static BOOL wq_pb_export_dir_to_local(NSString *srcContainerDir, NSString *dstLocalDir, NSUInteger *fileCount, NSString **errorText)
{
    NSString *err = nil;
    NSArray<NSString *> *entries = wq_list(srcContainerDir, &err);
    if (!entries) {
        if (errorText) *errorText = err ?: @"Unable to list PosterBoard store";
        return NO;
    }
    NSError *fmErr = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dstLocalDir
                                 withIntermediateDirectories:YES attributes:nil error:&fmErr]) {
        if (errorText) *errorText = fmErr.localizedDescription ?: @"Unable to create backup folder";
        return NO;
    }
    for (NSString *name in entries) {
        NSString *srcChild = [srcContainerDir stringByAppendingPathComponent:name];
        NSString *dstChild = [dstLocalDir stringByAppendingPathComponent:name];
        struct stat st;
        if (!wq_stat(srcChild, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            if (!wq_pb_export_dir_to_local(srcChild, dstChild, fileCount, errorText)) return NO;
        } else if (S_ISREG(st.st_mode)) {
            NSString *copyErr = nil;
            if (!wq_copy_to_local(srcChild, dstChild, &copyErr)) {
                if (errorText) *errorText = copyErr ?: [NSString stringWithFormat:@"Failed backing up %@", name];
                return NO;
            }
            if (fileCount) (*fileCount)++;
        }
    }
    return YES;
}

static NSString *_Nullable wq_pb_create_backup(NSString *storePath, NSUInteger *backedUpFiles, NSString **errorText)
{
    NSString *root = wq_pb_docs_backup_root();
    if (!root.length) {
        if (errorText) *errorText = @"Documents directory unavailable";
        return nil;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *staging = [root stringByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *finalDir = [root stringByAppendingPathComponent:stamp];
    for (NSUInteger suffix = 1; [NSFileManager.defaultManager fileExistsAtPath:finalDir]; suffix++) {
        finalDir = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu", stamp, (unsigned long)suffix]];
    }

    NSUInteger count = 0;
    if (!wq_pb_export_dir_to_local(storePath, staging, &count, errorText)) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        return nil;
    }
    NSError *mvErr = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:staging toPath:finalDir error:&mvErr]) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        if (errorText) *errorText = mvErr.localizedDescription ?: @"Unable to finalize PosterBoard backup";
        return nil;
    }
    if (backedUpFiles) *backedUpFiles = count;
    wq_log(@"posterboard: backed up %lu files to %@", (unsigned long)count, finalDir.lastPathComponent);
    return finalDir;
}

// Finds the inner PRBPosterExtensionDataStore-equivalent root inside an extracted .tendies folder.
static NSString *wq_pb_locate_payload_root(NSString *extractedDir)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *candidates = @[
        [extractedDir stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"],
        [extractedDir stringByAppendingPathComponent:@"PRBPosterExtensionDataStore"],
        [extractedDir stringByAppendingPathComponent:@"com.apple.PosterBoard/Library/Application Support/PRBPosterExtensionDataStore"],
    ];
    for (NSString *cand in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) return cand;
    }
    // Check one level deep for numbered store folders or descriptor containers.
    NSArray<NSString *> *top = [fm contentsOfDirectoryAtPath:extractedDir error:nil] ?: @[];
    NSMutableArray<NSString *> *nonHidden = [NSMutableArray new];
    for (NSString *entry in top) {
        if ([entry hasPrefix:@"."] || [entry isEqualToString:@"__MACOSX"]) continue;
        [nonHidden addObject:entry];
    }
    if (nonHidden.count == 1) {
        NSString *single = [extractedDir stringByAppendingPathComponent:nonHidden.firstObject];
        NSString *nested = [single stringByAppendingPathComponent:@"PRBPosterExtensionDataStore"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:nested isDirectory:&isDir] && isDir) return nested;
        if ([fm fileExistsAtPath:single isDirectory:&isDir] && isDir &&
            ([nonHidden.firstObject hasPrefix:@"Container"] || [nonHidden.firstObject isEqualToString:@"Descriptors"] || [nonHidden.firstObject isEqualToString:@"Store"])) {
            return single;
        }
    }
    return extractedDir;
}

static NSUInteger wq_pb_count_regular_files_local(NSString *dir)
{
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:dir];
    NSUInteger count = 0;
    for (NSString *rel in en) {
        if ([rel.lastPathComponent hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        NSString *full = [dir stringByAppendingPathComponent:rel];
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && !isDir) count++;
    }
    return count;
}

// Finds candidate wallpaper / asset folders inside PRBPosterExtensionDataStore where a custom photo
// wallpaper can be installed without breaking store structure.
static NSArray<NSString *> *wq_pb_find_wallpaper_targets(NSString *storePath)
{
    NSMutableArray<NSString *> *targets = [NSMutableArray new];
    NSArray<NSString *> *top = wq_list(storePath, nil) ?: @[];
    for (NSString *entry in top) {
        NSString *versionDir = [storePath stringByAppendingPathComponent:entry];
        struct stat st;
        if (!wq_stat(versionDir, &st) || !S_ISDIR(st.st_mode)) continue;
        NSString *extensionsDir = [versionDir stringByAppendingPathComponent:@"Extensions"];
        NSArray<NSString *> *exts = wq_list(extensionsDir, nil) ?: @[];
        for (NSString *ext in exts) {
            if ([ext containsString:@"PhotosPosterProvider"] || [ext containsString:@"CollectionsPoster"] || [ext containsString:@"Wallpaper"]) {
                NSString *extPath = [extensionsDir stringByAppendingPathComponent:ext];
                NSArray<NSString *> *sub = wq_list(extPath, nil) ?: @[];
                for (NSString *item in sub) {
                    if ([item isEqualToString:@"descriptors"] || [item isEqualToString:@"configurations"]) {
                        [targets addObject:[extPath stringByAppendingPathComponent:item]];
                    }
                }
            }
        }
    }
    return targets;
}

static NSUInteger wq_pb_inject_image_into_descriptor_dirs(NSString *parentDir, NSData *jpegData, NSData *pngData, NSString **errorText)
{
    NSUInteger injected = 0;
    NSArray<NSString *> *uuids = wq_list(parentDir, nil) ?: @[];
    for (NSString *uuid in uuids) {
        NSString *descDir = [parentDir stringByAppendingPathComponent:uuid];
        NSString *versionsDir = [descDir stringByAppendingPathComponent:@"versions"];
        NSArray<NSString *> *versions = wq_list(versionsDir, nil) ?: @[];
        for (NSString *ver in versions) {
            NSString *contentsDir = [[versionsDir stringByAppendingPathComponent:ver] stringByAppendingPathComponent:@"contents"];
            NSArray<NSString *> *files = wq_list(contentsDir, nil);
            if (!files) continue;
            for (NSString *file in files) {
                NSString *lower = file.lowercaseString;
                NSString *dest = [contentsDir stringByAppendingPathComponent:file];
                if ([lower hasSuffix:@".jpg"] || [lower hasSuffix:@".jpeg"] || [lower hasSuffix:@".heic"]) {
                    NSString *err = nil;
                    if (wq_write(dest, jpegData, &err)) injected++;
                    else if (errorText && !*errorText) *errorText = err;
                } else if ([lower hasSuffix:@".png"]) {
                    NSString *err = nil;
                    if (wq_write(dest, pngData, &err)) injected++;
                    else if (errorText && !*errorText) *errorText = err;
                }
            }
        }
    }
    return injected;
}

#pragma mark - Controller

@interface WQPosterBoardViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation WQPosterBoardViewController {
    UIScrollView *_scroll;
    UIStackView *_stack;
    UILabel *_containerBadgeLabel;
    UILabel *_storeStatusLabel;
    UILabel *_backupStatusLabel;
    UIImageView *_previewImageView;
    UILabel *_previewCaptionLabel;
    UILabel *_activityLabel;

    UIButton *_importTendiesButton;
    UIButton *_photoWallpaperButton;
    UIButton *_restoreBackupButton;
    UIButton *_browseStoreButton;
    UIButton *_openPosterBoardButton;
    UIButton *_respringButton;

    NSString *_Nullable _containerPath;
    NSString *_Nullable _storePath;
    NSArray<NSString *> *_storeVersions;
    NSArray<NSString *> *_backups;
    BOOL _busy;
    WQPosterPickerMode _pickerMode;
}

- (instancetype)init
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = @"PosterBoard Studio";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"PosterBoard Studio";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self action:@selector(refreshStoreState)];

    [self buildInterface];
    [self refreshStoreState];
}

- (void)buildInterface
{
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = YES;
    wq_theme_apply_scroll_insets(_scroll, 116.0);
    [self.view addSubview:_scroll];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    _stack = [UIStackView new];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 14;
    [_scroll addSubview:_stack];

    UILayoutGuide *guide = _scroll.contentLayoutGuide;
    UILayoutGuide *frameGuide = _scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12],
        [_stack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-24],
        [_stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [_stack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor constant:-32],
    ]];

    // 1. Hero PosterBoard Studio card
    UIVisualEffectView *heroCard = wq_theme_make_glass_card(26, NO);
    UIStackView *heroStack = [UIStackView new];
    heroStack.translatesAutoresizingMaskIntoConstraints = NO;
    heroStack.axis = UILayoutConstraintAxisVertical;
    heroStack.spacing = 10;
    [heroCard.contentView addSubview:heroStack];
    [NSLayoutConstraint activateConstraints:@[
        [heroStack.topAnchor constraintEqualToAnchor:heroCard.contentView.topAnchor constant:18],
        [heroStack.bottomAnchor constraintEqualToAnchor:heroCard.contentView.bottomAnchor constant:-18],
        [heroStack.leadingAnchor constraintEqualToAnchor:heroCard.contentView.leadingAnchor constant:18],
        [heroStack.trailingAnchor constraintEqualToAnchor:heroCard.contentView.trailingAnchor constant:-18],
    ]];

    UIStackView *titleRow = [UIStackView new];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = 12;

    UIImageView *heroIcon = [UIImageView new];
    heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    heroIcon.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *heroCfg = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold];
    heroIcon.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled" withConfiguration:heroCfg];
    heroIcon.tintColor = wq_theme_primary_text();
    [NSLayoutConstraint activateConstraints:@[
        [heroIcon.widthAnchor constraintEqualToConstant:36],
        [heroIcon.heightAnchor constraintEqualToConstant:36],
    ]];

    UIStackView *titleTextStack = [UIStackView new];
    titleTextStack.axis = UILayoutConstraintAxisVertical;
    titleTextStack.spacing = 2;

    UILabel *heroTitle = [UILabel new];
    heroTitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    heroTitle.textColor = wq_theme_primary_text();
    heroTitle.text = @"PosterBoard & Wallpaper Studio";

    _containerBadgeLabel = [UILabel new];
    _containerBadgeLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _containerBadgeLabel.textColor = wq_theme_secondary_text();
    _containerBadgeLabel.numberOfLines = 0;

    [titleTextStack addArrangedSubview:heroTitle];
    [titleTextStack addArrangedSubview:_containerBadgeLabel];
    [titleRow addArrangedSubview:heroIcon];
    [titleRow addArrangedSubview:titleTextStack];
    [heroStack addArrangedSubview:titleRow];

    _storeStatusLabel = [UILabel new];
    _storeStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _storeStatusLabel.textColor = wq_theme_secondary_text();
    _storeStatusLabel.numberOfLines = 0;
    [heroStack addArrangedSubview:_storeStatusLabel];

    _importTendiesButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _importTendiesButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_primary_button(_importTendiesButton, @"Import .tendies Archive", @"archivebox.fill");
    [_importTendiesButton addTarget:self action:@selector(pickTendiesArchive) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_importTendiesButton.heightAnchor constraintEqualToConstant:48],
    ]];
    [heroStack addArrangedSubview:_importTendiesButton];
    [_stack addArrangedSubview:heroCard];

    // 2. Wallpaper Studio + Preview Card
    UIVisualEffectView *wallCard = wq_theme_make_glass_card(24, NO);
    UIStackView *wallStack = [UIStackView new];
    wallStack.translatesAutoresizingMaskIntoConstraints = NO;
    wallStack.axis = UILayoutConstraintAxisVertical;
    wallStack.spacing = 12;
    [wallCard.contentView addSubview:wallStack];
    [NSLayoutConstraint activateConstraints:@[
        [wallStack.topAnchor constraintEqualToAnchor:wallCard.contentView.topAnchor constant:16],
        [wallStack.bottomAnchor constraintEqualToAnchor:wallCard.contentView.bottomAnchor constant:-16],
        [wallStack.leadingAnchor constraintEqualToAnchor:wallCard.contentView.leadingAnchor constant:16],
        [wallStack.trailingAnchor constraintEqualToAnchor:wallCard.contentView.trailingAnchor constant:-16],
    ]];

    UILabel *wallTitle = [UILabel new];
    wallTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    wallTitle.textColor = wq_theme_primary_text();
    wallTitle.text = @"Custom Photo Wallpaper";

    UILabel *wallSub = [UILabel new];
    wallSub.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    wallSub.textColor = wq_theme_secondary_text();
    wallSub.numberOfLines = 0;
    wallSub.text = @"Select any image from Photos or Files. WQ Glass creates a safety backup of PRBPosterExtensionDataStore before applying changes.";

    _previewImageView = [UIImageView new];
    _previewImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _previewImageView.contentMode = UIViewContentModeScaleAspectFill;
    _previewImageView.clipsToBounds = YES;
    _previewImageView.layer.cornerRadius = 16;
    _previewImageView.layer.borderWidth = 0.75;
    _previewImageView.layer.borderColor = wq_theme_rim().CGColor;
    _previewImageView.hidden = YES;
    [NSLayoutConstraint activateConstraints:@[
        [_previewImageView.heightAnchor constraintEqualToConstant:168],
    ]];

    _previewCaptionLabel = [UILabel new];
    _previewCaptionLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    _previewCaptionLabel.textColor = wq_theme_secondary_text();
    _previewCaptionLabel.numberOfLines = 0;
    _previewCaptionLabel.hidden = YES;

    _photoWallpaperButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _photoWallpaperButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_photoWallpaperButton, @"Choose Custom Photo Wallpaper", @"photo.badge.plus.fill");
    [_photoWallpaperButton addTarget:self action:@selector(choosePhotoWallpaper) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_photoWallpaperButton.heightAnchor constraintEqualToConstant:44],
    ]];

    [wallStack addArrangedSubview:wallTitle];
    [wallStack addArrangedSubview:wallSub];
    [wallStack addArrangedSubview:_previewImageView];
    [wallStack addArrangedSubview:_previewCaptionLabel];
    [wallStack addArrangedSubview:_photoWallpaperButton];
    [_stack addArrangedSubview:wallCard];

    // 3. Quick Actions: Open PosterBoard & Respring
    UIVisualEffectView *actionsCard = wq_theme_make_glass_card(24, NO);
    UIStackView *actionsStack = [UIStackView new];
    actionsStack.translatesAutoresizingMaskIntoConstraints = NO;
    actionsStack.axis = UILayoutConstraintAxisVertical;
    actionsStack.spacing = 12;
    [actionsCard.contentView addSubview:actionsStack];
    [NSLayoutConstraint activateConstraints:@[
        [actionsStack.topAnchor constraintEqualToAnchor:actionsCard.contentView.topAnchor constant:16],
        [actionsStack.bottomAnchor constraintEqualToAnchor:actionsCard.contentView.bottomAnchor constant:-16],
        [actionsStack.leadingAnchor constraintEqualToAnchor:actionsCard.contentView.leadingAnchor constant:16],
        [actionsStack.trailingAnchor constraintEqualToAnchor:actionsCard.contentView.trailingAnchor constant:-16],
    ]];

    UILabel *actionsTitle = [UILabel new];
    actionsTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    actionsTitle.textColor = wq_theme_primary_text();
    actionsTitle.text = @"System Actions";

    UIStackView *quickRow = [UIStackView new];
    quickRow.axis = UILayoutConstraintAxisHorizontal;
    quickRow.distribution = UIStackViewDistributionFillEqually;
    quickRow.spacing = 10;

    _openPosterBoardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _openPosterBoardButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_openPosterBoardButton, @"Open PosterBoard", @"arrow.up.forward.app.fill");
    [_openPosterBoardButton addTarget:self action:@selector(openPosterBoardApp) forControlEvents:UIControlEventTouchUpInside];

    _respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _respringButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_respringButton, @"Respring", @"arrow.trianglehead.2.clockwise.rotate.90");
    _respringButton.backgroundColor = wq_theme_active_pill();
    [_respringButton addTarget:self action:@selector(confirmRespring) forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [_openPosterBoardButton.heightAnchor constraintEqualToConstant:44],
        [_respringButton.heightAnchor constraintEqualToConstant:44],
    ]];
    [quickRow addArrangedSubview:_openPosterBoardButton];
    [quickRow addArrangedSubview:_respringButton];

    _browseStoreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _browseStoreButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_browseStoreButton, @"Browse PRBPosterExtensionDataStore", @"folder.fill");
    [_browseStoreButton addTarget:self action:@selector(browseStore) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_browseStoreButton.heightAnchor constraintEqualToConstant:42],
    ]];

    [actionsStack addArrangedSubview:actionsTitle];
    [actionsStack addArrangedSubview:quickRow];
    [actionsStack addArrangedSubview:_browseStoreButton];
    [_stack addArrangedSubview:actionsCard];

    // 4. Safety Backups Card
    UIVisualEffectView *backupCard = wq_theme_make_glass_card(24, NO);
    UIStackView *backupStack = [UIStackView new];
    backupStack.translatesAutoresizingMaskIntoConstraints = NO;
    backupStack.axis = UILayoutConstraintAxisVertical;
    backupStack.spacing = 10;
    [backupCard.contentView addSubview:backupStack];
    [NSLayoutConstraint activateConstraints:@[
        [backupStack.topAnchor constraintEqualToAnchor:backupCard.contentView.topAnchor constant:16],
        [backupStack.bottomAnchor constraintEqualToAnchor:backupCard.contentView.bottomAnchor constant:-16],
        [backupStack.leadingAnchor constraintEqualToAnchor:backupCard.contentView.leadingAnchor constant:16],
        [backupStack.trailingAnchor constraintEqualToAnchor:backupCard.contentView.trailingAnchor constant:-16],
    ]];

    UILabel *backupTitle = [UILabel new];
    backupTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    backupTitle.textColor = wq_theme_primary_text();
    backupTitle.text = @"Safety Backups";

    _backupStatusLabel = [UILabel new];
    _backupStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _backupStatusLabel.textColor = wq_theme_secondary_text();
    _backupStatusLabel.numberOfLines = 0;

    _restoreBackupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _restoreBackupButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_restoreBackupButton, @"Restore Backup", @"arrow.uturn.backward.circle.fill");
    [_restoreBackupButton addTarget:self action:@selector(restoreBackupTapped) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_restoreBackupButton.heightAnchor constraintEqualToConstant:44],
    ]];

    [backupStack addArrangedSubview:backupTitle];
    [backupStack addArrangedSubview:_backupStatusLabel];
    [backupStack addArrangedSubview:_restoreBackupButton];
    [_stack addArrangedSubview:backupCard];

    // 5. Activity / status card
    _activityLabel = [UILabel new];
    _activityLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    _activityLabel.textColor = wq_theme_secondary_text();
    _activityLabel.numberOfLines = 0;
    _activityLabel.textAlignment = NSTextAlignmentCenter;
    _activityLabel.text = @"Ready";
    [_stack addArrangedSubview:_activityLabel];
}

- (void)updateControls
{
    BOOL ready = _storePath.length > 0 && !_busy;
    _importTendiesButton.enabled = ready;
    _photoWallpaperButton.enabled = ready;
    _browseStoreButton.enabled = ready;
    _restoreBackupButton.enabled = ready && _backups.count > 0;
    _openPosterBoardButton.enabled = !_busy;
    _respringButton.enabled = !_busy;
}

- (void)refreshStoreState
{
    if (_busy) return;
    _activityLabel.text = @"Locating com.apple.PosterBoard container…";
    _backups = wq_pb_list_backups();
    [self updateControls];

    dispatch_async(wq_io(), ^{
        NSString *container = wq_pb_find_container();
        NSString *store = nil;
        NSArray<NSString *> *versions = @[];
        if (container.length) {
            wq_grant(container);
            NSString *candidate = [container stringByAppendingPathComponent:kPosterStoreRelPath];
            struct stat st;
            if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) {
                store = candidate;
                wq_grant(store);
                versions = wq_list(store, nil) ?: @[];
            }
        }
        NSArray<NSString *> *backups = wq_pb_list_backups();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_containerPath = container;
            self->_storePath = store;
            self->_storeVersions = versions;
            self->_backups = backups;

            if (store.length) {
                self->_containerBadgeLabel.text = [NSString stringWithFormat:@"%@ · %lu store folder(s)",
                    kPosterBoardBundleID, (unsigned long)versions.count];
                self->_storeStatusLabel.text = store;
            } else if (container.length) {
                self->_containerBadgeLabel.text = @"Container found · Data store missing";
                self->_storeStatusLabel.text = [NSString stringWithFormat:@"Found container (%@), but PRBPosterExtensionDataStore is not reachable yet.", container.lastPathComponent];
            } else {
                self->_containerBadgeLabel.text = @"PosterBoard container unavailable";
                self->_storeStatusLabel.text = @"Could not locate com.apple.PosterBoard Data/Application container. Check App Group health in Settings or run a container refresh.";
            }

            if (backups.count) {
                self->_backupStatusLabel.text = [NSString stringWithFormat:@"%lu safety backup(s) stored in Documents/PosterBoardBackups.\nLatest: %@",
                    (unsigned long)backups.count, backups.firstObject];
            } else {
                self->_backupStatusLabel.text = @"No PosterBoard backups yet. A safety backup is created automatically before applying any .tendies or photo wallpaper.";
            }
            self->_activityLabel.text = store.length ? @"PosterBoard store ready" : @"Waiting for PosterBoard container";
            [self updateControls];
        });
    });
}

#pragma mark - Import .tendies

- (void)pickTendiesArchive
{
    if (_busy || !_storePath.length) return;
    _pickerMode = WQPosterPickerTendies;
    NSArray<UTType *> *types = @[UTTypeZIP, UTTypeArchive, UTTypeData];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)applyTendiesAtLocalURL:(NSURL *)url
{
    NSString *storePath = _storePath;
    if (!storePath.length) return;
    _busy = YES;
    _activityLabel.text = [NSString stringWithFormat:@"Extracting %@…", url.lastPathComponent];
    [self updateControls];

    dispatch_async(wq_io(), ^{
        NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"tendies-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *err = nil;
        NSUInteger extractedFiles = 0;
        NSUInteger skippedLinks = 0;
        BOOL ok = wq_zip_extract(url.path, staging, wq_archive_posix_io(),
                                 512ULL * 1024ULL * 1024ULL, nil, nil,
                                 &extractedFiles, &skippedLinks, &err);
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];

        NSString *backupName = nil;
        NSUInteger backedFiles = 0;
        if (ok) {
            NSString *payloadRoot = wq_pb_locate_payload_root(staging);
            NSUInteger payloadFiles = wq_pb_count_regular_files_local(payloadRoot);
            if (payloadFiles == 0) {
                ok = NO;
                err = @"Archive contained no importable files.";
            } else {
                NSString *backupDir = wq_pb_create_backup(storePath, &backedFiles, &err);
                if (!backupDir) {
                    ok = NO;
                } else {
                    backupName = backupDir.lastPathComponent;
                    ok = wq_copy_contents(payloadRoot, storePath, &err);
                }
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        NSArray<NSString *> *backups = wq_pb_list_backups();

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_backups = backups;
            [self updateControls];
            if (ok) {
                self->_activityLabel.text = [NSString stringWithFormat:@"Applied %lu file(s) · Backup %@",
                    (unsigned long)extractedFiles, backupName ?: @"-"];
                wq_alert(self, WQVerbatim(@"PosterBoard Updated"),
                         WQVerbatim([NSString stringWithFormat:@"Imported %lu file(s) into PRBPosterExtensionDataStore.\n\nSafety backup saved: %@ (%lu files).\n\nTap Open PosterBoard or Respring to see the changes.",
                                     (unsigned long)extractedFiles, backupName ?: @"-", (unsigned long)backedFiles]));
                [self refreshStoreState];
            } else {
                self->_activityLabel.text = [NSString stringWithFormat:@"Import failed: %@", err ?: @"unknown error"];
                wq_alert(self, WQVerbatim(@"Import Failed"), WQVerbatim(err ?: @"Unable to import .tendies archive."));
            }
        });
    });
}

#pragma mark - Custom Photo Wallpaper

- (void)choosePhotoWallpaper
{
    if (_busy || !_storePath.length) return;
    UIAlertController *sheet = wq_alert_controller(@"Custom Photo Wallpaper",
        @"Choose where to pick your wallpaper image from:", UIAlertControllerStyleActionSheet);
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        UIImagePickerController *picker = [UIImagePickerController new];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.delegate = self;
        picker.allowsEditing = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files App" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        self->_pickerMode = WQPosterPickerPhotoFile;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _photoWallpaperButton;
    sheet.popoverPresentationController.sourceRect = _photoWallpaperButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyWallpaperImage:(UIImage *)image label:(NSString *)label
{
    if (!image || !_storePath.length) return;
    _previewImageView.image = image;
    _previewImageView.hidden = NO;
    _previewCaptionLabel.text = [NSString stringWithFormat:@"Selected: %@ (%.0f × %.0f px)",
        label ?: @"Wallpaper", image.size.width * image.scale, image.size.height * image.scale];
    _previewCaptionLabel.hidden = NO;

    NSData *jpegData = UIImageJPEGRepresentation(image, 0.94);
    NSData *pngData = UIImagePNGRepresentation(image);
    if (!jpegData || !pngData) {
        wq_alert(self, WQVerbatim(@"Wallpaper Error"), WQVerbatim(@"Unable to encode the selected image."));
        return;
    }

    NSString *storePath = _storePath;
    _busy = YES;
    _activityLabel.text = @"Backing up PosterBoard and preparing wallpaper…";
    [self updateControls];

    dispatch_async(wq_io(), ^{
        NSString *err = nil;
        NSUInteger backedFiles = 0;
        NSString *backupDir = wq_pb_create_backup(storePath, &backedFiles, &err);
        NSUInteger updatedSlots = 0;
        if (backupDir) {
            NSArray<NSString *> *targets = wq_pb_find_wallpaper_targets(storePath);
            for (NSString *targetDir in targets) {
                updatedSlots += wq_pb_inject_image_into_descriptor_dirs(targetDir, jpegData, pngData, &err);
            }
            // Also save a clean copy in Documents/PosterBoardBackups/Wallpapers for easy manual inspection/reuse.
            NSString *wallDir = [wq_pb_docs_backup_root() stringByAppendingPathComponent:@"Wallpapers"];
            [NSFileManager.defaultManager createDirectoryAtPath:wallDir withIntermediateDirectories:YES attributes:nil error:nil];
            [jpegData writeToFile:[wallDir stringByAppendingPathComponent:@"CustomWallpaper.jpg"] atomically:YES];
        }
        NSArray<NSString *> *backups = wq_pb_list_backups();

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_backups = backups;
            [self updateControls];
            if (!backupDir) {
                self->_activityLabel.text = [NSString stringWithFormat:@"Backup failed: %@", err ?: @"unknown error"];
                wq_alert(self, WQVerbatim(@"Backup Failed"), WQVerbatim(err ?: @"Could not back up PRBPosterExtensionDataStore."));
                return;
            }
            if (updatedSlots > 0) {
                self->_activityLabel.text = [NSString stringWithFormat:@"Injected wallpaper into %lu slot(s) · Backup %@",
                    (unsigned long)updatedSlots, backupDir.lastPathComponent];
                wq_alert(self, WQVerbatim(@"Wallpaper Applied"),
                         WQVerbatim([NSString stringWithFormat:@"Updated %lu PosterBoard wallpaper image asset(s) and created safety backup %@.\n\nTap Open PosterBoard or Respring to apply.",
                                     (unsigned long)updatedSlots, backupDir.lastPathComponent]));
            } else {
                self->_activityLabel.text = [NSString stringWithFormat:@"Backup saved (%@) · No direct slot image replaced", backupDir.lastPathComponent];
                wq_alert(self, WQVerbatim(@"Wallpaper Staged"),
                         WQVerbatim([NSString stringWithFormat:@"Safety backup %@ (%lu files) created.\n\nNo existing PhotosPosterProvider / CollectionsPoster descriptor image slots were found to replace automatically. Create a photo lock screen first in PosterBoard or tap Browse PRBPosterExtensionDataStore.",
                                     backupDir.lastPathComponent, (unsigned long)backedFiles]));
            }
            [self refreshStoreState];
        });
    });
}

#pragma mark - Restore Backup

- (void)restoreBackupTapped
{
    if (_busy || !_storePath.length || !_backups.count) return;
    if (_backups.count == 1) {
        [self confirmRestoreBackup:_backups.firstObject];
        return;
    }
    UIAlertController *sheet = wq_alert_controller(@"Restore PosterBoard Backup",
        @"Choose which safety backup snapshot to restore into PRBPosterExtensionDataStore:", UIAlertControllerStyleActionSheet);
    NSUInteger shown = 0;
    for (NSString *name in _backups) {
        if (shown++ >= 6) break;
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            [self confirmRestoreBackup:name];
        }]];
    }
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _restoreBackupButton;
    sheet.popoverPresentationController.sourceRect = _restoreBackupButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestoreBackup:(NSString *)backupName
{
    UIAlertController *alert = wq_alert_controller(@"Restore Backup?",
        [NSString stringWithFormat:@"Overwrite PRBPosterExtensionDataStore contents with snapshot %@?", backupName],
        UIAlertControllerStyleAlert);
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self performRestoreBackup:backupName];
    }]];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performRestoreBackup:(NSString *)backupName
{
    NSString *storePath = _storePath;
    NSString *backupDir = [wq_pb_docs_backup_root() stringByAppendingPathComponent:backupName];
    if (!storePath.length || !backupDir.length) return;

    _busy = YES;
    _activityLabel.text = [NSString stringWithFormat:@"Restoring %@…", backupName];
    [self updateControls];

    dispatch_async(wq_io(), ^{
        NSString *err = nil;
        BOOL ok = wq_pb_count_regular_files_local(backupDir) > 0;
        if (!ok) {
            err = @"Backup folder is empty.";
        } else {
            ok = wq_copy_contents(backupDir, storePath, &err);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            [self updateControls];
            if (ok) {
                self->_activityLabel.text = [NSString stringWithFormat:@"Restored %@", backupName];
                wq_alert(self, WQVerbatim(@"Backup Restored"),
                         WQVerbatim([NSString stringWithFormat:@"Restored %@ to PRBPosterExtensionDataStore.\n\nTap Open PosterBoard or Respring to apply.", backupName]));
                [self refreshStoreState];
            } else {
                self->_activityLabel.text = [NSString stringWithFormat:@"Restore failed: %@", err ?: @"unknown error"];
                wq_alert(self, WQVerbatim(@"Restore Failed"), WQVerbatim(err ?: @"Unable to restore backup."));
            }
        });
    });
}

#pragma mark - Open PosterBoard & Respring

- (void)openPosterBoardApp
{
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = sel_registerName("defaultWorkspace");
    SEL openSel = sel_registerName("openApplicationWithBundleID:");
    BOOL opened = NO;
    if (wsClass && [wsClass respondsToSelector:defaultSel]) {
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass, defaultSel);
        if (ws && [ws respondsToSelector:openSel]) {
            opened = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(ws, openSel, kPosterBoardBundleID);
        }
    }
    wq_log(@"posterboard: openApplicationWithBundleID:%@ -> %@", kPosterBoardBundleID, opened ? @"YES" : @"NO");
    if (!opened) {
        wq_alert(self, WQVerbatim(@"Unable to Open PosterBoard"),
                 WQVerbatim(@"iOS refused launching com.apple.PosterBoard from this app profile. Lock and unlock your device or swipe down the Lock Screen to preview posters."));
    }
}

- (void)confirmRespring
{
    UIAlertController *alert = wq_alert_controller(@"Respring Device?",
        @"Restart SpringBoard so newly applied PosterBoard descriptors and lock screen wallpapers take effect right away.",
        UIAlertControllerStyleAlert);
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self triggerRespring];
    }]];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)triggerRespring
{
    _activityLabel.text = @"Sending SpringBoard relaunch signal…";
    wq_log(@"posterboard: triggering respring");

    // Load FrontBoardServices/SpringBoardServices if available and attempt SBSRelaunchAction.
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);

    BOOL dispatchedAction = NO;
    Class relaunchCls = NSClassFromString(@"SBSRelaunchAction");
    Class fbsCls = NSClassFromString(@"FBSSystemService");
    SEL relaunchSel = sel_registerName("actionWithReason:options:targetURL:");
    SEL sharedSel = sel_registerName("sharedService");
    SEL sendSel = sel_registerName("sendActions:withResult:");
    if (relaunchCls && fbsCls &&
        [relaunchCls respondsToSelector:relaunchSel] &&
        [fbsCls respondsToSelector:sharedSel]) {
        id action = ((id (*)(id, SEL, NSString *, NSUInteger, NSURL *_Nullable))objc_msgSend)(
            relaunchCls, relaunchSel, @"RestartRenderServer", (1UL << 1), nil);
        id service = ((id (*)(id, SEL))objc_msgSend)(fbsCls, sharedSel);
        if (action && service && [service respondsToSelector:sendSel]) {
            ((void (*)(id, SEL, NSSet *, id _Nullable))objc_msgSend)(
                service, sendSel, [NSSet setWithObject:action], nil);
            dispatchedAction = YES;
        }
    }

    // Post standard Darwin notifications to nudge wallpaper/backboard reload where permitted.
    typedef uint32_t (*wq_notify_post_fn)(const char *);
    wq_notify_post_fn notifyPost = (wq_notify_post_fn)dlsym(RTLD_DEFAULT, "notify_post");
    if (notifyPost) {
        notifyPost("com.apple.backboardd.reload");
        notifyPost("com.apple.springboard.reload");
        notifyPost("com.apple.PosterBoard.reload");
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_activityLabel.text = dispatchedAction ? @"Respring request dispatched" : @"Reload notifications posted";
        wq_alert(self, WQVerbatim(@"Respring Triggered"),
                 WQVerbatim(@"The reload signal was sent. If your iOS sandbox prevents restarting SpringBoard directly, tap Open PosterBoard or lock/unlock your device to apply changes."));
    });
}

- (void)browseStore
{
    if (!_storePath.length) return;
    WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:_storePath title:@"PRBPosterExtensionDataStore"];
    [self.navigationController pushViewController:dir animated:YES];
}

#pragma mark - Pickers

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    [controller dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (_pickerMode == WQPosterPickerTendies) {
        [self applyTendiesAtLocalURL:url];
    } else if (_pickerMode == WQPosterPickerPhotoFile) {
        UIImage *image = [UIImage imageWithContentsOfFile:url.path];
        NSString *name = url.lastPathComponent;
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        if (image) {
            [self applyWallpaperImage:image label:name];
        } else {
            wq_alert(self, WQVerbatim(@"Invalid Image"), WQVerbatim(@"The selected file could not be opened as an image."));
        }
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info
{
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (image) {
            [self applyWallpaperImage:image label:@"Photo Library Wallpaper"];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end
