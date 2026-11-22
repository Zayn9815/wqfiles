//
//  WQWorkflows.m
//  WQ Glass One-Tap Dry-Run Folder Automation Workflows
//  GPL-3.0-or-later.
//

#import "WQWorkflows.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

static NSString *wq_workflows_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"Workflows"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_bucket_for_ext(NSString *ext)
{
    NSString *e = ext.lowercaseString;
    if (!e.length) return nil;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary new];
        for (NSString *x in @[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"webp", @"tiff", @"svg", @"bmp"]) m[x] = @"Images";
        for (NSString *x in @[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"txt", @"md", @"rtf", @"csv", @"pages"]) m[x] = @"Documents";
        for (NSString *x in @[@"mp4", @"mov", @"m4v", @"mkv", @"avi", @"webm"]) m[x] = @"Videos";
        for (NSString *x in @[@"mp3", @"m4a", @"wav", @"aac", @"flac", @"ogg", @"caf"]) m[x] = @"Audio";
        for (NSString *x in @[@"zip", @"ipa", @"tar", @"gz", @"7z", @"rar", @"wqenc"]) m[x] = @"Archives";
        for (NSString *x in @[@"json", @"plist", @"xml", @"js", @"ts", @"py", @"swift", @"m", @"h", @"c", @"cpp", @"html", @"css", @"sh", @"sql", @"yaml", @"yml"]) m[x] = @"Code";
        map = m;
    });
    return map[e];
}

static NSString *wq_quick_sha256_path(NSString *path)
{
    NSData *d = wq_read(path, 16 * 1024 * 1024, NULL);
    if (!d) return @"-";
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

@implementation WQWorkflowsViewController {
    NSString *_rootPath;
    NSString *_rootTitle;
    BOOL _busy;
    NSString *_status;
}

- (instancetype)initWithRootPath:(NSString *)rootPath title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _rootPath = [rootPath copy];
        _rootTitle = title.length ? [title copy] : (rootPath.lastPathComponent.length ? rootPath.lastPathComponent : @"/");
        self.title = WQLocalized(@"Folder Workflows");
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
}

#pragma mark - 1. Auto-Organize by File Type (Dry-Run Preview)

- (void)runAutoOrganizePreview
{
    if (_busy) return;
    if (wq_safe_read_only_enabled()) {
        wq_alert(self, WQLocalized(@"Safe Read-Only Mode Active"),
                 WQLocalized(@"Turn off Safe Mode on the Home screen before organizing files."));
        return;
    }
    _busy = YES;
    _status = WQLocalized(@"Scanning folder for Auto-Organize dry-run…");
    [self.tableView reloadData];
    NSString *root = _rootPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        wq_grant(root);
        NSArray<NSString *> *names = wq_list(root, NULL) ?: @[];
        NSMutableArray<NSArray<NSString *> *> *moves = [NSMutableArray new]; // @[srcPath, bucketName, fileName]
        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary new];
        for (NSString *n in names) {
            if ([n hasPrefix:@"."]) continue;
            NSString *p = [root stringByAppendingPathComponent:n];
            struct stat st;
            if (!wq_stat(p, &st) || !S_ISREG(st.st_mode)) continue;
            NSString *bucket = wq_bucket_for_ext(n.pathExtension);
            if (!bucket) continue;
            [moves addObject:@[p, bucket, n]];
            counts[bucket] = @([counts[bucket] unsignedIntegerValue] + 1);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkflowsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (!moves.count) {
                wq_alert(me, WQLocalized(@"Already Organized"), WQLocalized(@"No loose categorizable files were found in this folder."));
                return;
            }
            NSMutableArray<NSString *> *summary = [NSMutableArray new];
            for (NSString *b in [counts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                [summary addObject:[NSString stringWithFormat:@"• %@/ ← %lu files", b, (unsigned long)[counts[b] unsignedIntegerValue]]];
            }
            wq_present_glass_confirm(me,
                                     WQLocalizedFormat(@"Auto-Organize %lu Files?", (unsigned long)moves.count),
                                     [summary componentsJoinedByString:@"\n"],
                                     WQLocalized(@"Organize Now"),
                                     NO,
                                     ^{
                [me executeAutoOrganizeMoves:moves];
            });
        });
    });
}

