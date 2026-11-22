//
//  WQMediaTools.m
//  WQ Glass Privacy Photo EXIF Scrubber, Image Converter & Video-to-Audio Studio
//  GPL-3.0-or-later.
//

#import "WQMediaTools.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *wq_media_studio_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"Media Studio"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL wq_is_image_ext(NSString *ext)
{
    NSString *e = ext.lowercaseString;
    return [@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"webp", @"gif", @"tiff", @"bmp"] containsObject:e];
}

static UIImage *_Nullable wq_resize_image_if_needed(UIImage *img, CGFloat maxWidth)
{
    if (!img || maxWidth <= 0 || img.size.width <= maxWidth) return img;
    CGFloat scale = maxWidth / img.size.width;
    CGSize target = CGSizeMake(floor(img.size.width * scale), floor(img.size.height * scale));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

static NSData *_Nullable wq_encode_clean_image(UIImage *img, NSString *formatExt, CGFloat quality)
{
    if (!img || !img.CGImage) return nil;
    NSString *utid = [formatExt isEqualToString:@"png"] ? UTTypePNG.identifier
                   : [formatExt isEqualToString:@"heic"] ? UTTypeHEIC.identifier
                   : UTTypeJPEG.identifier;
    NSMutableData *out = [NSMutableData new];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)utid, 1, NULL);
    if (!dest) return nil;
    // Empty metadata dictionary strips all EXIF, GPS, TIFF, and camera model tags!
    NSDictionary *props = @{
        (id)kCGImageDestinationLossyCompressionQuality: @(quality),
        (id)kCGImagePropertyExifDictionary: (id)kCFNull,
        (id)kCGImagePropertyGPSDictionary: (id)kCFNull,
        (id)kCGImagePropertyTIFFDictionary: (id)kCFNull,
    };
    CGImageDestinationAddImage(dest, img.CGImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? out : nil;
}

@interface WQMediaToolsViewController () <UIDocumentPickerDelegate>
@end

@implementation WQMediaToolsViewController {
    NSString *_selectedPath;
    BOOL _isImage;
    BOOL _busy;
    NSString *_statusText;
    NSArray<NSArray<NSString *> *> *_infoRows;
}

- (instancetype)initWithInitialPath:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _selectedPath = [path copy];
        self.title = WQLocalized(@"Photo & Media Studio");
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
    if (_selectedPath.length) {
        [self inspectSelectedFile];
    }
}

- (void)pickFileForImages:(BOOL)imagesOnly
{
    NSArray<UTType *> *types = imagesOnly ? @[UTTypeImage] : @[UTTypeMovie, UTTypeVideo, UTTypeAudio];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *u = urls.firstObject;
    if (!u) return;
    _selectedPath = u.path;
    [self inspectSelectedFile];
}

- (void)inspectSelectedFile
{
    NSString *path = _selectedPath;
    if (!path.length) return;
    _isImage = wq_is_image_ext(path.pathExtension);
    _statusText = WQLocalized(@"Inspecting metadata…");
    _infoRows = @[];
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray new];
        [rows addObject:@[WQLocalized(@"File"), path.lastPathComponent]];
        struct stat st;
        if (wq_stat(path, &st)) {
            [rows addObject:@[WQLocalized(@"Size"), wq_size_text((unsigned long long)st.st_size)]];
        }
        if (wq_is_image_ext(path.pathExtension)) {
            NSData *data = wq_read(path, 64 * 1024 * 1024, NULL) ?: [NSData dataWithContentsOfFile:path];
            if (data.length) {
                CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                if (src) {
                    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
                    NSNumber *pw = props[(id)kCGImagePropertyPixelWidth];
                    NSNumber *ph = props[(id)kCGImagePropertyPixelHeight];
                    if (pw && ph) [rows addObject:@[WQLocalized(@"Dimensions"), [NSString stringWithFormat:@"%@ × %@ px", pw, ph]]];
                    NSString *colorModel = props[(id)kCGImagePropertyColorModel];
                    if (colorModel.length) [rows addObject:@[WQLocalized(@"Color Model"), colorModel]];
                    NSDictionary *gps = props[(id)kCGImagePropertyGPSDictionary];
                    [rows addObject:@[WQLocalized(@"GPS Location"), gps.count ? WQLocalized(@"Present (Scrub Recommended)") : WQLocalized(@"None")]];
                    NSDictionary *tiff = props[(id)kCGImagePropertyTIFFDictionary];
                    NSString *cam = tiff[(id)kCGImagePropertyTIFFModel];
                    [rows addObject:@[WQLocalized(@"Camera EXIF"), cam.length ? cam : WQLocalized(@"None")]];
                    CFRelease(src);
                }
            }
        } else {
            NSURL *fileURL = [NSURL fileURLWithPath:path];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            AVURLAsset *asset = [AVURLAsset assetWithURL:fileURL];
            double secs = CMTimeGetSeconds(asset.duration);
            if (isfinite(secs) && secs > 0) {
                long total = (long)llround(secs);
                [rows addObject:@[WQLocalized(@"Duration"), [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60]]];
            }
            NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if (vTracks.count) {
                AVAssetTrack *vt = vTracks.firstObject;
                CGSize sz = CGSizeApplyAffineTransform(vt.naturalSize, vt.preferredTransform);
                [rows addObject:@[WQLocalized(@"Video Resolution"), [NSString stringWithFormat:@"%.0f × %.0f", fabs(sz.width), fabs(sz.height)]]];
                if (vt.nominalFrameRate > 0) [rows addObject:@[WQLocalized(@"Frame Rate"), [NSString stringWithFormat:@"%.1f fps", vt.nominalFrameRate]]];
                if (vt.estimatedDataRate > 0) [rows addObject:@[WQLocalized(@"Video Bitrate"), [NSString stringWithFormat:@"%.1f Mbps", vt.estimatedDataRate / 1e6]]];
            }
            NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            [rows addObject:@[WQLocalized(@"Audio Tracks"), [NSString stringWithFormat:@"%lu", (unsigned long)aTracks.count]]];
#pragma clang diagnostic pop
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQMediaToolsViewController *me = weakSelf;
            if (!me) return;
            me->_statusText = nil;
            me->_infoRows = rows;
            [me.tableView reloadData];
        });
    });
}

