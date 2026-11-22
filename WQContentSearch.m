//
//  WQContentSearch.m
//  WQ Glass Deep Content & Regular Expression Grep Search
//  GPL-3.0-or-later.
//

#import "WQContentSearch.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQDir.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <string.h>
#import <sys/stat.h>

@interface WQGrepMatch : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *displayPath;
@property (nonatomic) NSUInteger lineNumber;
@property (nonatomic, copy) NSString *snippet;
@end

@implementation WQGrepMatch
@end

static BOOL wq_grep_ext_allowed(NSString *ext, NSInteger extMode)
{
    NSString *e = ext.lowercaseString;
    static NSSet *allText, *codeExts, *jsonPlist, *logExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        codeExts = [NSSet setWithArray:@[@"m", @"h", @"c", @"cpp", @"hpp", @"swift", @"js", @"ts", @"py", @"sh", @"rb", @"go", @"rs", @"java", @"html", @"css", @"sql"]];
        jsonPlist = [NSSet setWithArray:@[@"json", @"plist", @"xml", @"yaml", @"yml", @"strings", @"entitlements"]];
        logExts = [NSSet setWithArray:@[@"log", @"txt", @"crash", @"ips", @"diag", @"csv", @"md"]];
        NSMutableSet *merged = [NSMutableSet setWithSet:codeExts];
        [merged unionSet:jsonPlist];
        [merged unionSet:logExts];
        [merged addObjectsFromArray:@[@"ini", @"conf", @"cfg", @"env", @"toml", @"properties"]];
        allText = merged;
    });
    if (extMode == 1) return [codeExts containsObject:e];
    if (extMode == 2) return [jsonPlist containsObject:e];
    if (extMode == 3) return [logExts containsObject:e];
    return e.length == 0 || [allText containsObject:e];
}

static BOOL wq_data_looks_binary(NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger check = MIN(data.length, (NSUInteger)512);
    for (NSUInteger i = 0; i < check; i++) {
        if (bytes[i] == 0) return YES;
    }
    return NO;
}

@interface WQContentSearchViewController () <UISearchBarDelegate>
@end

@implementation WQContentSearchViewController {
    NSString *_rootPath;
    NSString *_rootTitle;
    BOOL _readOnly;
    BOOL _caseInsensitive;
    BOOL _useRegex;
    NSInteger _extMode; // 0 All Text, 1 Code, 2 JSON/Plist, 3 Logs/Txt
    BOOL _searching;
    WQScanCancellation *_cancel;
    NSString *_status;
    NSArray<WQGrepMatch *> *_matches;
    UISearchBar *_searchBar;
    UISegmentedControl *_extControl;
}

- (instancetype)initWithRootPath:(NSString *)rootPath title:(NSString *)title readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _rootPath = [rootPath copy];
        _rootTitle = title.length ? [title copy] : (rootPath.lastPathComponent.length ? rootPath.lastPathComponent : @"/");
        _readOnly = readOnly;
        _caseInsensitive = YES;
        _useRegex = NO;
        _extMode = 0;
        _matches = @[];
        self.title = WQLocalized(@"Content Grep");
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
    [self installSearchHeader];
    [self updateNavButton];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopSearch) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self stopSearch];
}

- (void)dealloc
{
    [_cancel cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)updateNavButton
{
    if (_searching) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Stop")
                                                                                  style:UIBarButtonItemStylePlain
                                                                                 target:self
                                                                                 action:@selector(stopSearch)];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Options")
                                                                                  style:UIBarButtonItemStylePlain
                                                                                 target:self
                                                                                 action:@selector(toggleOptions)];
    }
}

