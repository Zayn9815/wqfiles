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
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>

static NSString *const kPosterBoardBundleID = @"com.apple.PosterBoard";
static NSString *const kPosterStoreRelPath = @"Library/Application Support/PRBPosterExtensionDataStore";
static NSString *const kDefaultCollectionsProvider = @"com.apple.WallpaperKit.CollectionsPoster";

typedef NS_ENUM(NSInteger, WQPosterPickerMode) {
    WQPosterPickerTendies = 1,
    WQPosterPickerPhotoFile = 2,
};

#pragma mark - Container, grant & backup helpers

static BOOL wq_pb_is_numeric_name(NSString *name)
{
    if (!name.length) return NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static BOOL wq_pb_looks_like_uuid(NSString *name)
{
    if (name.length != 36) return NO;
    return [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static NSString *_Nullable wq_pb_docs_backup_root(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return docs.length ? [docs stringByAppendingPathComponent:@"PosterBoardBackups"] : nil;
}

static void wq_pb_grant_ancestry(NSString *containerPath)
{
    if (!containerPath.length) return;
    wq_grant(containerPath);
    NSString *lib = [containerPath stringByAppendingPathComponent:@"Library"];
    wq_grant(lib);
    NSString *appSupport = [lib stringByAppendingPathComponent:@"Application Support"];
    wq_grant(appSupport);
    wq_grant([appSupport stringByAppendingPathComponent:@"PRBPosterExtensionDataStore"]);
}

static void wq_pb_grant_tree(NSString *dir, NSUInteger depth)
{
    if (!dir.length || depth > 8) return;
    wq_grant(dir);
    NSArray<NSString *> *entries = wq_list(dir, nil);
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        NSString *child = [dir stringByAppendingPathComponent:name];
        struct stat st;
        if (wq_stat(child, &st) && S_ISDIR(st.st_mode)) {
            wq_pb_grant_tree(child, depth + 1);
        }
    }
}

static BOOL wq_pb_ensure_dir(NSString *targetDir, NSString *anchorDir, NSString **errorText)
{
    struct stat st;
    if (wq_stat(targetDir, &st)) {
        if (S_ISDIR(st.st_mode)) {
            wq_grant(targetDir);
            return YES;
        }
        if (errorText) *errorText = [NSString stringWithFormat:@"%@ exists as a file instead of a folder", targetDir.lastPathComponent];
        return NO;
    }
    NSString *normTarget = targetDir.stringByStandardizingPath;
    NSString *normAnchor = anchorDir.stringByStandardizingPath;
    if (![normTarget hasPrefix:normAnchor]) {
        wq_grant(targetDir.stringByDeletingLastPathComponent);
        return wq_create_dir(targetDir, errorText);
    }
    NSString *rel = [normTarget substringFromIndex:normAnchor.length];
    NSArray<NSString *> *parts = [rel pathComponents];
    NSString *cur = normAnchor;
    wq_grant(cur);
    for (NSString *part in parts) {
        if (!part.length || [part isEqualToString:@"/"]) continue;
        cur = [cur stringByAppendingPathComponent:part];
        if (wq_stat(cur, &st)) {
            if (!S_ISDIR(st.st_mode)) {
                if (errorText) *errorText = [NSString stringWithFormat:@"%@ is not a folder", part];
                return NO;
            }
            wq_grant(cur);
        } else {
            wq_grant(cur.stringByDeletingLastPathComponent);
            if (!wq_create_dir(cur, errorText)) return NO;
            wq_grant(cur);
        }
    }
    return YES;
}

static NSString *wq_pb_active_store_version(NSString *storePath)
{
    NSArray<NSString *> *entries = wq_list(storePath, nil) ?: @[];
    NSMutableArray<NSString *> *numericWithExt = [NSMutableArray new];
    NSMutableArray<NSString *> *numericAny = [NSMutableArray new];
    for (NSString *entry in entries) {
        if (!wq_pb_is_numeric_name(entry)) continue;
        NSString *dir = [storePath stringByAppendingPathComponent:entry];
        struct stat st;
        if (!wq_stat(dir, &st) || !S_ISDIR(st.st_mode)) continue;
        [numericAny addObject:entry];
        NSString *ext = [dir stringByAppendingPathComponent:@"Extensions"];
        if (wq_stat(ext, &st) && S_ISDIR(st.st_mode)) {
            [numericWithExt addObject:entry];
        }
    }
    NSArray<NSString *> *pool = numericWithExt.count ? numericWithExt : numericAny;
    NSArray<NSString *> *sorted = [pool sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger ia = a.integerValue;
        NSInteger ib = b.integerValue;
        return ib > ia ? NSOrderedDescending : (ib < ia ? NSOrderedAscending : NSOrderedSame);
    }];
    return sorted.firstObject ?: @"61";
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
        if ([bid isEqualToString:kPosterBoardBundleID]) {
            wq_pb_grant_ancestry(path);
            return path;
        }
    }

    // 2. Live LSApplicationProxy lookup.
    NSString *lsPath = wq_pb_ls_container();
    if (lsPath.length) {
        wq_pb_grant_ancestry(lsPath);
        return lsPath;
    }

    // 3. Worse-query enumeration of Data/Application fallback.
    NSArray<NSString *> *enumerated = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
    for (NSString *path in enumerated) {
        NSString *label = wq_container_label(path);
        if ([label isEqualToString:kPosterBoardBundleID]) {
            wq_pb_grant_ancestry(path);
            return path;
        }
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
    wq_grant(srcContainerDir);
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

static BOOL wq_pb_merge_local_dir(NSString *localDir, NSString *remoteDir, NSString *anchorDir,
                                  NSUInteger *copiedFiles, NSString **errorText)
{
    if (!wq_pb_ensure_dir(remoteDir, anchorDir, errorText)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listErr = nil;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:localDir error:&listErr];
    if (!items) {
        if (errorText) *errorText = listErr.localizedDescription ?: @"Unable to read extracted archive folder";
        return NO;
    }
    for (NSString *name in items) {
        if ([name isEqualToString:@".DS_Store"] || [name isEqualToString:@"__MACOSX"]) continue;
        NSString *localChild = [localDir stringByAppendingPathComponent:name];
        NSString *remoteChild = [remoteDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:localChild error:nil];
        NSString *ftype = attrs[NSFileType];
        if ([ftype isEqualToString:NSFileTypeSymbolicLink]) continue;
        if ([ftype isEqualToString:NSFileTypeDirectory]) {
            if (!wq_pb_merge_local_dir(localChild, remoteChild, anchorDir, copiedFiles, errorText)) return NO;
        } else if ([ftype isEqualToString:NSFileTypeRegular]) {
            struct stat st;
            wq_grant(remoteDir);
            BOOL ok = NO;
            if (wq_stat(remoteChild, &st)) {
                ok = S_ISREG(st.st_mode) ? wq_write_from_file(remoteChild, localChild, errorText) : NO;
                if (!ok && !S_ISREG(st.st_mode) && errorText && !*errorText) {
                    *errorText = [NSString stringWithFormat:@"%@ is not a regular file", name];
                }
            } else {
                ok = wq_create_file_from(remoteChild, localChild, errorText);
            }
            if (!ok) return NO;
            if (copiedFiles) (*copiedFiles)++;
        }
    }
    return YES;
}

// Finds a named subdirectory up to maxDepth levels below root (breadth-first), ignoring __MACOSX.
static NSString *_Nullable wq_pb_find_named_dir(NSString *root, NSString *targetName, NSUInteger maxDepth)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSArray *> *queue = [NSMutableArray arrayWithObject:@[root, @0]];
    while (queue.count) {
        NSArray *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *dir = node[0];
        NSUInteger depth = [node[1] unsignedIntegerValue];
        if ([dir.lastPathComponent isEqualToString:targetName]) return dir;
        if (depth >= maxDepth) continue;
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        for (NSString *name in children) {
            if ([name isEqualToString:@"__MACOSX"] || [name hasPrefix:@"."]) continue;
            NSString *child = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:child isDirectory:&isDir] && isDir) {
                [queue addObject:@[child, @(depth + 1)]];
            }
        }
    }
    return nil;
}