- (void)processImageWithFormat:(NSString *)ext quality:(CGFloat)quality maxWidth:(CGFloat)maxWidth label:(NSString *)label
{
    if (!_selectedPath.length || _busy) return;
    _busy = YES;
    _statusText = WQLocalized(@"Processing image…");
    [self.tableView reloadData];
    NSString *srcPath = _selectedPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *raw = wq_read(srcPath, 64 * 1024 * 1024, NULL) ?: [NSData dataWithContentsOfFile:srcPath];
        UIImage *img = raw.length ? [UIImage imageWithData:raw] : nil;
        UIImage *resized = wq_resize_image_if_needed(img, maxWidth);
        NSData *encoded = wq_encode_clean_image(resized, ext, quality);
        NSString *base = srcPath.lastPathComponent.stringByDeletingPathExtension ?: @"image";
        NSString *outPath = [wq_media_studio_dir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_%@.%@", base, label, ext]];
        BOOL ok = encoded.length > 0 && [encoded writeToFile:outPath atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQMediaToolsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_statusText = nil;
            [me.tableView reloadData];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                NSString *msg = WQLocalizedFormat(@"Saved %@ (%@ → %@) with all EXIF/GPS metadata stripped.",
                    outPath.lastPathComponent, wq_size_text(raw.length), wq_size_text(encoded.length));
                UIAlertController *alert = wq_alert_controller(WQLocalized(@"Done"), msg, UIAlertControllerStyleAlert);
                [alert addAction:wq_alert_action(WQLocalized(@"Share"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                    av.popoverPresentationController.sourceView = me.view;
                    av.popoverPresentationController.sourceRect = me.view.bounds;
                    [me presentViewController:av animated:YES completion:nil];
                })];
                [alert addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
                [me presentViewController:alert animated:YES completion:nil];
            } else {
                wq_alert(me, WQLocalized(@"Failed"), WQLocalized(@"Could not process or save the image."));
            }
        });
    });
}

- (void)extractAudioM4A
{
    if (!_selectedPath.length || _busy) return;
    _busy = YES;
    _statusText = WQLocalized(@"Extracting M4A audio…");
    [self.tableView reloadData];
    NSString *srcPath = _selectedPath;
    NSString *base = srcPath.lastPathComponent.stringByDeletingPathExtension ?: @"audio";
    NSString *outPath = [wq_media_studio_dir() stringByAppendingPathComponent:[base stringByAppendingString:@"_audio.m4a"]];
    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];

    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:srcPath]];
    AVAssetExportSession *exporter = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    if (!exporter) {
        _busy = NO;
        _statusText = nil;
        [self.tableView reloadData];
        wq_alert(self, WQLocalized(@"Unavailable"), WQLocalized(@"This media file cannot be exported to M4A audio."));
        return;
    }
    exporter.outputURL = [NSURL fileURLWithPath:outPath];
    exporter.outputFileType = AVFileTypeAppleM4A;
    __weak typeof(self) weakSelf = self;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        BOOL ok = exporter.status == AVAssetExportSessionStatusCompleted;
        NSString *errText = exporter.error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            WQMediaToolsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_statusText = nil;
            [me.tableView reloadData];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                UIAlertController *alert = wq_alert_controller(WQLocalized(@"Audio Extracted"),
                    WQLocalizedFormat(@"Saved %@ in Documents/Media Studio.", outPath.lastPathComponent),
                    UIAlertControllerStyleAlert);
                [alert addAction:wq_alert_action(WQLocalized(@"Share"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                    av.popoverPresentationController.sourceView = me.view;
                    av.popoverPresentationController.sourceRect = me.view.bounds;
                    [me presentViewController:av animated:YES completion:nil];
                })];
                [alert addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
                [me presentViewController:alert animated:YES completion:nil];
            } else {
                wq_alert(me, WQLocalized(@"Export Failed"), errText ?: WQLocalized(@"Could not extract audio track."));
            }
        });
    }];