- (void)installSearchHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 108)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _searchBar = [UISearchBar new];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = WQLocalizedFormat(@"Grep inside %@…", _rootTitle);
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchBar.delegate = self;

    _extControl = [[UISegmentedControl alloc] initWithItems:@[
        WQLocalized(@"All Text"),
        WQLocalized(@"Code"),
        WQLocalized(@"JSON/Plist"),
        WQLocalized(@"Logs"),
    ]];
    _extControl.translatesAutoresizingMaskIntoConstraints = NO;
    _extControl.selectedSegmentIndex = _extMode;
    [_extControl addTarget:self action:@selector(extChanged) forControlEvents:UIControlEventValueChanged];

    [box addSubview:_searchBar];
    [box addSubview:_extControl];
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:box.topAnchor constant:4],
        [_searchBar.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
        [_searchBar.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],
        [_extControl.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:4],
        [_extControl.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [_extControl.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [_extControl.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
    ]];
    self.tableView.tableHeaderView = box;
}

- (void)extChanged
{
    _extMode = _extControl.selectedSegmentIndex;
    wq_haptic_selection();
    if (_searchBar.text.length) [self runGrepForQuery:_searchBar.text];
}

- (void)toggleOptions
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Grep Search Options"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(_caseInsensitive ? WQLocalized(@"Case-Insensitive: ON") : WQLocalized(@"Case-Insensitive: OFF"),
                                     UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_caseInsensitive = !self->_caseInsensitive;
        if (self->_searchBar.text.length) [self runGrepForQuery:self->_searchBar.text];
    })];
    [sheet addAction:wq_alert_action(_useRegex ? WQLocalized(@"Regular Expression (Regex): ON") : WQLocalized(@"Regular Expression (Regex): OFF"),
                                     UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_useRegex = !self->_useRegex;
        if (self->_searchBar.text.length) [self runGrepForQuery:self->_searchBar.text];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    if (searchBar.text.length) [self runGrepForQuery:searchBar.text];
}

- (void)stopSearch
{
    [_cancel cancel];
    if (_searching) {
        _searching = NO;
        _status = nil;
        [self updateNavButton];
        [self.tableView reloadData];
    }
}

- (void)runGrepForQuery:(NSString *)query
{
    [_cancel cancel];
    if (!query.length) return;

    NSRegularExpression *regex = nil;
    if (_useRegex) {
        NSError *rxErr = nil;
        NSRegularExpressionOptions opts = _caseInsensitive ? NSRegularExpressionCaseInsensitive : 0;
        regex = [NSRegularExpression regularExpressionWithPattern:query options:opts error:&rxErr];
        if (!regex) {
            wq_alert(self, WQLocalized(@"Invalid Regular Expression"), rxErr.localizedDescription ?: WQLocalized(@"Check your regex pattern."));
            return;
        }
    }

    WQScanCancellation *cancel = [WQScanCancellation new];
    _cancel = cancel;
    _searching = YES;
    _matches = @[];
    _status = WQLocalizedFormat(@"Searching file contents for “%@”…", query);
    [self updateNavButton];
    [self.tableView reloadData];

    NSString *root = _rootPath;
    BOOL caseInsens = _caseInsensitive;
    NSInteger extMode = _extMode;
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

        NSMutableArray<NSString *> *pending = [NSMutableArray new];
        if ([containerParents containsObject:root]) {
            NSArray<NSString *> *containers = wq_enumerate(root, 0, nil, nil) ?: @[];
            for (NSString *c in containers) {
                if (cancel.isCancelled) break;
                wq_grant(c);
                [pending addObject:c];
            }
        } else {
            wq_grant(root);
            [pending addObject:root];
        }

        NSMutableArray<WQGrepMatch *> *found = [NSMutableArray new];
        NSUInteger scannedFiles = 0;
        CFAbsoluteTime lastPing = 0;
        NSStringCompareOptions cmpOpts = caseInsens ? NSCaseInsensitiveSearch : 0;

        while (pending.count && !cancel.isCancelled && found.count < 250 && scannedFiles < 30000) {
            @autoreleasepool {
                NSString *dir = pending.lastObject;
                [pending removeLastObject];
                NSArray<NSString *> *names = wq_list(dir, NULL);
                for (NSString *n in names) {
                    if (cancel.isCancelled || found.count >= 250) break;
                    NSString *p = [dir stringByAppendingPathComponent:n];
                    struct stat st;
                    if (lstat(p.fileSystemRepresentation, &st) != 0) {
                        if (!wq_stat(p, &st)) continue;
                    }
                    if (S_ISLNK(st.st_mode)) continue;
                    if (S_ISDIR(st.st_mode)) {
                        [pending addObject:p];
                        continue;
                    }
                    if (!S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 2 * 1024 * 1024) continue;
                    if (!wq_grep_ext_allowed(n.pathExtension, extMode)) continue;

                    scannedFiles++;
                    NSData *data = wq_read(p, 2 * 1024 * 1024, NULL);
                    if (!data.length) continue;

                    NSString *text = nil;
                    // Support binary plists automatically when searching JSON/Plist or All Text!
                    if (data.length >= 6 && memcmp(data.bytes, "bplist", 6) == 0) {
                        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
                        if (plist) text = [plist description];
                    } else if (!wq_data_looks_binary(data)) {
                        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                            ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                    }
                    if (!text.length) continue;

                    // Quick whole-file pre-check before splitting lines
                    BOOL hitFile = regex
                        ? ([regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil)
                        : ([text rangeOfString:query options:cmpOpts].location != NSNotFound);
                    if (!hitFile) continue;

                    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
                    NSUInteger fileHits = 0;
                    for (NSUInteger i = 0; i < lines.count && fileHits < 5 && found.count < 250; i++) {
                        NSString *line = lines[i];
                        BOOL matched = regex
                            ? ([regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil)
                            : ([line rangeOfString:query options:cmpOpts].location != NSNotFound);
                        if (matched) {
                            WQGrepMatch *m = [WQGrepMatch new];
                            m.path = p;
                            NSString *rel = [p hasPrefix:root] ? [p substringFromIndex:root.length] : p;
                            if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
                            m.displayPath = rel.length ? rel : p.lastPathComponent;
                            m.lineNumber = i + 1;
                            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                            m.snippet = trim.length > 140 ? [[trim substringToIndex:140] stringByAppendingString:@"…"] : trim;
                            [found addObject:m];
                            fileHits++;
                        }
                    }

                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - lastPing > 0.30) {
                        lastPing = now;
                        NSUInteger sc = scannedFiles;
                        NSArray<WQGrepMatch *> *snap = [found copy];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            WQContentSearchViewController *me = weakSelf;
                            if (!me || cancel.isCancelled) return;
                            me->_matches = snap;
                            me->_status = WQLocalizedFormat(@"Scanned %lu files · %lu matches…", (unsigned long)sc, (unsigned long)snap.count);
                            [me.tableView reloadData];
                        });
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            WQContentSearchViewController *me = weakSelf;
            if (!me) return;
            me->_searching = NO;
            me->_matches = found;
            me->_status = WQLocalizedFormat(@"%lu matches across %lu text files%@",
                                            (unsigned long)found.count, (unsigned long)scannedFiles,
                                            cancel.isCancelled ? WQLocalized(@" (stopped)") : @"");
            [me updateNavButton];
            [me.tableView reloadData];
        });
    });
}