static BOOL wq_pb_is_descriptor_dir(NSString *dir)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    return [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"versions"] isDirectory:&isDir] && isDir;
}

// Applies any standard .tendies archive layout (full Container store, versioned Extensions,
// provider folders, descriptors/configurations buckets, or bare descriptor UUID folders)
// into the device's active PRBPosterExtensionDataStore version without wiping existing posters.
static BOOL wq_pb_apply_tendies_from_staging(NSString *staging, NSString *storePath,
                                             NSUInteger *appliedFiles, NSString **errorText)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *activeVer = wq_pb_active_store_version(storePath);
    NSString *activeVerDir = [storePath stringByAppendingPathComponent:activeVer];
    NSString *activeExtensionsDir = [activeVerDir stringByAppendingPathComponent:@"Extensions"];
    NSString *defaultDescriptorsDir = [[activeExtensionsDir stringByAppendingPathComponent:kDefaultCollectionsProvider]
                                       stringByAppendingPathComponent:@"descriptors"];

    if (!wq_pb_ensure_dir(activeExtensionsDir, storePath, errorText)) return NO;

    NSUInteger copied = 0;

    // 1. Container / PRBPosterExtensionDataStore store backup or export.
    NSString *foundStore = wq_pb_find_named_dir(staging, @"PRBPosterExtensionDataStore", 4);
    if (foundStore) {
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:foundStore error:nil] ?: @[];
        NSString *bestVerDir = nil;
        NSInteger bestVer = -1;
        for (NSString *c in children) {
            if (!wq_pb_is_numeric_name(c)) continue;
            NSString *cand = [foundStore stringByAppendingPathComponent:c];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"Extensions"] isDirectory:&isDir] && isDir &&
                c.integerValue > bestVer) {
                bestVer = c.integerValue;
                bestVerDir = cand;
            }
        }
        NSString *extSrc = bestVerDir
            ? [bestVerDir stringByAppendingPathComponent:@"Extensions"]
            : ([fm fileExistsAtPath:[foundStore stringByAppendingPathComponent:@"Extensions"] isDirectory:nil]
               ? [foundStore stringByAppendingPathComponent:@"Extensions"] : nil);
        if (extSrc) {
            if (!wq_pb_merge_local_dir(extSrc, activeExtensionsDir, storePath, &copied, errorText)) return NO;
            if (appliedFiles) *appliedFiles = copied;
            return copied > 0;
        }
    }

    // 2. Unwrap neutral single wrapper directory if present (e.g., MyTheme.tendies -> MyTheme/...).
    NSString *workRoot = staging;
    for (int unwrap = 0; unwrap < 3; unwrap++) {
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:workRoot error:nil] ?: @[];
        NSMutableArray<NSString *> *visible = [NSMutableArray new];
        for (NSString *e in entries) {
            if ([e hasPrefix:@"."] || [e isEqualToString:@"__MACOSX"]) continue;
            [visible addObject:e];
        }
        if (visible.count != 1) break;
        NSString *only = visible.firstObject;
        NSString *onlyPath = [workRoot stringByAppendingPathComponent:only];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:onlyPath isDirectory:&isDir] || !isDir) break;
        if ([only isEqualToString:@"Extensions"] || [only isEqualToString:@"descriptors"] ||
            [only isEqualToString:@"configurations"] || [only isEqualToString:@"versions"] ||
            wq_pb_is_descriptor_dir(onlyPath) || wq_pb_is_numeric_name(only)) {
            break;
        }
        workRoot = onlyPath;
    }

    // 3. Direct Extensions/ or <ver>/Extensions/ tree.
    NSString *extRoot = wq_pb_find_named_dir(workRoot, @"Extensions", 2);
    if (extRoot) {
        if (!wq_pb_merge_local_dir(extRoot, activeExtensionsDir, storePath, &copied, errorText)) return NO;
        if (appliedFiles) *appliedFiles = copied;
        if (copied == 0 && errorText && !*errorText) *errorText = @"Extensions folder in archive contained no files.";
        return copied > 0;
    }

    // 4. Direct descriptors/ or configurations/ buckets (standard Nugget / MisakaX .tendies layout).
    NSArray<NSString *> *topEntries = [fm contentsOfDirectoryAtPath:workRoot error:nil] ?: @[];
    BOOL handledBucket = NO;
    for (NSString *name in topEntries) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
        NSString *src = [workRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) continue;
        NSString *lower = name.lowercaseString;
        if ([lower isEqualToString:@"descriptors"] || [lower isEqualToString:@"configurations"]) {
            NSString *dst = [[activeExtensionsDir stringByAppendingPathComponent:kDefaultCollectionsProvider]
                             stringByAppendingPathComponent:lower];
            if (!wq_pb_merge_local_dir(src, dst, storePath, &copied, errorText)) return NO;
            handledBucket = YES;
        } else if ([name containsString:@"."]) {
            // Provider bundle ID directory containing descriptors/configurations
            BOOL hasSubBucket = NO;
            for (NSString *sub in ([fm contentsOfDirectoryAtPath:src error:nil] ?: @[])) {
                if ([sub isEqualToString:@"descriptors"] || [sub isEqualToString:@"configurations"]) {
                    hasSubBucket = YES;
                    break;
                }
            }
            if (hasSubBucket) {
                NSString *dst = [activeExtensionsDir stringByAppendingPathComponent:name];
                if (!wq_pb_merge_local_dir(src, dst, storePath, &copied, errorText)) return NO;
                handledBucket = YES;
            }
        }
    }
    if (handledBucket) {
        if (appliedFiles) *appliedFiles = copied;
        if (copied == 0 && errorText && !*errorText) *errorText = @"Descriptor folders in archive contained no files.";
        return copied > 0;
    }

    // 5. Bare descriptor folder(s): either <UUID>/versions/... or versions/ at top level.
    if (wq_pb_is_descriptor_dir(workRoot)) {
        NSString *uuidName = wq_pb_looks_like_uuid(workRoot.lastPathComponent)
            ? workRoot.lastPathComponent.uppercaseString
            : NSUUID.UUID.UUIDString;
        NSString *dst = [defaultDescriptorsDir stringByAppendingPathComponent:uuidName];
        if (!wq_pb_merge_local_dir(workRoot, dst, storePath, &copied, errorText)) return NO;
        if (appliedFiles) *appliedFiles = copied;
        return copied > 0;
    }

    BOOL mergedDescriptor = NO;
    for (NSString *name in topEntries) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
        NSString *src = [workRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) continue;
        if (wq_pb_is_descriptor_dir(src)) {
            NSString *uuidName = wq_pb_looks_like_uuid(name) ? name.uppercaseString : NSUUID.UUID.UUIDString;
            NSString *dst = [defaultDescriptorsDir stringByAppendingPathComponent:uuidName];
            if (!wq_pb_merge_local_dir(src, dst, storePath, &copied, errorText)) return NO;
            mergedDescriptor = YES;
        }
    }
    if (mergedDescriptor) {
        if (appliedFiles) *appliedFiles = copied;
        return copied > 0;
    }

    if (errorText && !*errorText) {
        *errorText = @"Unrecognized .tendies layout: expected descriptors/, Extensions/, PRBPosterExtensionDataStore, or a UUID/versions bundle.";
    }
    return NO;
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