- (void)executeAutoOrganizeMoves:(NSArray<NSArray<NSString *> *> *)moves
{
    _busy = YES;
    _status = WQLocalized(@"Moving files into category folders…");
    [self.tableView reloadData];
    NSString *root = _rootPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSUInteger moved = 0;
        for (NSArray<NSString *> *m in moves) {
            NSString *src = m[0];
            NSString *bucket = m[1];
            NSString *name = m[2];
            NSString *dir = [root stringByAppendingPathComponent:bucket];
            struct stat dst;
            if (!wq_stat(dir, &dst)) wq_create_dir(dir, NULL);
            NSString *dest = [dir stringByAppendingPathComponent:name];
            if (wq_stat(dest, &dst)) continue; // never clobber existing file
            if (wq_move(src, dir, NULL)) moved++;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkflowsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(me, WQLocalized(@"Folder Organized"), WQLocalizedFormat(@"Moved %lu of %lu files cleanly.", (unsigned long)moved, (unsigned long)moves.count));
        });
    });
}

#pragma mark - 2. Clean Empty Folders & Zero-Byte Junk (Dry-Run Preview)

- (void)runCleanJunkPreview
{
    if (_busy) return;
    if (wq_refuse_if_deleting_off(self)) return;
    _busy = YES;
    _status = WQLocalized(@"Scanning for empty folders & zero-byte junk…");
    [self.tableView reloadData];
    NSString *root = _rootPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        wq_grant(root);
        NSMutableArray<NSString *> *junk = [NSMutableArray new];
        NSArray<NSString *> *names = wq_list(root, NULL) ?: @[];
        for (NSString *n in names) {
            NSString *p = [root stringByAppendingPathComponent:n];
            struct stat st;
            if (!wq_stat(p, &st)) continue;
            if (S_ISREG(st.st_mode)) {
                if (st.st_size == 0 || [n isEqualToString:@".DS_Store"] || [n isEqualToString:@"Thumbs.db"]) {
                    [junk addObject:p];
                }
            } else if (S_ISDIR(st.st_mode)) {
                NSArray<NSString *> *children = wq_list(p, NULL);
                if (children && children.count == 0) [junk addObject:p];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkflowsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (!junk.count) {
                wq_alert(me, WQLocalized(@"Folder Is Clean"), WQLocalized(@"No empty subfolders, .DS_Store, or 0-byte files were found."));
                return;
            }
            NSMutableArray<NSString *> *preview = [NSMutableArray new];
            for (NSUInteger i = 0; i < MIN(junk.count, (NSUInteger)6); i++) {
                [preview addObject:[NSString stringWithFormat:@"• %@", junk[i].lastPathComponent]];
            }
            if (junk.count > 6) [preview addObject:[NSString stringWithFormat:@"… +%lu more", (unsigned long)(junk.count - 6)]];
            wq_present_glass_confirm(me,
                                     WQLocalizedFormat(@"Clean %lu Junk / Empty Items?", (unsigned long)junk.count),
                                     [preview componentsJoinedByString:@"\n"],
                                     WQLocalized(@"Clean Now"),
                                     YES,
                                     ^{
                dispatch_async(wq_io(), ^{
                    NSUInteger removed = 0;
                    for (NSString *p in junk) {
                        if (wq_delete(p, NULL)) removed++;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                        wq_alert(me, WQLocalized(@"Cleaned"), WQLocalizedFormat(@"Removed %lu items safely.", (unsigned long)removed));
                    });
                });
            });
        });
    });
}

#pragma mark - 3. Photo Contact Sheet PDF (3x4 Proof Grid)

