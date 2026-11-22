//
//  WQOCRStudio.m
//  WQ Glass Offline Apple Vision OCR & PDF Watermark Studio
//  GPL-3.0-or-later.
//

#import "WQOCRStudio.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CoreGraphics/CoreGraphics.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Vision/Vision.h>

typedef NS_ENUM(NSInteger, WQOCRPickMode) {
    WQOCRPickNone = 0,
    WQOCRPickForOCR,
    WQOCRPickForWatermark,
};

static NSString *wq_ocr_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"OCR & PDF Studio"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_run_vision_ocr_on_cgimage(CGImageRef cgImg, NSError **outError)
{
    if (!cgImg) return nil;
    __block NSMutableArray<NSString *> *lines = [NSMutableArray new];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *__unused err) {
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [obs topCandidates:1].firstObject;
            if (top.string.length) [lines addObject:top.string];
        }
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
    NSError *err = nil;
    if (![handler performRequests:@[req] error:&err]) {
        if (outError) *outError = err;
        return nil;
    }
    return [lines componentsJoinedByString:@"\n"];
}

@interface WQOCRStudioViewController () <UIDocumentPickerDelegate>
@end

@implementation WQOCRStudioViewController {
    NSString *_initialPath;
    WQOCRPickMode _pickMode;
    BOOL _busy;
    NSString *_status;
    NSString *_extractedText;
    NSString *_sourceName;
    NSString *_watermarkText;
    CGFloat _watermarkAlpha;
}

- (instancetype)initWithInitialPath:(NSString *)filePath
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _initialPath = [filePath copy];
        _watermarkText = @"CONFIDENTIAL";
        _watermarkAlpha = 0.22;
        self.title = WQLocalized(@"OCR & PDF Watermark");
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
    if (_initialPath.length) {
        [self runOCROnFilePath:_initialPath];
    }
}

- (void)pickForMode:(WQOCRPickMode)mode
{
    if (_busy) return;
    _pickMode = mode;
    NSArray<UTType *> *types = (mode == WQOCRPickForWatermark) ? @[UTTypePDF] : @[UTTypeImage, UTTypePDF];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *u = urls.firstObject;
    WQOCRPickMode mode = _pickMode;
    _pickMode = WQOCRPickNone;
    if (!u) return;
    if (mode == WQOCRPickForOCR) {
        [self runOCROnFilePath:u.path];
    } else if (mode == WQOCRPickForWatermark) {
        [self watermarkPDFAtPath:u.path];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *__unused)controller
{
    _pickMode = WQOCRPickNone;
}

- (void)runOCROnFilePath:(NSString *)path
{
    if (!path.length || _busy) return;
    _busy = YES;
    _sourceName = path.lastPathComponent;
    _status = WQLocalizedFormat(@"Running offline Vision OCR on %@…", _sourceName);
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *raw = wq_read(path, 64 * 1024 * 1024, NULL) ?: [NSData dataWithContentsOfFile:path];
        NSString *ext = path.pathExtension.lowercaseString;
        NSMutableArray<NSString *> *pageTexts = [NSMutableArray new];
        NSError *ocrErr = nil;

        if ([ext isEqualToString:@"pdf"]) {
            PDFDocument *doc = raw.length ? [[PDFDocument alloc] initWithData:raw] : [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
            NSUInteger pages = MIN(doc.pageCount, (NSUInteger)25);
            for (NSUInteger i = 0; i < pages; i++) {
                @autoreleasepool {
                    PDFPage *pg = [doc pageAtIndex:i];
                    CGRect bounds = [pg boundsForBox:kPDFDisplayBoxMediaBox];
                    CGFloat scale = 2.0;
                    CGSize pxSize = CGSizeMake(MAX(100, bounds.size.width * scale), MAX(100, bounds.size.height * scale));
                    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pxSize];
                    UIImage *rendered = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                        [UIColor.whiteColor setFill];
                        CGContextFillRect(ctx.CGContext, CGRectMake(0, 0, pxSize.width, pxSize.height));
                        CGContextTranslateCTM(ctx.CGContext, 0, pxSize.height);
                        CGContextScaleCTM(ctx.CGContext, scale, -scale);
                        [pg drawWithBox:kPDFDisplayBoxMediaBox toContext:ctx.CGContext];
                    }];
                    NSString *t = wq_run_vision_ocr_on_cgimage(rendered.CGImage, &ocrErr);
                    if (t.length) {
                        if (pages > 1) [pageTexts addObject:[NSString stringWithFormat:@"--- Page %lu ---\n%@", (unsigned long)(i + 1), t]];
                        else [pageTexts addObject:t];
                    }
                }
            }
        } else {
            UIImage *img = raw.length ? [UIImage imageWithData:raw] : [UIImage imageWithContentsOfFile:path];
            NSString *t = wq_run_vision_ocr_on_cgimage(img.CGImage, &ocrErr);
            if (t.length) [pageTexts addObject:t];
        }

        NSString *combined = [pageTexts componentsJoinedByString:@"\n\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQOCRStudioViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            me->_extractedText = combined.length ? combined : nil;
            [me.tableView reloadData];
            if (combined.length) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                [me presentExtractedTextModal];
            } else {
                wq_alert(me, WQLocalized(@"No Text Found"), ocrErr.localizedDescription ?: WQLocalized(@"No readable text was detected in this file."));
            }
        });
    });
}