static NSData *_Nullable wq_pb_encode_heic(UIImage *image)
{
    if (!image.CGImage) return nil;
    NSMutableData *out = [NSMutableData new];
    CFStringRef typeID = (__bridge CFStringRef)(UTTypeHEIC.identifier ?: @"public.heic");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, typeID, 1, NULL);
    if (!dest) return nil;
    NSDictionary *props = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(0.92) };
    CGImageDestinationAddImage(dest, image.CGImage, (__bridge CFDictionaryRef)props);
    BOOL finalized = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return finalized && out.length > 0 ? out : nil;
}

static void wq_pb_collect_images_in_dir(NSString *dir, NSUInteger depth, NSMutableArray<NSString *> *outPaths)
{
    if (depth > 5) return;
    wq_grant(dir);
    NSArray<NSString *> *entries = wq_list(dir, nil);
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        NSString *child = [dir stringByAppendingPathComponent:name];
        struct stat st;
        if (!wq_stat(child, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            wq_pb_collect_images_in_dir(child, depth + 1, outPaths);
        } else if (S_ISREG(st.st_mode)) {
            NSString *lower = name.lowercaseString;
            if ([lower hasSuffix:@".jpg"] || [lower hasSuffix:@".jpeg"] ||
                [lower hasSuffix:@".heic"] || [lower hasSuffix:@".png"]) {
                [outPaths addObject:child];
            }
        }
    }
}