#pragma clang diagnostic pop
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView
{
    return _selectedPath.length ? 3 : 1;
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return (NSInteger)_infoRows.count;
    return _isImage ? 4 : 1;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Choose Media File");
    if (section == 1) return WQLocalized(@"Inspector & Privacy Metadata");
    return _isImage ? WQLocalized(@"Privacy Scrub & Convert") : WQLocalized(@"Audio / Video Tools");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && _statusText.length) return _statusText;
    if (section == 2) return WQLocalized(@"Originals are never modified; clean outputs save to Documents/Media Studio.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media-tool"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"media-tool"];
    UIListContentConfiguration *c = indexPath.section == 1
        ? [UIListContentConfiguration valueCellConfiguration]
        : [UIListContentConfiguration subtitleCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Pick Photo (EXIF Scrub / Convert)");
            c.secondaryText = WQLocalized(@"JPEG, PNG, HEIC — strip GPS & resize offline");
            c.image = [UIImage systemImageNamed:@"photo.badge.checkmark"];
        } else {
            c.text = WQLocalized(@"Pick Video / Audio (Inspect / Extract M4A)");
            c.secondaryText = WQLocalized(@"Read codec/FPS/bitrate or extract audio track");
            c.image = [UIImage systemImageNamed:@"film.stack"];
        }
        c.imageProperties.tintColor = wq_theme_accent();
    } else if (indexPath.section == 1) {
        c.text = _infoRows[(NSUInteger)indexPath.row][0];
        c.secondaryText = _infoRows[(NSUInteger)indexPath.row][1];
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (_isImage) {
        NSArray<NSArray<NSString *> *> *ops = @[
            @[WQLocalized(@"Scrub EXIF / GPS (85% Balanced JPEG)"), WQLocalized(@"Removes GPS & camera info, keeps original size"), @"hand.raised.fill"],
            @[WQLocalized(@"Compact Share (65% JPEG · Max 1920px)"), WQLocalized(@"Great for fast uploads & saving storage"), @"arrow.down.right.and.arrow.up.left"],
            @[WQLocalized(@"Clean PNG Copy (Lossless, No EXIF)"), WQLocalized(@"Saves a clean lossless PNG copy"), @"photo.fill"],
            @[WQLocalized(@"Clean HEIC Copy (85% HEIC, No EXIF)"), WQLocalized(@"High-efficiency Apple format with metadata stripped"), @"sparkles"],
        ];
        NSArray<NSString *> *op = ops[(NSUInteger)indexPath.row];
        c.text = op[0];
        c.secondaryText = op[1];
        c.image = [UIImage systemImageNamed:op[2]];
        c.imageProperties.tintColor = wq_theme_aurora_teal();
    } else {
        c.text = WQLocalized(@"Extract Audio Track (.m4a)");
        c.secondaryText = WQLocalized(@"Exports AAC audio offline to Documents/Media Studio");
        c.image = [UIImage systemImageNamed:@"waveform"];
        c.imageProperties.tintColor = wq_theme_aurora_teal();
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        [self pickFileForImages:indexPath.row == 0];
        return;
    }
    if (indexPath.section == 2) {
        if (_isImage) {
            if (indexPath.row == 0) [self processImageWithFormat:@"jpg" quality:0.85 maxWidth:0 label:@"clean"];
            else if (indexPath.row == 1) [self processImageWithFormat:@"jpg" quality:0.65 maxWidth:1920 label:@"compact"];
            else if (indexPath.row == 2) [self processImageWithFormat:@"png" quality:1.0 maxWidth:0 label:@"clean"];
            else [self processImageWithFormat:@"heic" quality:0.85 maxWidth:0 label:@"clean"];
        } else {
            [self extractAudioM4A];
        }
    }
}

@end

void wq_present_media_tools(UIViewController *host, NSString *filePath)
{
    WQMediaToolsViewController *vc = [[WQMediaToolsViewController alloc] initWithInitialPath:filePath];
    if (host.navigationController) [host.navigationController pushViewController:vc animated:YES];
    else [host presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
}