- (void)presentExtractedTextModal
{
    if (!_extractedText.length) return;
    UIViewController *vc = [UIViewController new];
    vc.title = _sourceName ?: WQLocalized(@"Extracted Text");
    vc.view.backgroundColor = wq_theme_canvas_top();

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.font = [UIFont systemFontOfSize:14.5];
    tv.textColor = wq_theme_primary_text();
    tv.backgroundColor = UIColor.clearColor;
    tv.textContainerInset = UIEdgeInsetsMake(16, 16, 20, 16);
    tv.text = _extractedText;
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];

    NSString *textCopy = [_extractedText copy];
    NSString *srcName = [_sourceName copy] ?: @"ocr";
    __weak UIViewController *weakVC = vc;
    vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                         primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakVC dismissViewControllerAnimated:YES completion:nil];
    }]];
    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Copy") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
        UIPasteboard.generalPasteboard.string = textCopy;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        wq_alert(weakVC, WQLocalized(@"Copied"), WQLocalized(@"Extracted OCR text copied to clipboard."));
    }]];
    UIBarButtonItem *saveBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Save .txt") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *__unused a) {
        NSString *base = srcName.stringByDeletingPathExtension ?: @"ocr";
        NSString *outPath = [wq_ocr_output_dir() stringByAppendingPathComponent:[base stringByAppendingString:@"_OCR.txt"]];
        BOOL ok = [textCopy writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        wq_haptic_notify(ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError);
        if (ok) {
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
            share.popoverPresentationController.sourceView = weakVC.view;
            [weakVC presentViewController:share animated:YES completion:nil];
        }
    }]];
    vc.navigationItem.rightBarButtonItems = @[copyBtn, saveBtn];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)watermarkPDFAtPath:(NSString *)path
{
    if (!path.length || _busy) return;
    _busy = YES;
    _status = WQLocalized(@"Stamping diagonal watermark onto PDF…");
    [self.tableView reloadData];

    NSString *stamp = _watermarkText.length ? _watermarkText : @"CONFIDENTIAL";
    CGFloat alpha = _watermarkAlpha;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *raw = wq_read(path, 128 * 1024 * 1024, NULL) ?: [NSData dataWithContentsOfFile:path];
        PDFDocument *doc = raw.length ? [[PDFDocument alloc] initWithData:raw] : [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
        NSString *base = path.lastPathComponent.stringByDeletingPathExtension ?: @"document";
        NSString *outPath = [wq_ocr_output_dir() stringByAppendingPathComponent:[base stringByAppendingString:@"_Watermarked.pdf"]];
        BOOL ok = NO;
        if (doc && doc.pageCount > 0) {
            CGRect firstBox = [[doc pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
            UIGraphicsPDFRenderer *renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:firstBox];
            NSData *pdfData = [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *ctx) {
                for (NSUInteger i = 0; i < doc.pageCount; i++) {
                    @autoreleasepool {
                        PDFPage *pg = [doc pageAtIndex:i];
                        CGRect box = [pg boundsForBox:kPDFDisplayBoxMediaBox];
                        [ctx beginPageWithBounds:box pageInfo:@{}];
                        CGContextRef cg = ctx.CGContext;
                        CGContextSaveGState(cg);
                        CGContextTranslateCTM(cg, 0, box.size.height);
                        CGContextScaleCTM(cg, 1.0, -1.0);
                        [pg drawWithBox:kPDFDisplayBoxMediaBox toContext:cg];
                        CGContextRestoreGState(cg);

                        // Diagonal watermark text
                        CGContextSaveGState(cg);
                        CGContextTranslateCTM(cg, box.size.width * 0.5, box.size.height * 0.5);
                        CGContextRotateCTM(cg, (CGFloat)(-M_PI / 5.0));
                        CGFloat fontSize = MAX(28.0, MIN(72.0, box.size.width * 0.09));
                        NSDictionary *attrs = @{
                            NSFontAttributeName: [UIFont systemFontOfSize:fontSize weight:UIFontWeightBlack],
                            NSForegroundColorAttributeName: [UIColor.systemRedColor colorWithAlphaComponent:alpha],
                        };
                        CGSize textSize = [stamp sizeWithAttributes:attrs];
                        [stamp drawAtPoint:CGPointMake(-textSize.width * 0.5, -textSize.height * 0.5) withAttributes:attrs];
                        CGContextRestoreGState(cg);
                    }
                }
            }];
            ok = pdfData.length > 0 && [pdfData writeToFile:outPath atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQOCRStudioViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                UIAlertController *done = wq_alert_controller(WQLocalized(@"Watermarked PDF Saved"),
                                                              WQLocalizedFormat(@"Saved to Documents/OCR & PDF Studio/%@", outPath.lastPathComponent),
                                                              UIAlertControllerStyleAlert);
                [done addAction:wq_alert_action(WQLocalized(@"Share PDF"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                    share.popoverPresentationController.sourceView = me.view;
                    [me presentViewController:share animated:YES completion:nil];
                })];
                [done addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
                [me presentViewController:done animated:YES completion:nil];
            } else {
                wq_alert(me, WQLocalized(@"Watermark Failed"), WQLocalized(@"Could not render the selected PDF."));
            }
        });
    });
}