// Finds candidate wallpaper / asset folders inside PRBPosterExtensionDataStore where a custom photo
// wallpaper can be installed without breaking store structure.
static NSArray<NSString *> *wq_pb_find_wallpaper_targets(NSString *storePath)
{
    NSMutableArray<NSString *> *primaryTargets = [NSMutableArray new];
    NSMutableArray<NSString *> *fallbackTargets = [NSMutableArray new];
    wq_grant(storePath);
    NSArray<NSString *> *top = wq_list(storePath, nil) ?: @[];
    for (NSString *entry in top) {
        NSString *versionDir = [storePath stringByAppendingPathComponent:entry];
        struct stat st;
        if (!wq_stat(versionDir, &st) || !S_ISDIR(st.st_mode)) continue;
        wq_grant(versionDir);
        NSString *extensionsDir = [versionDir stringByAppendingPathComponent:@"Extensions"];
        NSArray<NSString *> *exts = wq_list(extensionsDir, nil) ?: @[];
        for (NSString *ext in exts) {
            NSString *extPath = [extensionsDir stringByAppendingPathComponent:ext];
            BOOL preferred = [ext containsString:@"PhotosPosterProvider"] ||
                             [ext containsString:@"CollectionsPoster"] ||
                             [ext containsString:@"Wallpaper"];
            BOOL posterLike = preferred || [ext containsString:@"Poster"];
            if (!posterLike) continue;
            NSArray<NSString *> *sub = wq_list(extPath, nil) ?: @[];
            for (NSString *item in sub) {
                if ([item isEqualToString:@"configurations"] || [item isEqualToString:@"descriptors"]) {
                    NSString *target = [extPath stringByAppendingPathComponent:item];
                    [preferred ? primaryTargets : fallbackTargets addObject:target];
                }
            }
        }
    }
    return primaryTargets.count ? primaryTargets : fallbackTargets;
}

