//
//  WQDocStudio.m
//  WQ Glass Offline PDF & Document Studio (PDFKit)
//  GPL-3.0-or-later.
//

#import "WQDocStudio.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, WQDocStudioMode) {
    WQDocStudioModeNone = 0,
    WQDocStudioModeImagesToPDF,
    WQDocStudioModeMergePDFs,
    WQDocStudioModeSplitPDF,
};

static NSString *wq_pdf_studio_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"PDF Studio"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_pdf_output_path(NSString *prefix)
{
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *name = [NSString stringWithFormat:@"%@_%@.pdf", prefix, [df stringFromDate:NSDate.date]];
    return [wq_pdf_studio_dir() stringByAppendingPathComponent:name];
}

// Parses ranges like "1-5" or "1, 3, 5-7" into 0-based page indices bounded by pageCount.
static NSArray<NSNumber *> *wq_parse_page_ranges(NSString *spec, NSUInteger pageCount)
{
    NSMutableOrderedSet<NSNumber *> *indices = [NSMutableOrderedSet new];
    for (NSString *rawPart in [spec componentsSeparatedByString:@","]) {
        NSString *part = [rawPart stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!part.length) continue;
        NSArray<NSString *> *bounds = [part componentsSeparatedByString:@"-"];
        if (bounds.count == 1) {
            NSInteger p = bounds[0].integerValue;
            if (p >= 1 && (NSUInteger)p <= pageCount) [indices addObject:@((NSUInteger)(p - 1))];
        } else if (bounds.count == 2) {
            NSInteger a = bounds[0].integerValue;
            NSInteger b = bounds[1].integerValue;
            if (a > b) { NSInteger t = a; a = b; b = t; }
            for (NSInteger p = MAX(1, a); p <= MIN((NSInteger)pageCount, b); p++) {
                [indices addObject:@((NSUInteger)(p - 1))];
            }
        }
    }
    return indices.array;
}

@interface WQDocStudioViewController () <UIDocumentPickerDelegate>
@end

@implementation WQDocStudioViewController {
    WQDocStudioMode _mode;
    BOOL _busy;
    NSString *_statusText;
    NSArray<NSString *> *_savedPDFs;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"PDF Studio");
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
    [self reloadSavedPDFs];
}

- (void)reloadSavedPDFs
{
    NSString *dir = wq_pdf_studio_dir();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSString *> *pdfs = [NSMutableArray new];
    for (NSString *n in names) {
        if ([n.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
            [pdfs addObject:[dir stringByAppendingPathComponent:n]];
        }
    }
    [pdfs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b.lastPathComponent localizedStandardCompare:a.lastPathComponent];
    }];
    _savedPDFs = pdfs;
    [self.tableView reloadData];
}

- (void)startPickerForMode:(WQDocStudioMode)mode
{
    if (_busy) return;
    _mode = mode;
    NSArray<UTType *> *types = (mode == WQDocStudioModeImagesToPDF) ? @[UTTypeImage] : @[UTTypePDF];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = (mode != WQDocStudioModeSplitPDF);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *__unused)controller
{
    _mode = WQDocStudioModeNone;
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    WQDocStudioMode mode = _mode;
    _mode = WQDocStudioModeNone;
    if (!urls.count) return;
    if (mode == WQDocStudioModeImagesToPDF) {
        [self buildPDFFromImageURLs:urls];
    } else if (mode == WQDocStudioModeMergePDFs) {
        if (urls.count < 2) {
            wq_alert(self, WQLocalized(@"Select 2+ PDFs"), WQLocalized(@"Choose at least two PDF files to merge."));
            return;
        }
        [self mergePDFURLs:urls];
    } else if (mode == WQDocStudioModeSplitPDF) {
        [self promptSplitForPDFURL:urls.firstObject];
    }
}

- (void)buildPDFFromImageURLs:(NSArray<NSURL *> *)urls
{
    _busy = YES;
    _statusText = WQLocalized(@"Creating PDF…");
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PDFDocument *doc = [PDFDocument new];
        NSUInteger added = 0;
        for (NSURL *u in urls) {
            @autoreleasepool {
                UIImage *img = [UIImage imageWithContentsOfFile:u.path];
                if (!img) continue;
                PDFPage *page = [[PDFPage alloc] initWithImage:img];
                if (page) {
                    [doc insertPage:page atIndex:doc.pageCount];
                    added++;
                }
            }
        }
        NSString *outPath = wq_pdf_output_path(@"Images");
        BOOL ok = added > 0 && [doc writeToFile:outPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDocStudioViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_statusText = nil;
            [me reloadSavedPDFs];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(me, WQLocalized(@"PDF Created"), WQLocalizedFormat(@"Saved %@ (%lu pages) in Documents/PDF Studio.", outPath.lastPathComponent, (unsigned long)added));
            } else {
                wq_alert(me, WQLocalized(@"Failed"), WQLocalized(@"Could not create PDF from the selected images."));
            }
        });
    });
}

