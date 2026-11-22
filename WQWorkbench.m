//
//  WQWorkbench.m
//  WQ Glass Everyday Utility Workbench (QR Studio, Password/UUID, Scratchpad, Dev Converters)
//  GPL-3.0-or-later.
//

#import "WQWorkbench.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

static NSString *const kWQScratchpadPref = @"WQWorkbenchScratchpad";

static UIImage *_Nullable wq_render_qr_image(NSString *payload, CGFloat size)
{
    if (!payload.length) return nil;
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = filter.outputImage;
    if (!ci) return nil;
    CGFloat scale = size / MAX(1.0, ci.extent.size.width);
    CIImage *scaled = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

static NSString *wq_generate_password(NSUInteger length, BOOL upper, BOOL lower, BOOL digits, BOOL symbols, double *entropyOut)
{
    NSMutableString *pool = [NSMutableString new];
    if (lower) [pool appendString:@"abcdefghijklmnopqrstuvwxyz"];
    if (upper) [pool appendString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    if (digits) [pool appendString:@"0123456789"];
    if (symbols) [pool appendString:@"!@#$%^&*()-_=+[]{}?"];
    if (!pool.length) [pool appendString:@"abcdefghijklmnopqrstuvwxyz0123456789"];

    NSUInteger len = MAX((NSUInteger)8, MIN((NSUInteger)64, length));
    if (entropyOut) *entropyOut = (double)len * log2((double)pool.length);

    NSMutableString *out = [NSMutableString stringWithCapacity:len];
    uint8_t bytes[64];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        for (NSUInteger i = 0; i < sizeof(bytes); i++) bytes[i] = (uint8_t)arc4random_uniform(256);
    }
    for (NSUInteger i = 0; i < len; i++) {
        NSUInteger idx = (NSUInteger)bytes[i] % pool.length;
        [out appendFormat:@"%C", [pool characterAtIndex:idx]];
    }
    return out;
}

static NSString *wq_decode_jwt_payload(NSString *token)
{
    NSString *trimmed = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"."];
    if (parts.count < 2) return WQLocalized(@"Not a valid JWT (expected header.payload.signature).");
    NSMutableString *result = [NSMutableString new];
    NSArray<NSString *> *labels = @[@"HEADER", @"PAYLOAD"];
    for (NSUInteger i = 0; i < 2; i++) {
        NSMutableString *b64 = [[parts[i] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
        [b64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b64.length)];
        while (b64.length % 4 != 0) [b64 appendString:@"="];
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        NSString *pretty = nil;
        if (raw.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
            if (obj) {
                NSData *p = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
                if (p) pretty = [[NSString alloc] initWithData:p encoding:NSUTF8StringEncoding];
            }
            if (!pretty) pretty = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
        }
        [result appendFormat:@"=== %@ ===\n%@\n\n", labels[i], pretty ?: WQLocalized(@"(unreadable)")];
    }
    return result;
}

#pragma mark - QR Modal

@interface WQQRModalViewController : UIViewController
@property (nonatomic, copy) NSString *payload;
@property (nonatomic, copy, nullable) NSString *modalTitle;
@end

@implementation WQQRModalViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.title = _modalTitle ?: WQLocalized(@"QR Code");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeModal)];

    UIVisualEffectView *card = wq_theme_make_glass_card(26.0, NO);
    [self.view addSubview:card];

    UIImage *qr = wq_render_qr_image(_payload, 560.0);
    UIView *qrBacking = [UIView new];
    qrBacking.translatesAutoresizingMaskIntoConstraints = NO;
    qrBacking.backgroundColor = UIColor.whiteColor;
    qrBacking.layer.cornerRadius = 18.0;
    qrBacking.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *iv = [[UIImageView alloc] initWithImage:qr];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.magnificationFilter = kCAFilterNearest;
    [qrBacking addSubview:iv];

    UILabel *caption = [UILabel new];
    caption.text = _payload;
    caption.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    caption.textColor = wq_theme_secondary_text();
    caption.textAlignment = NSTextAlignmentCenter;
    caption.numberOfLines = 4;

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    wq_theme_style_primary_button(shareBtn, WQLocalized(@"Share / Save QR"), @"square.and.arrow.up");
    __weak typeof(self) weakSelf = self;
    [shareBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        if (!qr || !weakSelf) return;
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[qr] applicationActivities:nil];
        av.popoverPresentationController.sourceView = shareBtn;
        av.popoverPresentationController.sourceRect = shareBtn.bounds;
        [weakSelf presentViewController:av animated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    wq_theme_style_secondary_button(copyBtn, WQLocalized(@"Copy Text"), @"doc.on.doc");
    [copyBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        UIPasteboard.generalPasteboard.string = weakSelf.payload;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *btnRow = [[UIStackView alloc] initWithArrangedSubviews:@[shareBtn, copyBtn]];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 10;
    btnRow.distribution = UIStackViewDistributionFillEqually;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[qrBacking, caption, btnRow]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    [card.contentView addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-22],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20],
        [qrBacking.widthAnchor constraintEqualToConstant:240],
        [qrBacking.heightAnchor constraintEqualToConstant:240],
        [iv.topAnchor constraintEqualToAnchor:qrBacking.topAnchor constant:14],
        [iv.bottomAnchor constraintEqualToAnchor:qrBacking.bottomAnchor constant:-14],
        [iv.leadingAnchor constraintEqualToAnchor:qrBacking.leadingAnchor constant:14],
        [iv.trailingAnchor constraintEqualToAnchor:qrBacking.trailingAnchor constant:-14],
        [caption.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [btnRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)closeModal
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void wq_present_qr_modal(UIViewController *host, NSString *payload, NSString *title)
{
    if (!host || !payload.length) return;
    WQQRModalViewController *vc = [WQQRModalViewController new];
    vc.payload = payload;
    vc.modalTitle = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [host presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Utility Workbench Controller

@interface WQWorkbenchViewController () <UIDocumentPickerDelegate>
@end

@implementation WQWorkbenchViewController {
    NSUInteger _pwLength;
    BOOL _pwUpper, _pwLower, _pwDigits, _pwSymbols;
    NSString *_lastPassword;
    double _lastEntropy;
    NSMutableArray<NSString *> *_snippets;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Utility Workbench");
        _pwLength = 20;
        _pwUpper = YES;
        _pwLower = YES;
        _pwDigits = YES;
        _pwSymbols = YES;
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
    [self loadSnippets];
    [self regeneratePassword];
}

- (void)loadSnippets
{
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kWQScratchpadPref];
    _snippets = [NSMutableArray new];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id item in saved) {
            if ([item isKindOfClass:NSString.class] && [(NSString *)item length]) [_snippets addObject:item];
        }
    }
}

- (void)saveSnippets
{
    [NSUserDefaults.standardUserDefaults setObject:_snippets forKey:kWQScratchpadPref];
}

- (void)regeneratePassword
{
    double ent = 0;
    _lastPassword = wq_generate_password(_pwLength, _pwUpper, _pwLower, _pwDigits, _pwSymbols, &ent);
    _lastEntropy = ent;
    [self.tableView reloadData];
}

- (void)promptQRText
{
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"Generate QR Code"),
        WQLocalized(@"Enter any URL, text, or identifier to render as a scannable QR code."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com";
        tf.text = UIPasteboard.generalPasteboard.string ?: @"";
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Generate"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *txt = alert.textFields.firstObject.text;
        if (txt.length) wq_present_qr_modal(self, txt, WQLocalized(@"QR Code"));
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptWiFiQR
{
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"Wi-Fi Login QR"),
        WQLocalized(@"Enter Wi-Fi network name (SSID) and password to generate a scan-to-join QR code."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Network Name (SSID)");
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Password (leave empty if open)");
        tf.secureTextEntry = YES;
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Generate"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *ssid = alert.textFields[0].text ?: @"";
        NSString *pass = alert.textFields[1].text ?: @"";
        if (!ssid.length) return;
        NSString *escSSID = [[ssid stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@";" withString:@"\\;"];
        NSString *escPass = [[pass stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@";" withString:@"\\;"];
        NSString *payload = pass.length
            ? [NSString stringWithFormat:@"WIFI:T:WPA;S:%@;P:%@;;", escSSID, escPass]
            : [NSString stringWithFormat:@"WIFI:T:nopass;S:%@;;", escSSID];
        wq_present_qr_modal(self, payload, [NSString stringWithFormat:@"Wi-Fi · %@", ssid]);
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickImageToDecodeQR
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *u = urls.firstObject;
    if (!u) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CIImage *ci = [CIImage imageWithContentsOfURL:u];
        NSMutableArray<NSString *> *found = [NSMutableArray new];
        if (ci) {
            CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
            for (CIFeature *f in [det featuresInImage:ci]) {
                if ([f isKindOfClass:CIQRCodeFeature.class]) {
                    NSString *msg = ((CIQRCodeFeature *)f).messageString;
                    if (msg.length) [found addObject:msg];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQWorkbenchViewController *me = weakSelf;
            if (!me) return;
            if (!found.count) {
                wq_alert(me, WQLocalized(@"No QR Code Found"), WQLocalized(@"No readable QR code was detected in that image."));
                return;
            }
            NSString *joined = [found componentsJoinedByString:@"\n\n"];
            UIAlertController *alert = wq_alert_controller(WQLocalized(@"Decoded QR Code"), joined, UIAlertControllerStyleAlert);
            [alert addAction:wq_alert_action(WQLocalized(@"Copy"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                UIPasteboard.generalPasteboard.string = joined;
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            })];
            [alert addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
            [me presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)promptAddSnippet
{
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"Pin Snippet / Note"),
        WQLocalized(@"Saved locally on-device for instant one-tap copy."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Paste or type text…");
        tf.text = UIPasteboard.generalPasteboard.string ?: @"";
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *s = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!s.length) return;
        [self->_snippets insertObject:s atIndex:0];
        [self saveSnippets];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self.tableView reloadData];
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptConverterKind:(NSInteger)kind
{
    NSArray<NSString *> *titles = @[
        WQLocalized(@"Base64 Encode"),
        WQLocalized(@"Base64 Decode"),
        WQLocalized(@"URL Encode / Decode"),
        WQLocalized(@"Hex Encode / Decode"),
        WQLocalized(@"JWT Payload Inspector"),
        WQLocalized(@"JSON Pretty-Print / Validate"),
    ];
    UIAlertController *alert = wq_alert_controller(titles[(NSUInteger)kind],
        WQLocalized(@"Paste text below (auto-filled from clipboard if available)."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = UIPasteboard.generalPasteboard.string ?: @"";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Convert"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *inp = alert.textFields.firstObject.text ?: @"";
        if (!inp.length) return;
        NSString *out = nil;
        if (kind == 0) {
            out = [[inp dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        } else if (kind == 1) {
            NSData *d = [[NSData alloc] initWithBase64EncodedString:inp options:NSDataBase64DecodingIgnoreUnknownCharacters];
            out = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: WQLocalized(@"(binary data)")) : WQLocalized(@"Invalid Base64 input.");
        } else if (kind == 2) {
            NSString *decoded = inp.stringByRemovingPercentEncoding;
            out = (decoded && ![decoded isEqualToString:inp])
                ? decoded
                : [inp stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        } else if (kind == 3) {
            NSString *clean = [inp stringByReplacingOccurrencesOfString:@" " withString:@""];
            NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
            if (clean.length >= 2 && clean.length % 2 == 0 && [clean rangeOfCharacterFromSet:nonHex].location == NSNotFound) {
                NSMutableData *buf = [NSMutableData dataWithCapacity:clean.length / 2];
                for (NSUInteger i = 0; i < clean.length; i += 2) {
                    unsigned int byteVal = 0;
                    [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byteVal];
                    uint8_t b = (uint8_t)byteVal;
                    [buf appendBytes:&b length:1];
                }
                out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: WQLocalized(@"(non-UTF8 bytes)");
            } else {
                NSData *d = [inp dataUsingEncoding:NSUTF8StringEncoding];
                const uint8_t *p = d.bytes;
                NSMutableString *hex = [NSMutableString stringWithCapacity:d.length * 2];
                for (NSUInteger i = 0; i < d.length; i++) [hex appendFormat:@"%02x", p[i]];
                out = hex;
            }
        } else if (kind == 4) {
            out = wq_decode_jwt_payload(inp);
        } else {
            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:[inp dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:&err];
            if (!obj) {
                out = err.localizedDescription ?: WQLocalized(@"Invalid JSON.");
            } else if ([NSJSONSerialization isValidJSONObject:obj]) {
                NSData *pretty = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
                out = pretty ? [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding] : [obj description];
            } else {
                out = [obj description];
            }
        }
        UIAlertController *res = wq_alert_controller(titles[(NSUInteger)kind], out ?: @"", UIAlertControllerStyleAlert);
        [res addAction:wq_alert_action(WQLocalized(@"Copy Result"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
            UIPasteboard.generalPasteboard.string = out ?: @"";
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        })];
        [res addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
        [self presentViewController:res animated:YES completion:nil];
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

// 0: QR Code Studio, 1: Password & UUID Generator, 2: Private Scratchpad & Clipboard, 3: Dev & Text Converters
- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 4; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    if (section == 1) return 4;
    if (section == 2) return 2 + (NSInteger)_snippets.count;
    return 6;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"QR Code Studio");
    if (section == 1) return WQLocalized(@"Password & UUID Generator");
    if (section == 2) return WQLocalized(@"Private Scratchpad & Clipboard");
    return WQLocalized(@"Text & Developer Converters");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"wb-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wb-cell"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.section == 0) {
        NSArray<NSArray<NSString *> *> *rows = @[
            @[WQLocalized(@"Generate Text / URL QR"), WQLocalized(@"Render crisp QR code to share or save"), @"qrcode"],
            @[WQLocalized(@"Generate Wi-Fi Login QR"), WQLocalized(@"Scan-to-join WPA/WPA2/WPA3 Wi-Fi QR"), @"wifi"],
            @[WQLocalized(@"Decode QR from Image"), WQLocalized(@"Read QR codes from saved screenshots/photos"), @"qrcode.viewfinder"],
        ];
        c.text = rows[(NSUInteger)indexPath.row][0];
        c.secondaryText = rows[(NSUInteger)indexPath.row][1];
        c.image = [UIImage systemImageNamed:rows[(NSUInteger)indexPath.row][2]];
        c.imageProperties.tintColor = wq_theme_accent();
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            c.text = _lastPassword ?: @"";
            c.textProperties.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightSemibold];
            c.textProperties.numberOfLines = 2;
            NSString *strength = _lastEntropy >= 100 ? WQLocalized(@"Very Strong")
                               : _lastEntropy >= 70 ? WQLocalized(@"Strong") : WQLocalized(@"Moderate");
            c.secondaryText = WQLocalizedFormat(@"Tap to Copy · %lu chars · %.0f bits (%@)", (unsigned long)_pwLength, _lastEntropy, strength);
            c.secondaryTextProperties.color = wq_theme_aurora_teal();
            c.image = [UIImage systemImageNamed:@"key.fill"];
            c.imageProperties.tintColor = wq_theme_aurora_teal();
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Regenerate Password");
            c.secondaryText = WQLocalizedFormat(@"Length: %lu · Symbols: %@", (unsigned long)_pwLength, _pwSymbols ? WQLocalized(@"On") : WQLocalized(@"Off"));
            c.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            c.imageProperties.tintColor = wq_theme_accent();
        } else if (indexPath.row == 2) {
            c.text = WQLocalized(@"Customize Length & Symbols");
            c.secondaryText = WQLocalized(@"Cycle length (12 / 16 / 20 / 32) or toggle symbols");
            c.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            c.imageProperties.tintColor = wq_theme_accent();
        } else {
            c.text = WQLocalized(@"Copy Fresh UUID v4");
            c.secondaryText = WQLocalized(@"Generates a random RFC 4122 UUID immediately");
            c.image = [UIImage systemImageNamed:@"number.square.fill"];
            c.imageProperties.tintColor = wq_theme_accent();
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Pin New Snippet / Paste Clipboard");
            c.secondaryText = WQLocalized(@"Save quick notes or paths on-device");
            c.image = [UIImage systemImageNamed:@"pin.fill"];
            c.imageProperties.tintColor = wq_theme_accent();
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Clear System Clipboard");
            c.secondaryText = WQLocalized(@"Instantly wipe copied passwords or sensitive text");
            c.image = [UIImage systemImageNamed:@"trash.slash.fill"];
            c.imageProperties.tintColor = UIColor.systemRedColor;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSString *snip = _snippets[(NSUInteger)indexPath.row - 2];
            c.text = snip;
            c.textProperties.numberOfLines = 2;
            c.secondaryText = WQLocalized(@"Tap to copy · Swipe left to delete");
            c.image = [UIImage systemImageNamed:@"doc.text"];
            c.imageProperties.tintColor = wq_theme_secondary_text();
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else {
        NSArray<NSArray<NSString *> *> *conv = @[
            @[WQLocalized(@"Base64 Encode"), @"text.badge.plus"],
            @[WQLocalized(@"Base64 Decode"), @"text.badge.checkmark"],
            @[WQLocalized(@"URL Encode / Decode"), @"link"],
            @[WQLocalized(@"Hex Encode / Decode"), @"number"],
            @[WQLocalized(@"JWT Payload Inspector"), @"lock.doc.fill"],
            @[WQLocalized(@"JSON Pretty-Print / Validate"), @"curlybraces"],
        ];
        c.text = conv[(NSUInteger)indexPath.row][0];
        c.image = [UIImage systemImageNamed:conv[(NSUInteger)indexPath.row][1]];
        c.imageProperties.tintColor = wq_theme_accent();
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self promptQRText];
        else if (indexPath.row == 1) [self promptWiFiQR];
        else [self pickImageToDecodeQR];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            UIPasteboard.generalPasteboard.string = _lastPassword;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Copied"), WQLocalized(@"Password copied to clipboard."));
        } else if (indexPath.row == 1) {
            [self regeneratePassword];
        } else if (indexPath.row == 2) {
            UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Password Options"), nil, UIAlertControllerStyleActionSheet);
            for (NSNumber *len in @[@12, @16, @20, @32]) {
                [sheet addAction:wq_alert_action(WQLocalizedFormat(@"%@ characters", len), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    self->_pwLength = len.unsignedIntegerValue;
                    [self regeneratePassword];
                })];
            }
            [sheet addAction:wq_alert_action(_pwSymbols ? WQLocalized(@"Turn Symbols Off") : WQLocalized(@"Turn Symbols On"),
                UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                self->_pwSymbols = !self->_pwSymbols;
                [self regeneratePassword];
            })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            sheet.popoverPresentationController.sourceView = cell ?: self.view;
            sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
            [self presentViewController:sheet animated:YES completion:nil];
        } else {
            NSString *uuid = NSUUID.UUID.UUIDString;
            UIPasteboard.generalPasteboard.string = uuid;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"UUID Copied"), uuid);
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self promptAddSnippet];
        } else if (indexPath.row == 1) {
            UIPasteboard.generalPasteboard.items = @[];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Clipboard Cleared"), WQLocalized(@"The system clipboard has been wiped."));
        } else {
            NSString *snip = _snippets[(NSUInteger)indexPath.row - 2];
            UIPasteboard.generalPasteboard.string = snip;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        }
    } else {
        [self promptConverterKind:indexPath.row];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 2 || indexPath.row < 2) return nil;
    NSUInteger idx = (NSUInteger)indexPath.row - 2;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:WQLocalized(@"Delete") handler:^(UIContextualAction *__unused act, UIView *__unused v, void (^done)(BOOL)) {
        if (idx < self->_snippets.count) {
            [self->_snippets removeObjectAtIndex:idx];
            [self saveSnippets];
            [self.tableView reloadData];
        }
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