- (void)runPhotoContactSheet
{
    if (_busy) return;
    _busy = YES;
    _status = WQLocalized(@"Rendering 3×4 Photo Contact Sheet PDF…");
    [self.tableView reloadData];
    NSString *root = _rootPath;
    NSString *title = _rootTitle;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        wq_grant(root);
        NSSet *imgExts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"webp"]];
        NSArray<NSString *> *names = [[wq_list(root, NULL) ?: @[] sortedArrayUsingSelector:@selector(localizedStandardCompare:)] copy];
        NSMutableArray<NSString *> *imgs = [NSMutableArray new];
        for (NSString *n in names) {
            if ([imgExts containsObject:n.pathExtension.lowercaseString]) {
                [imgs addObject:[root stringByAppendingPathComponent:n]];
            }
        }
        NSString *outPath = nil;
        BOOL ok = NO;
        if (imgs.count > 0) {
            CGRect pageRect = CGRectMake(0, 0, 612, 792); // US Letter
            UIGraphicsPDFRenderer *renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:pageRect];
            NSData *pdf = [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *ctx) {
                const NSUInteger cols = 3, rows = 4, perPage = cols * rows;
                CGFloat margin = 32.0, gap = 14.0, headerH = 34.0;
                CGFloat cellW = (pageRect.size.width - margin * 2.0 - gap * (cols - 1)) / (CGFloat)cols;
                CGFloat cellH = (pageRect.size.height - margin * 2.0 - headerH - gap * (rows - 1)) / (CGFloat)rows;
                for (NSUInteger idx = 0; idx < imgs.count; idx++) {
                    @autoreleasepool {
                        if (idx % perPage == 0) {
                            [ctx beginPage];
                            NSString *hdr = [NSString stringWithFormat:@"%@ — Contact Sheet (Page %lu)", title, (unsigned long)(idx / perPage + 1)];
                            [hdr drawAtPoint:CGPointMake(margin, margin) withAttributes:@{
                                NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightBold],
                                NSForegroundColorAttributeName: UIColor.darkGrayColor,
                            }];
                        }
                        NSUInteger slot = idx % perPage;
                        NSUInteger c = slot % cols;
                        NSUInteger r = slot / cols;
                        CGFloat x = margin + (CGFloat)c * (cellW + gap);
                        CGFloat y = margin + headerH + (CGFloat)r * (cellH + gap);
                        CGRect imgRect = CGRectMake(x, y, cellW, cellH - 18.0);
                        NSData *raw = wq_read(imgs[idx], 32 * 1024 * 1024, NULL) ?: [NSData dataWithContentsOfFile:imgs[idx]];
                        UIImage *img = raw.length ? [UIImage imageWithData:raw] : nil;
                        if (img && img.size.width > 0 && img.size.height > 0) {
                            CGFloat scale = MIN(imgRect.size.width / img.size.width, imgRect.size.height / img.size.height);
                            CGSize drawSz = CGSizeMake(img.size.width * scale, img.size.height * scale);
                            CGRect fit = CGRectMake(CGRectGetMidX(imgRect) - drawSz.width * 0.5,
                                                    CGRectGetMidY(imgRect) - drawSz.height * 0.5,
                                                    drawSz.width, drawSz.height);
                            [img drawInRect:fit];
                        }
                        NSString *cap = imgs[idx].lastPathComponent;
                        [cap drawInRect:CGRectMake(x, CGRectGetMaxY(imgRect) + 3, cellW, 14) withAttributes:@{
                            NSFontAttributeName: [UIFont systemFontOfSize:8.5 weight:UIFontWeightMedium],
                            NSForegroundColorAttributeName: UIColor.grayColor,
                        }];
                    }
                }
            }];
            NSString *fname = [NSString stringWithFormat:@"%@_ContactSheet.pdf", title];
            outPath = [wq_workflows_output_dir() stringByAppendingPathComponent:fname];
            ok = pdf.length > 0 && [pdf writeToFile:outPath atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkflowsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (!imgs.count) {
                wq_alert(me, WQLocalized(@"No Images Found"), WQLocalized(@"This folder has no JPEG, PNG, or HEIC images."));
            } else if (ok && outPath) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                share.popoverPresentationController.sourceView = me.view;
                [me presentViewController:share animated:YES completion:nil];
            } else {
                wq_alert(me, WQLocalized(@"Export Failed"), WQLocalized(@"Could not create contact sheet PDF."));
            }
        });
    });
}

#pragma mark - 4. Folder Audit Manifest Generator (CSV / Markdown + SHA-256)