static NSUInteger wq_pb_inject_image_into_descriptor_dirs(NSString *parentDir, NSData *jpegData, NSData *pngData, NSData *_Nullable heicData, NSString **errorText)
{
    NSUInteger injected = 0;
    wq_grant(parentDir);
    NSArray<NSString *> *uuids = wq_list(parentDir, nil) ?: @[];
    for (NSString *uuid in uuids) {
        NSString *descDir = [parentDir stringByAppendingPathComponent:uuid];
        wq_grant(descDir);
        NSString *versionsDir = [descDir stringByAppendingPathComponent:@"versions"];
        NSArray<NSString *> *versions = wq_list(versionsDir, nil) ?: @[];
        for (NSString *ver in versions) {
            NSString *verPath = [versionsDir stringByAppendingPathComponent:ver];
            wq_grant(verPath);
            NSString *contentsDir = [verPath stringByAppendingPathComponent:@"contents"];
            NSMutableArray<NSString *> *imageFiles = [NSMutableArray new];
            wq_pb_collect_images_in_dir(contentsDir, 0, imageFiles);
            for (NSString *dest in imageFiles) {
                NSString *lower = dest.lowercaseString;
                NSData *payload = nil;
                if ([lower hasSuffix:@".png"]) payload = pngData;
                else if ([lower hasSuffix:@".heic"]) payload = heicData ?: jpegData;
                else payload = jpegData;
                if (!payload.length) continue;
                NSString *err = nil;
                if (wq_write(dest, payload, &err)) injected++;
                else if (errorText && !*errorText) *errorText = err;
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
    UIStackView *_quickRow;
    UILabel *_containerBadgeLabel;
    UILabel *_storeStatusLabel;
    UILabel *_backupStatusLabel;
    UIImageView *_previewImageView;
    UILabel *_previewCaptionLabel;
    UILabel *_activityLabel;

    UIButton *_importTendiesButton;
    UIButton *_photoWallpaperButton;
    UIButton *_applyWallpaperButton;
    UIButton *_restoreBackupButton;
    UIButton *_browseStoreButton;
    UIButton *_openPosterBoardButton;
    UIButton *_respringButton;

    UIImage *_Nullable _selectedWallpaperImage;
    NSString *_Nullable _selectedWallpaperLabel;
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

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (_quickRow) {
        BOOL narrow = self.view.bounds.size.width < 480.0;
        _quickRow.axis = narrow ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    }
}

- (void)buildInterface
{
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = YES;
    wq_theme_apply_scroll_insets(_scroll, 28.0);
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
    heroTitle.numberOfLines = 0;
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
        [_importTendiesButton.heightAnchor constraintGreaterThanOrEqualToConstant:48],
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
    wallTitle.numberOfLines = 0;
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
        [_photoWallpaperButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];

    _applyWallpaperButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _applyWallpaperButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_primary_button(_applyWallpaperButton, @"Apply Wallpaper", @"checkmark.circle.fill");
    [_applyWallpaperButton addTarget:self action:@selector(applySelectedWallpaper) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_applyWallpaperButton.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    [wallStack addArrangedSubview:wallTitle];
    [wallStack addArrangedSubview:wallSub];
    [wallStack addArrangedSubview:_previewImageView];
    [wallStack addArrangedSubview:_previewCaptionLabel];
    [wallStack addArrangedSubview:_photoWallpaperButton];
    [wallStack addArrangedSubview:_applyWallpaperButton];
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
    actionsTitle.numberOfLines = 0;
    actionsTitle.text = @"System Actions";

    _quickRow = [UIStackView new];
    _quickRow.axis = UILayoutConstraintAxisHorizontal;
    _quickRow.distribution = UIStackViewDistributionFillEqually;
    _quickRow.spacing = 10;

    _openPosterBoardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _openPosterBoardButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_openPosterBoardButton, @"Open PosterBoard", @"arrow.up.forward.app.fill");
    [_openPosterBoardButton addTarget:self action:@selector(openPosterBoardApp) forControlEvents:UIControlEventTouchUpInside];

    _respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _respringButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_respringButton, @"Respring", @"arrow.trianglehead.2.clockwise.rotate.90");
    UIButtonConfiguration *respringCfg = [_respringButton.configuration copy];
    if (respringCfg) {
        respringCfg.baseBackgroundColor = wq_theme_active_pill();
        respringCfg.background.strokeColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.85 alpha:0.55];
        respringCfg.background.strokeWidth = 1.0;
        _respringButton.configuration = respringCfg;
    }
    [_respringButton addTarget:self action:@selector(confirmRespring) forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [_openPosterBoardButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [_respringButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [_quickRow addArrangedSubview:_openPosterBoardButton];
    [_quickRow addArrangedSubview:_respringButton];

    _browseStoreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _browseStoreButton.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_browseStoreButton, @"Browse PRBPosterExtensionDataStore", @"folder.fill");
    [_browseStoreButton addTarget:self action:@selector(browseStore) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [_browseStoreButton.heightAnchor constraintGreaterThanOrEqualToConstant:42],
    ]];

    [actionsStack addArrangedSubview:actionsTitle];
    [actionsStack addArrangedSubview:_quickRow];
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
    backupTitle.numberOfLines = 0;
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
        [_restoreBackupButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
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
    _applyWallpaperButton.enabled = ready && _selectedWallpaperImage != nil;
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
        NSString *activeVersion = nil;
        if (container.length) {
            wq_pb_grant_ancestry(container);
            NSString *candidate = [container stringByAppendingPathComponent:kPosterStoreRelPath];
            struct stat st;
            if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) {
                store = candidate;
                wq_grant(store);
                versions = wq_list(store, nil) ?: @[];
                activeVersion = wq_pb_active_store_version(store);
            }
        }
        NSArray<NSString *> *backups = wq_pb_list_backups();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_containerPath = container;
            self->_storePath = store;
            self->_storeVersions = versions;
            self->_backups = backups;

            if (store.length) {
                self->_containerBadgeLabel.text = [NSString stringWithFormat:@"%@ · store v%@ · %lu folder(s)",
                    kPosterBoardBundleID, activeVersion ?: @"?", (unsigned long)versions.count];
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
    UTType *tendiesType = [UTType typeWithFilenameExtension:@"tendies"];
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (tendiesType) [types addObject:tendiesType];
    [types addObjectsFromArray:@[UTTypeZIP, UTTypeArchive, UTTypeData]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)applyTendiesAtLocalURL:(NSURL *)url
{
    NSString *containerPath = _containerPath;
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
        NSUInteger appliedFiles = 0;
        if (ok) {
            NSUInteger stagedFiles = wq_pb_count_regular_files_local(staging);
            if (stagedFiles == 0) {
                ok = NO;
                err = @"Archive contained no importable files.";
            } else {
                wq_pb_grant_ancestry(containerPath);
                wq_pb_grant_tree(storePath, 0);
                NSString *backupDir = wq_pb_create_backup(storePath, &backedFiles, &err);
                if (!backupDir) {
                    ok = NO;
                } else {
                    backupName = backupDir.lastPathComponent;
                    ok = wq_pb_apply_tendies_from_staging(staging, storePath, &appliedFiles, &err);
                }
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        if (ok) {
            typedef uint32_t (*wq_notify_post_fn)(const char *);
            wq_notify_post_fn notifyPost = (wq_notify_post_fn)dlsym(RTLD_DEFAULT, "notify_post");
            if (notifyPost) notifyPost("com.apple.PosterBoard.reload");
        }
        NSArray<NSString *> *backups = wq_pb_list_backups();

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            self->_backups = backups;
            [self updateControls];
            if (ok) {
                self->_activityLabel.text = [NSString stringWithFormat:@"Applied %lu file(s) · Backup %@",
                    (unsigned long)appliedFiles, backupName ?: @"-"];
                wq_alert(self, WQVerbatim(@"PosterBoard Updated"),
                         WQVerbatim([NSString stringWithFormat:@"Imported %lu file(s) into PRBPosterExtensionDataStore (active store v%@).\n\nSafety backup saved: %@ (%lu files).\n\nTap Open PosterBoard or Respring to see the changes.",
                                     (unsigned long)appliedFiles, wq_pb_active_store_version(storePath),
                                     backupName ?: @"-", (unsigned long)backedFiles]));
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

- (void)stageWallpaperImage:(UIImage *)image label:(NSString *)label
{
    if (!image) return;
    _selectedWallpaperImage = image;
    _selectedWallpaperLabel = [label copy];
    _previewImageView.image = image;
    _previewImageView.hidden = NO;
    _previewCaptionLabel.text = [NSString stringWithFormat:@"Selected: %@ (%.0f × %.0f px) — tap Apply Wallpaper below.",
        label ?: @"Wallpaper", image.size.width * image.scale, image.size.height * image.scale];
    _previewCaptionLabel.hidden = NO;
    _activityLabel.text = _storePath.length
        ? @"Wallpaper preview ready — tap Apply Wallpaper"
        : @"Wallpaper staged — waiting for PosterBoard store";
    [self updateControls];
}

- (void)applySelectedWallpaper
{
    if (_busy || !_storePath.length) return;
    if (!_selectedWallpaperImage) {
        [self choosePhotoWallpaper];
        return;
    }
    [self applyWallpaperImage:_selectedWallpaperImage label:_selectedWallpaperLabel];
}

- (void)applyWallpaperImage:(UIImage *)image label:(NSString *)label
{
    if (!image || !_storePath.length) return;
    _selectedWallpaperImage = image;
    _selectedWallpaperLabel = [label copy];
    _previewImageView.image = image;
    _previewImageView.hidden = NO;
    _previewCaptionLabel.text = [NSString stringWithFormat:@"Applying: %@ (%.0f × %.0f px)",
        label ?: @"Wallpaper", image.size.width * image.scale, image.size.height * image.scale];
    _previewCaptionLabel.hidden = NO;

    NSString *containerPath = _containerPath;
    NSString *storePath = _storePath;
    _busy = YES;
    _activityLabel.text = @"Backing up PosterBoard and preparing wallpaper…";
    [self updateControls];

    dispatch_async(wq_io(), ^{
        NSData *jpegData = UIImageJPEGRepresentation(image, 0.94);
        NSData *pngData = UIImagePNGRepresentation(image);
        NSData *heicData = wq_pb_encode_heic(image);
        if (!jpegData || !pngData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_busy = NO;
                [self updateControls];
                self->_activityLabel.text = @"Unable to encode selected image";
                wq_alert(self, WQVerbatim(@"Wallpaper Error"), WQVerbatim(@"Unable to encode the selected image."));
            });
            return;
        }

        NSString *err = nil;
        NSUInteger backedFiles = 0;
        wq_pb_grant_ancestry(containerPath);
        wq_pb_grant_tree(storePath, 0);
        NSString *backupDir = wq_pb_create_backup(storePath, &backedFiles, &err);
        NSUInteger updatedSlots = 0;
        if (backupDir) {
            NSArray<NSString *> *targets = wq_pb_find_wallpaper_targets(storePath);
            for (NSString *targetDir in targets) {
                updatedSlots += wq_pb_inject_image_into_descriptor_dirs(targetDir, jpegData, pngData, heicData, &err);
            }
            // Also save a clean copy in Documents/PosterBoardBackups/Wallpapers for easy manual inspection/reuse.
            NSString *wallDir = [wq_pb_docs_backup_root() stringByAppendingPathComponent:@"Wallpapers"];
            [NSFileManager.defaultManager createDirectoryAtPath:wallDir withIntermediateDirectories:YES attributes:nil error:nil];
            [jpegData writeToFile:[wallDir stringByAppendingPathComponent:@"CustomWallpaper.jpg"] atomically:YES];
            if (updatedSlots > 0) {
                typedef uint32_t (*wq_notify_post_fn)(const char *);
                wq_notify_post_fn notifyPost = (wq_notify_post_fn)dlsym(RTLD_DEFAULT, "notify_post");
                if (notifyPost) notifyPost("com.apple.PosterBoard.reload");
            }
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
    NSString *containerPath = _containerPath;
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
            wq_pb_grant_ancestry(containerPath);
            wq_pb_grant_tree(storePath, 0);
            ok = wq_copy_contents(backupDir, storePath, &err);
            if (!ok) {
                err = nil;
                NSUInteger restored = 0;
                ok = wq_pb_merge_local_dir(backupDir, storePath, storePath, &restored, &err);
            }
            if (ok) {
                typedef uint32_t (*wq_notify_post_fn)(const char *);
                wq_notify_post_fn notifyPost = (wq_notify_post_fn)dlsym(RTLD_DEFAULT, "notify_post");
                if (notifyPost) notifyPost("com.apple.PosterBoard.reload");
            }
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

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    WQPosterPickerMode mode = _pickerMode;
    _pickerMode = 0;
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (mode == WQPosterPickerTendies) {
        [self applyTendiesAtLocalURL:url];
    } else if (mode == WQPosterPickerPhotoFile) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        UIImage *image = data ? [UIImage imageWithData:data] : [UIImage imageWithContentsOfFile:url.path];
        NSString *name = url.lastPathComponent;
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        if (image) {
            [self stageWallpaperImage:image label:name];
        } else {
            wq_alert(self, WQVerbatim(@"Invalid Image"), WQVerbatim(@"The selected file could not be opened as an image."));
        }
    } else {
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *__unused)controller
{
    _pickerMode = 0;
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info
{
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (image) {
            [self stageWallpaperImage:image label:@"Photo Library Wallpaper"];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end