- (void)mergePDFURLs:(NSArray<NSURL *> *)urls
{
    _busy = YES;
    _statusText = WQLocalized(@"Merging PDFs…");
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PDFDocument *merged = [PDFDocument new];
        NSUInteger totalPages = 0;
        for (NSURL *u in urls) {
            @autoreleasepool {
                PDFDocument *src = [[PDFDocument alloc] initWithURL:u];
                if (!src) continue;
                for (NSUInteger i = 0; i < src.pageCount; i++) {
                    PDFPage *p = [src pageAtIndex:i];
                    if (p) {
                        [merged insertPage:p atIndex:merged.pageCount];
                        totalPages++;
                    }
                }
            }
        }
        NSString *outPath = wq_pdf_output_path(@"Merged");
        BOOL ok = totalPages > 0 && [merged writeToFile:outPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDocStudioViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_statusText = nil;
            [me reloadSavedPDFs];
            if (ok) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(me, WQLocalized(@"PDFs Merged"), WQLocalizedFormat(@"Saved %@ (%lu total pages).", outPath.lastPathComponent, (unsigned long)totalPages));
            } else {
                wq_alert(me, WQLocalized(@"Merge Failed"), WQLocalized(@"Could not merge the selected PDF files."));
            }
        });
    });
}

- (void)promptSplitForPDFURL:(NSURL *)url
{
    PDFDocument *probe = [[PDFDocument alloc] initWithURL:url];
    NSUInteger count = probe.pageCount;
    if (!probe || count == 0) {
        wq_alert(self, WQLocalized(@"Unreadable PDF"), WQLocalized(@"The selected PDF has no readable pages."));
        return;
    }
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"Extract PDF Pages"),
        WQLocalizedFormat(@"%@ has %lu pages. Enter pages or ranges to extract (e.g. 1-3 or 1,4,6-8).", url.lastPathComponent, (unsigned long)count),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"1-3";
        tf.text = count >= 2 ? [NSString stringWithFormat:@"1-%lu", (unsigned long)MIN((NSUInteger)5, count)] : @"1";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Extract"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *spec = alert.textFields.firstObject.text ?: @"";
        NSArray<NSNumber *> *indices = wq_parse_page_ranges(spec, count);
        if (!indices.count) {
            wq_alert(self, WQLocalized(@"Invalid Range"), WQLocalized(@"No valid page numbers found in that range."));
            return;
        }
        self->_busy = YES;
        self->_statusText = WQLocalized(@"Extracting pages…");
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            PDFDocument *src = [[PDFDocument alloc] initWithURL:url];
            PDFDocument *outDoc = [PDFDocument new];
            for (NSNumber *idx in indices) {
                PDFPage *p = [src pageAtIndex:idx.unsignedIntegerValue];
                if (p) [outDoc insertPage:p atIndex:outDoc.pageCount];
            }
            NSString *outPath = wq_pdf_output_path(@"Extract");
            BOOL ok = outDoc.pageCount > 0 && [outDoc writeToFile:outPath];
            dispatch_async(dispatch_get_main_queue(), ^{
                WQDocStudioViewController *me = weakSelf;
                if (!me) return;
                me->_busy = NO;
                me->_statusText = nil;
                [me reloadSavedPDFs];
                if (ok) {
                    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                    wq_alert(me, WQLocalized(@"Pages Extracted"), WQLocalizedFormat(@"Saved %@ (%lu pages).", outPath.lastPathComponent, (unsigned long)outDoc.pageCount));
                } else {
                    wq_alert(me, WQLocalized(@"Extract Failed"), WQLocalized(@"Could not write extracted PDF."));
                }
            });
        });
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    return MAX(1, (NSInteger)_savedPDFs.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? WQLocalized(@"PDF Tools (100% Offline)") : WQLocalized(@"Created in Documents/PDF Studio");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && _statusText.length) return _statusText;
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pdf-studio"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pdf-studio"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.section == 0) {
        NSArray<NSArray<NSString *> *> *tools = @[
            @[WQLocalized(@"Images → PDF"), WQLocalized(@"Combine multiple images into a single PDF"), @"photo.on.rectangle.angled"],
            @[WQLocalized(@"Merge PDFs"), WQLocalized(@"Join two or more PDFs into one document"), @"doc.on.doc.fill"],
            @[WQLocalized(@"Split / Extract Pages"), WQLocalized(@"Extract a page range (e.g. 1-5) into a new PDF"), @"scissors"],
        ];
        NSArray<NSString *> *t = tools[(NSUInteger)indexPath.row];
        c.text = t[0];
        c.secondaryText = t[1];
        c.image = [UIImage systemImageNamed:t[2]];
        c.imageProperties.tintColor = wq_theme_accent();
    } else if (!_savedPDFs.count) {
        c.text = WQLocalized(@"No created PDFs yet");
        c.secondaryText = WQLocalized(@"Generated PDFs are saved in Documents/PDF Studio.");
        c.textProperties.color = wq_theme_secondary_text();
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        NSString *p = _savedPDFs[(NSUInteger)indexPath.row];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        c.text = p.lastPathComponent;
        c.secondaryText = wq_size_text(sz);
        c.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        c.image = [UIImage systemImageNamed:@"doc.richtext.fill"];
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
        if (indexPath.row == 0) [self startPickerForMode:WQDocStudioModeImagesToPDF];
        else if (indexPath.row == 1) [self startPickerForMode:WQDocStudioModeMergePDFs];
        else [self startPickerForMode:WQDocStudioModeSplitPDF];
        return;
    }
    if (!_savedPDFs.count) return;
    NSString *path = _savedPDFs[(NSUInteger)indexPath.row];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    av.popoverPresentationController.sourceView = cell ?: self.view;
    av.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:av animated:YES completion:nil];
}

@end