- (void)runAuditManifestWithHashes:(BOOL)includeHashes asCSV:(BOOL)asCSV
{
    if (_busy) return;
    _busy = YES;
    _status = WQLocalized(@"Generating Folder Audit Manifest…");
    [self.tableView reloadData];
    NSString *root = _rootPath;
    NSString *title = _rootTitle;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        wq_grant(root);
        NSMutableArray<NSString *> *rows = [NSMutableArray new];
        if (asCSV) {
            [rows addObject:includeHashes ? @"Path,Bytes,Modified,SHA256" : @"Path,Bytes,Modified"];
        } else {
            [rows addObject:[NSString stringWithFormat:@"# Folder Audit Manifest: %@", title]];
            [rows addObject:[NSString stringWithFormat:@"Root: `%@`\n", root]];
            [rows addObject:includeHashes ? @"| File | Size | Modified | SHA-256 |" : @"| File | Size | Modified |"];
            [rows addObject:includeHashes ? @"|---|---:|---|---|" : @"|---|---:|---|"];
        }
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:root];
        NSUInteger count = 0;
        while (stack.count && count < 2000) {
            @autoreleasepool {
                NSString *dir = stack.lastObject;
                [stack removeLastObject];
                NSArray<NSString *> *names = [[wq_list(dir, NULL) ?: @[] sortedArrayUsingSelector:@selector(compare:)] copy];
                for (NSString *n in names) {
                    if (count >= 2000) break;
                    NSString *p = [dir stringByAppendingPathComponent:n];
                    struct stat st;
                    if (!wq_stat(p, &st)) continue;
                    if (S_ISDIR(st.st_mode)) {
                        [stack addObject:p];
                    } else if (S_ISREG(st.st_mode)) {
                        count++;
                        NSString *rel = [p hasPrefix:root] ? [p substringFromIndex:root.length] : p;
                        if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
                        NSString *mod = [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)st.st_mtime]] ?: @"";
                        NSString *hash = includeHashes ? wq_quick_sha256_path(p) : nil;
                        if (asCSV) {
                            NSString *safeRel = [rel stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
                            if (includeHashes) [rows addObject:[NSString stringWithFormat:@"\"%@\",%lld,%@,%@", safeRel, st.st_size, mod, hash]];
                            else [rows addObject:[NSString stringWithFormat:@"\"%@\",%lld,%@", safeRel, st.st_size, mod]];
                        } else {
                            if (includeHashes) [rows addObject:[NSString stringWithFormat:@"| `%@` | %@ | %@ | `%@` |", rel, wq_size_text((unsigned long long)MAX(0LL, st.st_size)), mod, hash]];
                            else [rows addObject:[NSString stringWithFormat:@"| `%@` | %@ | %@ |", rel, wq_size_text((unsigned long long)MAX(0LL, st.st_size)), mod]];
                        }
                    }
                }
            }
        }
        NSString *ext = asCSV ? @"csv" : @"md";
        NSString *outPath = [wq_workflows_output_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_Manifest.%@", title, ext]];
        BOOL ok = [[rows componentsJoinedByString:@"\n"] writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkflowsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                share.popoverPresentationController.sourceView = me.view;
                [me presentViewController:share animated:YES completion:nil];
            } else {
                wq_alert(me, WQLocalized(@"Manifest Failed"), WQLocalized(@"Could not write audit manifest file."));
            }
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 2 : 3;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return _status ?: WQLocalizedFormat(@"Folder Cleanup & Sorting (%@)", _rootTitle);
    return WQLocalized(@"Export & Proofing Workflows");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"wf-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wf-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.imageProperties.tintColor = wq_theme_accent();

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Auto-Organize by File Type");
            c.secondaryText = WQLocalized(@"Dry-run preview → sorts into Images/, Documents/, Videos/, Audio/, Archives/, Code/");
            c.image = [UIImage systemImageNamed:@"folder.badge.gearshape"];
        } else {
            c.text = WQLocalized(@"Clean Empty Folders & Zero-Byte Junk");
            c.secondaryText = WQLocalized(@"Finds empty subfolders, .DS_Store & 0-byte files with preview");
            c.image = [UIImage systemImageNamed:@"sparkles"];
        }
    } else {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Photo Contact Sheet PDF (3×4 Grid)");
            c.secondaryText = WQLocalized(@"Creates a printable proof sheet PDF of all images in this folder");
            c.image = [UIImage systemImageNamed:@"square.grid.3x3.fill"];
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Export Audit Manifest (CSV + SHA-256)");
            c.secondaryText = WQLocalized(@"Spreadsheet report of files, sizes, dates & SHA-256 checksums");
            c.image = [UIImage systemImageNamed:@"tablecells.fill"];
        } else {
            c.text = WQLocalized(@"Export Tree Report (Markdown)");
            c.secondaryText = WQLocalized(@"Clean Markdown inventory table ready to share or archive");
            c.image = [UIImage systemImageNamed:@"doc.richtext.fill"];
        }
    }
    c.secondaryTextProperties.numberOfLines = 2;
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self runAutoOrganizePreview];
        else [self runCleanJunkPreview];
    } else {
        if (indexPath.row == 0) [self runPhotoContactSheet];
        else if (indexPath.row == 1) [self runAuditManifestWithHashes:YES asCSV:YES];
        else [self runAuditManifestWithHashes:NO asCSV:NO];
    }
}

@end
