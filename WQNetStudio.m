//
//  WQNetStudio.m
//  WQ Glass Pro HTTP / REST API Tester & cURL Generator
//  GPL-3.0-or-later.
//

#import "WQNetStudio.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"

static NSString *const kWQNetPresetsPref = @"WQNetStudioPresets";

static NSString *wq_net_studio_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"API Responses"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_shell_single_quote(NSString *s)
{
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"]];
}

@implementation WQNetStudioViewController {
    NSString *_method;
    NSString *_urlText;
    NSString *_headersText;
    NSString *_bodyText;
    BOOL _loading;
    NSInteger _statusCode;
    double _latencyMs;
    NSUInteger _responseBytes;
    NSDictionary *_responseHeaders;
    NSString *_responseBody;
    NSString *_responseError;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_presets;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _method = @"GET";
        _urlText = @"https://httpbin.org/get";
        _headersText = @"Accept: application/json";
        _bodyText = @"";
        self.title = WQLocalized(@"HTTP / API Studio");
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
    [self loadPresets];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Send")
                                                                              style:wq_primary_button_style()
                                                                             target:self
                                                                             action:@selector(sendRequest)];
}

- (void)loadPresets
{
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kWQNetPresetsPref];
    _presets = [NSMutableArray new];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id obj in saved) {
            if ([obj isKindOfClass:NSDictionary.class]) [_presets addObject:obj];
        }
    }
    if (!_presets.count) {
        [_presets addObjectsFromArray:@[
            @{ @"name": @"HTTPBin GET", @"method": @"GET", @"url": @"https://httpbin.org/get", @"headers": @"Accept: application/json", @"body": @"" },
            @{ @"name": @"GitHub Zen", @"method": @"GET", @"url": @"https://api.github.com/zen", @"headers": @"User-Agent: WQGlass", @"body": @"" },
            @{ @"name": @"HTTPBin POST JSON", @"method": @"POST", @"url": @"https://httpbin.org/post", @"headers": @"Content-Type: application/json", @"body": @"{\"app\":\"WQ Glass\"}" },
        ]];
    }
}

- (void)saveCurrentPreset
{
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Save Request Preset"), _urlText, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = WQLocalized(@"Preset name");
        f.text = [NSURL URLWithString:self->_urlText].host ?: @"Request";
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Save", UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *nm = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!nm.length) nm = @"Preset";
        [self->_presets insertObject:@{
            @"name": nm,
            @"method": self->_method ?: @"GET",
            @"url": self->_urlText ?: @"",
            @"headers": self->_headersText ?: @"",
            @"body": self->_bodyText ?: @"",
        } atIndex:0];
        while (self->_presets.count > 20) [self->_presets removeLastObject];
        [NSUserDefaults.standardUserDefaults setObject:self->_presets forKey:kWQNetPresetsPref];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self.tableView reloadData];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSDictionary<NSString *, NSString *> *)parsedHeaders
{
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary new];
    for (NSString *line in [_headersText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *v = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (k.length) out[k] = v;
    }
    return out;
}

- (NSString *)curlCommand
{
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:@"curl", @"-X", _method ?: @"GET", nil];
    NSDictionary<NSString *, NSString *> *hdrs = [self parsedHeaders];
    for (NSString *k in hdrs) {
        [parts addObject:@"-H"];
        [parts addObject:wq_shell_single_quote([NSString stringWithFormat:@"%@: %@", k, hdrs[k]])];
    }
    if (_bodyText.length && !([_method isEqualToString:@"GET"] || [_method isEqualToString:@"HEAD"])) {
        [parts addObject:@"-d"];
        [parts addObject:wq_shell_single_quote(_bodyText)];
    }
    [parts addObject:wq_shell_single_quote(_urlText ?: @"")];
    return [parts componentsJoinedByString:@" "];
}

- (void)sendRequest
{
    if (_loading) return;
    NSURL *url = [NSURL URLWithString:[_urlText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (!url || !url.scheme.length || !url.host.length) {
        wq_alert(self, WQLocalized(@"Invalid URL"), WQLocalized(@"Enter a full http:// or https:// URL."));
        return;
    }
    _loading = YES;
    _responseError = nil;
    _responseBody = nil;
    _responseHeaders = nil;
    _statusCode = 0;
    _latencyMs = 0;
    _responseBytes = 0;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.tableView reloadData];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    req.HTTPMethod = _method ?: @"GET";
    NSDictionary<NSString *, NSString *> *hdrs = [self parsedHeaders];
    for (NSString *k in hdrs) [req setValue:hdrs[k] forHTTPHeaderField:k];
    if (_bodyText.length && !([req.HTTPMethod isEqualToString:@"GET"] || [req.HTTPMethod isEqualToString:@"HEAD"])) {
        req.HTTPBody = [_bodyText dataUsingEncoding:NSUTF8StringEncoding];
    }

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSString *pretty = nil;
        if (data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json) {
                NSData *pd = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
                if (pd) pretty = [[NSString alloc] initWithData:pd encoding:NSUTF8StringEncoding];
            }
            if (!pretty) {
                pretty = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]
                    ?: WQLocalizedFormat(@"<Binary response: %@>", wq_size_text(data.length));
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQNetStudioViewController *me = weakSelf;
            if (!me) return;
            me->_loading = NO;
            me.navigationItem.rightBarButtonItem.enabled = YES;
            me->_latencyMs = ms;
            me->_statusCode = http ? http.statusCode : 0;
            me->_responseHeaders = http ? http.allHeaderFields : nil;
            me->_responseBytes = data.length;
            me->_responseBody = pretty;
            me->_responseError = error.localizedDescription;
            wq_haptic_notify(error ? UINotificationFeedbackTypeError : UINotificationFeedbackTypeSuccess);
            [me.tableView reloadData];
        });
    }];
    [task resume];
}