- (void)promptWatermarkText
{
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Watermark Text"), WQLocalized(@"Stamped diagonally across every PDF page."), UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = self->_watermarkText;
        f.placeholder = @"CONFIDENTIAL";
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Save", UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) self->_watermarkText = t;
        [self.tableView reloadData];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return _extractedText.length ? 2 : 1;
    return 3;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return _status ?: WQLocalized(@"Offline On-Device OCR (Apple Vision)");
    return WQLocalized(@"PDF Watermark Studio");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ocr-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ocr-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.imageProperties.tintColor = wq_theme_accent();

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Extract Text from Image or PDF…");
            c.secondaryText = WQLocalized(@"100% offline accurate Apple Vision text recognition");
            c.image = [UIImage systemImageNamed:@"text.viewfinder"];
        } else {
            c.text = WQLocalizedFormat(@"View Last OCR Result (%@)", _sourceName ?: @"Text");
            c.secondaryText = WQLocalizedFormat(@"%lu characters extracted · Tap to view, copy or save", (unsigned long)_extractedText.length);
            c.image = [UIImage systemImageNamed:@"doc.plaintext.fill"];
        }
    } else {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Watermark Text");
            c.secondaryText = _watermarkText;
            c.image = [UIImage systemImageNamed:@"pencil.line"];
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Watermark Opacity");
            c.secondaryText = [NSString stringWithFormat:@"%.0f%% (Tap to cycle 15%% / 22%% / 38%%)", _watermarkAlpha * 100.0];
            c.image = [UIImage systemImageNamed:@"circle.lefthalf.filled"];
        } else {
            c.text = WQLocalized(@"Pick PDF & Apply Watermark…");
            c.secondaryText = WQLocalized(@"Saves a clean watermarked copy in Documents/OCR & PDF Studio");
            c.image = [UIImage systemImageNamed:@"doc.badge.gearshape.fill"];
        }
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self pickForMode:WQOCRPickForOCR];
        else [self presentExtractedTextModal];
    } else {
        if (indexPath.row == 0) [self promptWatermarkText];
        else if (indexPath.row == 1) {
            if (_watermarkAlpha < 0.20) _watermarkAlpha = 0.22;
            else if (_watermarkAlpha < 0.30) _watermarkAlpha = 0.38;
            else _watermarkAlpha = 0.15;
            [tableView reloadData];
        } else {
            if (_initialPath.length && [_initialPath.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
                [self watermarkPDFAtPath:_initialPath];
            } else {
                [self pickForMode:WQOCRPickForWatermark];
            }
        }
    }
}

@end

void wq_present_ocr_studio(UIViewController *host, NSString *filePath)
{
    WQOCRStudioViewController *vc = [[WQOCRStudioViewController alloc] initWithInitialPath:filePath];
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }
}