- (void)openMatchPreview:(WQGrepMatch *)match
{
    NSData *raw = wq_read(match.path, 2 * 1024 * 1024, NULL);
    NSString *text = nil;
    if (raw.length >= 6 && memcmp(raw.bytes, "bplist", 6) == 0) {
        id plist = [NSPropertyListSerialization propertyListWithData:raw options:0 format:NULL error:nil];
        text = [plist description];
    } else if (raw.length) {
        text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    }
    UIViewController *vc = [UIViewController new];
    vc.title = [NSString stringWithFormat:@"%@ : L%lu", match.path.lastPathComponent, (unsigned long)match.lineNumber];
    vc.view.backgroundColor = wq_theme_canvas_top();

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.textColor = wq_theme_primary_text();
    tv.backgroundColor = UIColor.clearColor;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 20, 12);
    tv.text = text ?: WQLocalized(@"Unable to display file contents.");
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];

    NSString *parentDir = match.path.stringByDeletingLastPathComponent;
    BOOL ro = _readOnly;
    __weak typeof(self) weakSelf = self;
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Open Folder") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *__unused a) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:parentDir title:nil];
        dir.readOnly = ro;
        [weakSelf.navigationController pushViewController:dir animated:YES];
    }]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_matches.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger __unused)section
{
    if (_status.length) return _status;
    return WQLocalizedFormat(@"Mode: %@ · %@", _useRegex ? @"Regex" : @"Plain Text", _caseInsensitive ? @"Case-Insensitive" : @"Case-Sensitive");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"grep-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"grep-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_matches.count) {
        c.text = _searching ? WQLocalized(@"Searching…") : WQLocalized(@"Type a word or regex pattern and tap Search");
        c.secondaryText = WQLocalized(@"Searches inside text, code, JSON, binary/XML plists, and logs offline.");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQGrepMatch *m = _matches[(NSUInteger)indexPath.row];
    c.text = [NSString stringWithFormat:@"%@  (L%lu)", m.displayPath, (unsigned long)m.lineNumber];
    c.secondaryText = m.snippet;
    c.textProperties.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    c.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    c.secondaryTextProperties.color = wq_theme_aurora_teal();
    c.secondaryTextProperties.numberOfLines = 2;
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_matches.count) return;
    wq_haptic_selection();
    [self openMatchPreview:_matches[(NSUInteger)indexPath.row]];
}

@end