- (void)showTextModalWithTitle:(NSString *)title body:(NSString *)body
{
    UIViewController *vc = [UIViewController new];
    vc.title = title;
    vc.view.backgroundColor = wq_theme_canvas_top();

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.textColor = wq_theme_primary_text();
    tv.backgroundColor = UIColor.clearColor;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 20, 12);
    tv.text = body ?: @"";
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];

    NSString *copyText = [body copy] ?: @"";
    __weak UIViewController *weakVC = vc;
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Copy") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
        UIPasteboard.generalPasteboard.string = copyText;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        wq_alert(weakVC, WQLocalized(@"Copied"), WQLocalized(@"Content copied to clipboard."));
    }]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)editMultilineTitle:(NSString *)title current:(NSString *)current onSave:(void (^)(NSString *val))onSave
{
    UIViewController *vc = [UIViewController new];
    vc.title = title;
    vc.view.backgroundColor = wq_theme_canvas_top();

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    tv.textColor = wq_theme_primary_text();
    tv.backgroundColor = [wq_theme_glass_tint() colorWithAlphaComponent:0.45];
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.text = current ?: @"";
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.keyboardLayoutGuide.topAnchor constant:-8],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:12],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-12],
    ]];

    __weak UIViewController *weakVC = vc;
    vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Cancel") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakVC dismissViewControllerAnimated:YES completion:nil];
    }]];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Save") image:nil identifier:nil handler:^(UIAction *__unused a) {
        NSString *val = tv.text ?: @"";
        [weakVC dismissViewControllerAnimated:YES completion:^{ if (onSave) onSave(val); }];
    }]];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:^{ [tv becomeFirstResponder]; }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 3; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 6;
    if (section == 1) return (_responseBody.length || _responseHeaders.count || _responseError.length) ? 4 : 1;
    return (NSInteger)_presets.count;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Request Builder");
    if (section == 1) {
        if (_loading) return WQLocalized(@"Sending Request…");
        if (_statusCode > 0) return [NSString stringWithFormat:@"Response · HTTP %ld · %.0f ms · %@", (long)_statusCode, _latencyMs, wq_size_text(_responseBytes)];
        return WQLocalized(@"Response");
    }
    return WQLocalized(@"Saved Request Presets");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"net-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"net-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.imageProperties.tintColor = wq_theme_accent();

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"HTTP Method");
            c.secondaryText = _method;
            c.image = [UIImage systemImageNamed:@"arrow.left.arrow.right.circle.fill"];
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Endpoint URL");
            c.secondaryText = _urlText;
            c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
            c.image = [UIImage systemImageNamed:@"globe"];
        } else if (indexPath.row == 2) {
            c.text = WQLocalized(@"Headers (Key: Value)");
            c.secondaryText = _headersText.length ? _headersText : WQLocalized(@"None");
            c.secondaryTextProperties.numberOfLines = 2;
            c.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        } else if (indexPath.row == 3) {
            c.text = WQLocalized(@"Request Body");
            c.secondaryText = _bodyText.length ? _bodyText : WQLocalized(@"Empty");
            c.secondaryTextProperties.numberOfLines = 2;
            c.image = [UIImage systemImageNamed:@"curlybraces"];
        } else if (indexPath.row == 4) {
            c.text = WQLocalized(@"Copy as cURL Command");
            c.secondaryText = [self curlCommand];
            c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingTail;
            c.image = [UIImage systemImageNamed:@"terminal.fill"];
        } else {
            c.text = WQLocalized(@"Save as Preset…");
            c.secondaryText = WQLocalized(@"Bookmark this request for 1-tap replay");
            c.image = [UIImage systemImageNamed:@"bookmark.fill"];
        }
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 1) {
        if (!(_responseBody.length || _responseHeaders.count || _responseError.length)) {
            c.text = _loading ? WQLocalized(@"Waiting for server…") : WQLocalized(@"Tap Send to execute request");
            c.secondaryText = nil;
            c.image = nil;
            c.textProperties.color = wq_theme_secondary_text();
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
        if (indexPath.row == 0) {
            c.text = _responseError.length ? WQLocalized(@"Request Error") : WQLocalizedFormat(@"HTTP %ld (%.0f ms)", (long)_statusCode, _latencyMs);
            c.secondaryText = _responseError ?: WQLocalizedFormat(@"%@ received", wq_size_text(_responseBytes));
            c.image = [UIImage systemImageNamed:_responseError.length ? @"xmark.octagon.fill" : @"checkmark.circle.fill"];
            c.imageProperties.tintColor = _responseError.length ? UIColor.systemRedColor : (_statusCode >= 200 && _statusCode < 300 ? UIColor.systemGreenColor : UIColor.systemOrangeColor);
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"View Response Body");
            c.secondaryText = _responseBody.length ? [_responseBody substringToIndex:MIN(_responseBody.length, (NSUInteger)90)] : WQLocalized(@"Empty body");
            c.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            c.text = WQLocalized(@"Inspect Response Headers");
            c.secondaryText = WQLocalizedFormat(@"%lu headers", (unsigned long)_responseHeaders.count);
            c.image = [UIImage systemImageNamed:@"list.bullet.indent"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            c.text = WQLocalized(@"Save Response to File & Share");
            c.secondaryText = WQLocalized(@"Saves into Documents/API Responses");
            c.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.contentConfiguration = c;
        return cell;
    }

    NSDictionary<NSString *, NSString *> *p = _presets[(NSUInteger)indexPath.row];
    c.text = [NSString stringWithFormat:@"[%@] %@", p[@"method"] ?: @"GET", p[@"name"] ?: @"Preset"];
    c.secondaryText = p[@"url"];
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:@"bolt.horizontal.circle.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            UIAlertController *sh = wq_alert_controller(WQLocalized(@"HTTP Method"), nil, UIAlertControllerStyleActionSheet);
            for (NSString *m in @[@"GET", @"POST", @"PUT", @"DELETE", @"HEAD"]) {
                [sh addAction:wq_alert_action(m, UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    self->_method = m;
                    [self.tableView reloadData];
                })];
            }
            [sh addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            sh.popoverPresentationController.sourceView = cell ?: self.view;
            sh.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
            [self presentViewController:sh animated:YES completion:nil];
        } else if (indexPath.row == 1) {
            UIAlertController *a = wq_alert_controller(WQLocalized(@"Endpoint URL"), nil, UIAlertControllerStyleAlert);
            [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
                f.text = self->_urlText;
                f.keyboardType = UIKeyboardTypeURL;
                f.autocapitalizationType = UITextAutocapitalizationTypeNone;
                f.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
            [a addAction:wq_alert_action(@"Set", UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
                NSString *u = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (u.length) self->_urlText = u;
                [self.tableView reloadData];
            })];
            [self presentViewController:a animated:YES completion:nil];
        } else if (indexPath.row == 2) {
            [self editMultilineTitle:WQLocalized(@"Headers (Key: Value)") current:_headersText onSave:^(NSString *val) {
                self->_headersText = val;
                [self.tableView reloadData];
            }];
        } else if (indexPath.row == 3) {
            [self editMultilineTitle:WQLocalized(@"Request Body") current:_bodyText onSave:^(NSString *val) {
                self->_bodyText = val;
                [self.tableView reloadData];
            }];
        } else if (indexPath.row == 4) {
            UIPasteboard.generalPasteboard.string = [self curlCommand];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"cURL Copied"), [self curlCommand]);
        } else {
            [self saveCurrentPreset];
        }
        return;
    }

    if (indexPath.section == 1 && (_responseBody.length || _responseHeaders.count)) {
        if (indexPath.row == 1) {
            [self showTextModalWithTitle:WQLocalized(@"Response Body") body:_responseBody ?: @""];
        } else if (indexPath.row == 2) {
            NSMutableArray<NSString *> *lines = [NSMutableArray new];
            for (id k in [_responseHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", k, _responseHeaders[k]]];
            }
            [self showTextModalWithTitle:WQLocalized(@"Response Headers") body:[lines componentsJoinedByString:@"\n"]];
        } else if (indexPath.row == 3 && _responseBody.length) {
            NSString *ext = ([_responseBody hasPrefix:@"{"] || [_responseBody hasPrefix:@"["]) ? @"json" : @"txt";
            NSString *fname = [NSString stringWithFormat:@"response_%ld.%@", (long)NSDate.date.timeIntervalSince1970, ext];
            NSString *outPath = [wq_net_studio_output_dir() stringByAppendingPathComponent:fname];
            if ([_responseBody writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                share.popoverPresentationController.sourceView = self.view;
                [self presentViewController:share animated:YES completion:nil];
            }
        }
        return;
    }

    if (indexPath.section == 2 && (NSUInteger)indexPath.row < _presets.count) {
        NSDictionary<NSString *, NSString *> *p = _presets[(NSUInteger)indexPath.row];
        _method = p[@"method"] ?: @"GET";
        _urlText = p[@"url"] ?: @"";
        _headersText = p[@"headers"] ?: @"";
        _bodyText = p[@"body"] ?: @"";
        [self.tableView reloadData];
    }
}

@end
