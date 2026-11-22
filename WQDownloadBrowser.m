//
//  WQDownloadBrowser.m
//  WQ Glass 1DM / IDM Style Built-In Ad-Blocking Browser, Media Sniffer & Page Grabber
//  GPL-3.0-or-later.
//

#import "WQDownloadBrowser.h"
#import "WQDownloadManager.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <WebKit/WebKit.h>

static NSString *const kWQBrowserBookmarksPref = @"WQBrowserBookmarks";
static NSString *const kWQBrowserAdBlockPref = @"WQBrowserAdBlockEnabled";
static NSString *const kWQBrowserHomepage = @"https://duckduckgo.com";
static NSString *const kWQDesktopUA = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

#pragma mark - Weak WKScriptMessageHandler Proxy (Prevents Retain Cycles)

@interface WQWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation WQWeakScriptMessageHandler
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}
@end

#pragma mark - Browser Models

@interface WQSniffedMedia : NSObject
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, copy, nullable) NSString *cookie;
@property (nonatomic, copy, nullable) NSString *userAgent;
@property (nonatomic) BOOL isHLS;
@end

@implementation WQSniffedMedia
@end

@interface WQBrowserTab : NSObject
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic) BOOL incognito;
@property (nonatomic) BOOL desktopMode;
@property (nonatomic, strong) NSMutableArray<WQSniffedMedia *> *media;
@property (nonatomic, strong) NSMutableSet<NSString *> *seenURLs;
@property (nonatomic, copy) NSString *pageTitle;
@end

@implementation WQBrowserTab
- (instancetype)init
{
    if ((self = [super init])) {
        _media = [NSMutableArray new];
        _seenURLs = [NSMutableSet new];
        _pageTitle = @"New Tab";
    }
    return self;
}
@end

#pragma mark - Ad Blocker Rules & Media Sniffer UserScript

static NSString *wq_browser_adblock_rules_json(void)
{
    return @"["
        "{\"trigger\":{\"url-filter\":\".*(doubleclick\\\\.net|googlesyndication\\\\.com|googleadservices\\\\.com|adservice\\\\.google\\\\.|taboola\\\\.com|outbrain\\\\.com|popads\\\\.net|popcash\\\\.net|propellerads\\\\.com|exoclick\\\\.com|juicyads\\\\.com|adnxs\\\\.com|criteo\\\\.com|scorecardresearch\\\\.com|amazon-adsystem\\\\.com).*\"},\"action\":{\"type\":\"block\"}}"
    "]";
}

static NSString *wq_browser_media_sniffer_js(void)
{
    return @"(function(){"
    "if(window.__wqSniffInstalled) return; window.__wqSniffInstalled = true;"
    "var seen = {};"
    "var rx = /\\.(m3u8|mp4|m4v|mov|webm|mp3|m4a|aac|flac|ogg|wav)(\\?|#|$)/i;"
    "function report(raw, hint){"
    "  try{"
    "    if(!raw || typeof raw !== 'string') return;"
    "    if(raw.indexOf('blob:')===0 || raw.indexOf('data:')===0) return;"
    "    var abs = new URL(raw, location.href).href;"
    "    if(seen[abs]) return;"
    "    var m = abs.match(rx);"
    "    if(!m && !hint) return;"
    "    seen[abs] = 1;"
    "    var ext = m ? m[1].toUpperCase() : (hint || 'MEDIA');"
    "    if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wqMediaSniff){"
    "      window.webkit.messageHandlers.wqMediaSniff.postMessage({"
    "        url: abs, kind: ext, title: document.title || '',"
    "        referer: location.href, cookie: document.cookie || '', ua: navigator.userAgent || ''"
    "      });"
    "    }"
    "  }catch(e){}"
    "}"
    "function scanDOM(){"
    "  try{"
    "    var els = document.querySelectorAll('video,audio,source');"
    "    for(var i=0;i<els.length;i++){"
    "      var el = els[i];"
    "      var s = el.currentSrc || el.src || el.getAttribute('src');"
    "      if(s) report(s, el.tagName==='AUDIO' ? 'AUDIO' : 'VIDEO');"
    "    }"
    "  }catch(e){}"
    "}"
    "var origOpen = XMLHttpRequest.prototype.open;"
    "XMLHttpRequest.prototype.open = function(method, url){"
    "  if(typeof url === 'string' && rx.test(url)) report(url, null);"
    "  return origOpen.apply(this, arguments);"
    "};"
    "if(window.fetch){"
    "  var origFetch = window.fetch;"
    "  window.fetch = function(input){"
    "    try{ var u = (typeof input === 'string') ? input : (input && input.url); if(u && rx.test(u)) report(u, null); }catch(e){}"
    "    return origFetch.apply(this, arguments);"
    "  };"
    "}"
    "if(window.HTMLMediaElement && HTMLMediaElement.prototype.load){"
    "  var origLoad = HTMLMediaElement.prototype.load;"
    "  HTMLMediaElement.prototype.load = function(){"
    "    try{ report(this.currentSrc || this.src, this.tagName==='AUDIO'?'AUDIO':'VIDEO'); }catch(e){}"
    "    return origLoad.apply(this, arguments);"
    "  };"
    "}"
    "document.addEventListener('DOMContentLoaded', scanDOM, {passive:true});"
    "window.addEventListener('load', scanDOM, {passive:true});"
    "document.addEventListener('play', function(ev){"
    "  var t = ev.target; if(t && (t.currentSrc || t.src)) report(t.currentSrc || t.src, t.tagName==='AUDIO'?'AUDIO':'VIDEO');"
    "}, true);"
    "})();";
}

static BOOL wq_url_has_downloadable_ext(NSURL *url)
{
    NSString *ext = url.pathExtension.lowercaseString;
    if (!ext.length) return NO;
    static NSSet<NSString *> *dlExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlExts = [NSSet setWithArray:@[
            @"zip", @"rar", @"7z", @"tar", @"gz", @"bz2", @"xz", @"wqenc",
            @"ipa", @"deb", @"dmg", @"pkg", @"apk",
            @"mp4", @"m4v", @"mov", @"mkv", @"webm", @"avi", @"ts", @"m3u8",
            @"mp3", @"m4a", @"aac", @"flac", @"wav", @"ogg",
            @"epub", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx",
        ]];
    });
    return [dlExts containsObject:ext];
}

static NSDictionary<NSString *, NSString *> *wq_headers_for_sniffed(WQSniffedMedia *m)
{
    NSMutableDictionary<NSString *, NSString *> *h = [NSMutableDictionary new];
    if (m.referer.length) h[@"Referer"] = m.referer;
    if (m.cookie.length) h[@"Cookie"] = m.cookie;
    if (m.userAgent.length) h[@"User-Agent"] = m.userAgent;
    return h;
}

#pragma mark - 1DM/IDM Media Grabber & Quality Picker Sheet

@interface WQMediaGrabberSheetViewController : UITableViewController
- (instancetype)initWithMedia:(NSArray<WQSniffedMedia *> *)media onClear:(void (^)(void))onClear;
@end

@implementation WQMediaGrabberSheetViewController {
    NSArray<WQSniffedMedia *> *_media;
    void (^_onClear)(void);
}

- (instancetype)initWithMedia:(NSArray<WQSniffedMedia *> *)media onClear:(void (^)(void))onClear
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _media = [media copy];
        _onClear = [onClear copy];
        self.title = WQLocalizedFormat(@"Detected Media (%lu)", (unsigned long)_media.count);
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
    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    if (_media.count) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Clear") image:nil identifier:nil handler:^(UIAction *__unused a) {
            if (weakSelf) {
                if (weakSelf->_onClear) weakSelf->_onClear();
                weakSelf->_media = @[];
                [weakSelf.tableView reloadData];
            }
        }]];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }
- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_media.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger __unused)section
{
    return WQLocalized(@"Tap an HLS (.m3u8) stream to open the Quality Picker (1080p / 720p / 480p / Audio Only). Tap direct videos or audio to download with captured page cookies & headers.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"grab-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"grab-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_media.count) {
        c.text = WQLocalized(@"No Playable Media Detected Yet");
        c.secondaryText = WQLocalized(@"Start playing a video or audio clip on the webpage and WQ Glass will sniff the stream automatically.");
        c.secondaryTextProperties.numberOfLines = 3;
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQSniffedMedia *m = _media[(NSUInteger)indexPath.row];
    NSString *tag = m.isHLS ? @"HLS · Quality Picker" : m.kind;
    NSString *fname = [NSURL URLWithString:m.urlString].lastPathComponent;
    if (!fname.length || [fname isEqualToString:@"/"]) fname = m.title.length ? m.title : @"media";
    c.text = [NSString stringWithFormat:@"[%@] %@", tag, fname];
    c.secondaryText = m.urlString;
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:m.isHLS ? @"sparkles.tv.fill" : ([m.kind isEqualToString:@"MP3"] || [m.kind isEqualToString:@"M4A"] || [m.kind isEqualToString:@"AUDIO"] ? @"music.note" : @"film.fill")];
    c.imageProperties.tintColor = m.isHLS ? wq_theme_aurora_teal() : wq_theme_accent();
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_media.count) return;
    wq_haptic_selection();
    WQSniffedMedia *m = _media[(NSUInteger)indexPath.row];
    NSDictionary<NSString *, NSString *> *hdrs = wq_headers_for_sniffed(m);
    NSString *suggested = m.title.length ? m.title : [NSURL URLWithString:m.urlString].lastPathComponent;
    if (m.isHLS) {
        wq_present_hls_quality_picker(self, m.urlString, suggested, hdrs);
    } else {
        NSString *ext = [NSURL URLWithString:m.urlString].pathExtension;
        if (ext.length && ![suggested.lowercaseString hasSuffix:[@"." stringByAppendingString:ext.lowercaseString]]) {
            suggested = [suggested stringByAppendingPathExtension:ext];
        }
        wq_present_add_download_sheet(self, m.urlString, suggested, -1, hdrs, NO, m.kind);
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_media.count) return nil;
    WQSniffedMedia *m = _media[(NSUInteger)indexPath.row];
    UIContextualAction *copyAct = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                          title:WQLocalized(@"Copy URL")
                                                                        handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        UIPasteboard.generalPasteboard.string = m.urlString;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        done(YES);
    }];
    copyAct.backgroundColor = wq_theme_accent();
    return [UISwipeActionsConfiguration configurationWithActions:@[copyAct]];
}

@end

#pragma mark - Page Resource Grabber ("Grab All Links & Media")

@interface WQPageGrabberViewController : UITableViewController
- (instancetype)initWithResources:(NSArray<NSDictionary<NSString *, NSString *> *> *)items
                          headers:(NSDictionary<NSString *, NSString *> *)headers;
@end

@implementation WQPageGrabberViewController {
    NSArray<NSDictionary<NSString *, NSString *> *> *_all;
    NSArray<NSDictionary<NSString *, NSString *> *> *_filtered;
    NSMutableSet<NSString *> *_selectedURLs;
    NSDictionary<NSString *, NSString *> *_headers;
    UISegmentedControl *_seg;
}

- (instancetype)initWithResources:(NSArray<NSDictionary<NSString *, NSString *> *> *)items
                          headers:(NSDictionary<NSString *, NSString *> *)headers
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _all = [items copy];
        _headers = [headers copy] ?: @{};
        _selectedURLs = [NSMutableSet new];
        self.title = WQLocalized(@"Page Resource Grabber");
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
    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self updateDownloadButton];

    CGFloat w = self.tableView.bounds.size.width ?: 360.0;
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    hdr.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _seg = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Videos", @"Audio", @"Images", @"Files"]];
    _seg.translatesAutoresizingMaskIntoConstraints = NO;
    _seg.selectedSegmentIndex = 0;
    [_seg addTarget:self action:@selector(applyFilter) forControlEvents:UIControlEventValueChanged];
    [hdr addSubview:_seg];
    [NSLayoutConstraint activateConstraints:@[
        [_seg.topAnchor constraintEqualToAnchor:hdr.topAnchor constant:8],
        [_seg.bottomAnchor constraintEqualToAnchor:hdr.bottomAnchor constant:-8],
        [_seg.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor constant:12],
        [_seg.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor constant:-12],
    ]];
    self.tableView.tableHeaderView = hdr;
    [self applyFilter];
}

- (void)updateDownloadButton
{
    __weak typeof(self) weakSelf = self;
    NSString *title = _selectedURLs.count
        ? WQLocalizedFormat(@"Download (%lu)", (unsigned long)_selectedURLs.count)
        : WQLocalized(@"Select All");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *__unused a) {
        WQPageGrabberViewController *me = weakSelf;
        if (!me) return;
        if (!me->_selectedURLs.count) {
            for (NSDictionary *d in me->_filtered) {
                NSString *u = d[@"url"];
                if (u.length) [me->_selectedURLs addObject:u];
            }
            [me updateDownloadButton];
            [me.tableView reloadData];
            return;
        }
        NSArray<NSString *> *urls = me->_selectedURLs.allObjects;
        NSDictionary *hdrs = me->_headers;
        [me dismissViewControllerAnimated:YES completion:^{
            for (NSString *u in urls) {
                [WQDownloadManager.sharedManager enqueueURLString:u
                                                suggestedFilename:nil
                                                   destinationDir:nil
                                                          headers:hdrs
                                                        partCount:WQDownloadManager.sharedManager.defaultPartCount
                                                            isHLS:[u.lowercaseString containsString:@".m3u8"]
                                                     qualityLabel:nil
                                                         startNow:YES];
            }
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        }];
    }]];
}

- (void)applyFilter
{
    NSInteger idx = _seg ? _seg.selectedSegmentIndex : 0;
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *d in _all) {
        NSString *cat = d[@"cat"] ?: @"Other";
        if (idx == 0) [out addObject:d];
        else if (idx == 1 && [cat isEqualToString:@"Videos"]) [out addObject:d];
        else if (idx == 2 && [cat isEqualToString:@"Audio"]) [out addObject:d];
        else if (idx == 3 && [cat isEqualToString:@"Images"]) [out addObject:d];
        else if (idx == 4 && ([cat isEqualToString:@"Archives"] || [cat isEqualToString:@"Documents"] || [cat isEqualToString:@"Apps"])) [out addObject:d];
    }
    _filtered = out;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }
- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_filtered.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pg-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pg-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_filtered.count) {
        c.text = WQLocalized(@"No matching resources on this page");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSDictionary *d = _filtered[(NSUInteger)indexPath.row];
    NSString *u = d[@"url"] ?: @"";
    c.text = d[@"name"] ?: u.lastPathComponent;
    c.secondaryText = [NSString stringWithFormat:@"[%@] %@", d[@"cat"] ?: @"File", u];
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.contentConfiguration = c;
    cell.accessoryType = [_selectedURLs containsObject:u] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_filtered.count) return;
    wq_haptic_selection();
    NSString *u = _filtered[(NSUInteger)indexPath.row][@"url"];
    if (!u.length) return;
    if ([_selectedURLs containsObject:u]) [_selectedURLs removeObject:u];
    else [_selectedURLs addObject:u];
    [self updateDownloadButton];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - WQDownloadBrowserViewController

@interface WQDownloadBrowserViewController () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UITextFieldDelegate>
@end

@implementation WQDownloadBrowserViewController {
    NSString *_initialURL;
    NSMutableArray<WQBrowserTab *> *_tabs;
    NSInteger _activeIndex;
    BOOL _adBlockEnabled;
    WKContentRuleList *_adBlockList;

    UIView *_webContainer;
    UITextField *_urlField;
    UIProgressView *_progressView;
    UIButton *_backBtn;
    UIButton *_fwdBtn;
    UIButton *_mediaBtn;
    UIButton *_tabsBtn;
    UIButton *_dlBtn;
    UIButton *_menuBtn;
}

- (instancetype)initWithInitialURL:(NSString *)urlString
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _initialURL = [urlString copy];
        _tabs = [NSMutableArray new];
        _activeIndex = 0;
        id pref = [NSUserDefaults.standardUserDefaults objectForKey:kWQBrowserAdBlockPref];
        _adBlockEnabled = pref ? [pref boolValue] : YES;
        self.title = WQLocalized(@"IDM Browser");
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)dealloc
{
    for (WQBrowserTab *t in _tabs) {
        @try {
            [t.webView removeObserver:self forKeyPath:@"estimatedProgress"];
            [t.webView removeObserver:self forKeyPath:@"title"];
        } @catch (NSException *__unused e) {}
        [t.webView.configuration.userContentController removeScriptMessageHandlerForName:@"wqMediaSniff"];
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = wq_theme_canvas_top();
    [self buildChrome];
    [self compileAdBlockerAndOpenFirstTab];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateDownloadsBadge) name:WQDownloadManagerDidUpdateNotification object:nil];
    [self updateDownloadsBadge];
}

- (void)buildChrome
{
    // Top glass URL bar
    UIVisualEffectView *topBar = wq_theme_make_glass_card(16.0, YES);
    topBar.translatesAutoresizingMaskIntoConstraints = NO;

    _urlField = [UITextField new];
    _urlField.translatesAutoresizingMaskIntoConstraints = NO;
    _urlField.placeholder = WQLocalized(@"Search or enter website URL…");
    _urlField.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _urlField.textColor = wq_theme_primary_text();
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.keyboardType = UIKeyboardTypeWebSearch;
    _urlField.returnKeyType = UIReturnKeyGo;
    _urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _urlField.delegate = self;

    UIButton *reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [reloadBtn setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    reloadBtn.tintColor = wq_theme_accent();
    [reloadBtn addTarget:self action:@selector(reloadTapped) forControlEvents:UIControlEventTouchUpInside];

    [topBar.contentView addSubview:_urlField];
    [topBar.contentView addSubview:reloadBtn];
    [NSLayoutConstraint activateConstraints:@[
        [_urlField.leadingAnchor constraintEqualToAnchor:topBar.contentView.leadingAnchor constant:12],
        [_urlField.topAnchor constraintEqualToAnchor:topBar.contentView.topAnchor constant:6],
        [_urlField.bottomAnchor constraintEqualToAnchor:topBar.contentView.bottomAnchor constant:-6],
        [reloadBtn.leadingAnchor constraintEqualToAnchor:_urlField.trailingAnchor constant:6],
        [reloadBtn.trailingAnchor constraintEqualToAnchor:topBar.contentView.trailingAnchor constant:-8],
        [reloadBtn.centerYAnchor constraintEqualToAnchor:topBar.contentView.centerYAnchor],
        [reloadBtn.widthAnchor constraintEqualToConstant:30],
    ]];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.progressTintColor = wq_theme_aurora_teal();
    _progressView.trackTintColor = UIColor.clearColor;
    _progressView.hidden = YES;

    _webContainer = [UIView new];
    _webContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _webContainer.backgroundColor = wq_theme_canvas_top();

    // Bottom glass 1DM/IDM toolbar
    UIVisualEffectView *botBar = wq_theme_make_glass_card(20.0, YES);
    botBar.translatesAutoresizingMaskIntoConstraints = NO;

    _backBtn = [self makeBarBtn:@"chevron.backward" action:@selector(goBackTapped)];
    _fwdBtn = [self makeBarBtn:@"chevron.forward" action:@selector(goFwdTapped)];
    _mediaBtn = [self makeBarBtn:@"arrow.down.circle.fill" action:@selector(openMediaGrabber)];
    [_mediaBtn setTitle:@" 0" forState:UIControlStateNormal];
    _mediaBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightBold];
    _tabsBtn = [self makeBarBtn:@"square.on.square" action:@selector(openTabsSheet)];
    [_tabsBtn setTitle:@" 1" forState:UIControlStateNormal];
    _tabsBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    _dlBtn = [self makeBarBtn:@"tray.and.arrow.down.fill" action:@selector(openDownloadManager)];
    _dlBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    _menuBtn = [self makeBarBtn:@"ellipsis.circle" action:@selector(openBrowserMenu)];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_backBtn, _fwdBtn, _mediaBtn, _tabsBtn, _dlBtn, _menuBtn]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    [botBar.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:botBar.contentView.topAnchor constant:4],
        [row.bottomAnchor constraintEqualToAnchor:botBar.contentView.bottomAnchor constant:-4],
        [row.leadingAnchor constraintEqualToAnchor:botBar.contentView.leadingAnchor constant:6],
        [row.trailingAnchor constraintEqualToAnchor:botBar.contentView.trailingAnchor constant:-6],
    ]];

    [self.view addSubview:topBar];
    [self.view addSubview:_progressView];
    [self.view addSubview:_webContainer];
    [self.view addSubview:botBar];

    [NSLayoutConstraint activateConstraints:@[
        [topBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [topBar.heightAnchor constraintEqualToConstant:40],

        [_progressView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:2],
        [_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_progressView.heightAnchor constraintEqualToConstant:2],

        [_webContainer.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor],
        [_webContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_webContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_webContainer.bottomAnchor constraintEqualToAnchor:botBar.topAnchor constant:-6],

        [botBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [botBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [botBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-4],
        [botBar.heightAnchor constraintEqualToConstant:46],
    ]];
}

- (UIButton *)makeBarBtn:(NSString *)sym action:(SEL)sel
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sym] forState:UIControlStateNormal];
    b.tintColor = wq_theme_primary_text();
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)compileAdBlockerAndOpenFirstTab
{
    __weak typeof(self) weakSelf = self;
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"wqglass_adblock_v1"
                                                      encodedContentRuleList:wq_browser_adblock_rules_json()
                                                           completionHandler:^(WKContentRuleList *list, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        me->_adBlockList = list;
        [me openNewTabWithURL:(me->_initialURL.length ? me->_initialURL : kWQBrowserHomepage) incognito:NO];
    }];
}

- (WQBrowserTab *)activeTab
{
    if (_activeIndex >= 0 && (NSUInteger)_activeIndex < _tabs.count) {
        return _tabs[(NSUInteger)_activeIndex];
    }
    return nil;
}

- (void)openNewTabWithURL:(NSString *)urlStr incognito:(BOOL)incognito
{
    if (_tabs.count >= 6) {
        wq_alert(self, WQLocalized(@"Tab Limit Reached"), WQLocalized(@"Close one of your 6 browser tabs before opening another."));
        return;
    }
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.websiteDataStore = incognito ? [WKWebsiteDataStore nonPersistentDataStore] : [WKWebsiteDataStore defaultDataStore];

    WKUserContentController *ucc = [WKUserContentController new];
    WKUserScript *sniffScript = [[WKUserScript alloc] initWithSource:wq_browser_media_sniffer_js()
                                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                    forMainFrameOnly:NO];
    [ucc addUserScript:sniffScript];
    WQWeakScriptMessageHandler *proxy = [WQWeakScriptMessageHandler new];
    proxy.target = self;
    [ucc addScriptMessageHandler:proxy name:@"wqMediaSniff"];
    if (_adBlockEnabled && _adBlockList) {
        [ucc addContentRuleList:_adBlockList];
    }
    cfg.userContentController = ucc;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:_webContainer.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.navigationDelegate = self;
    wv.UIDelegate = self;
    wv.allowsBackForwardNavigationGestures = YES;
    [wv addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:NULL];
    [wv addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:NULL];

    WQBrowserTab *tab = [WQBrowserTab new];
    tab.webView = wv;
    tab.incognito = incognito;
    [_tabs addObject:tab];
    [self switchToTabIndex:(NSInteger)_tabs.count - 1];

    if (urlStr.length) {
        [self loadUserInput:urlStr];
    }
}

- (void)switchToTabIndex:(NSInteger)index
{
    if (index < 0 || (NSUInteger)index >= _tabs.count) return;
    _activeIndex = index;
    for (UIView *sub in _webContainer.subviews) [sub removeFromSuperview];
    WQBrowserTab *tab = self.activeTab;
    tab.webView.frame = _webContainer.bounds;
    [_webContainer addSubview:tab.webView];
    _urlField.text = tab.webView.URL.absoluteString ?: @"";
    self.title = tab.incognito ? WQLocalized(@"Private IDM Browser") : WQLocalized(@"IDM Browser");
    [self updateToolbarState];
}

- (void)loadUserInput:(NSString *)raw
{
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    NSURL *url = nil;
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) {
        url = [NSURL URLWithString:trimmed];
    } else if ([trimmed containsString:@"."] && ![trimmed containsString:@" "]) {
        url = [NSURL URLWithString:[@"https://" stringByAppendingString:trimmed]];
    } else {
        NSString *q = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
        url = [NSURL URLWithString:[@"https://duckduckgo.com/?q=" stringByAppendingString:q]];
    }
    if (url) {
        [self.activeTab.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)updateToolbarState
{
    WQBrowserTab *tab = self.activeTab;
    _backBtn.enabled = tab.webView.canGoBack;
    _fwdBtn.enabled = tab.webView.canGoForward;
    NSUInteger mCount = tab.media.count;
    [_mediaBtn setTitle:[NSString stringWithFormat:@" %lu", (unsigned long)mCount] forState:UIControlStateNormal];
    _mediaBtn.tintColor = mCount > 0 ? wq_theme_aurora_teal() : wq_theme_secondary_text();
    [_tabsBtn setTitle:[NSString stringWithFormat:@" %lu", (unsigned long)_tabs.count] forState:UIControlStateNormal];
}

- (void)updateDownloadsBadge
{
    NSUInteger active = WQDownloadManager.sharedManager.activeCount;
    [_dlBtn setTitle:(active > 0 ? [NSString stringWithFormat:@" %lu", (unsigned long)active] : @"") forState:UIControlStateNormal];
    _dlBtn.tintColor = active > 0 ? wq_theme_accent() : wq_theme_primary_text();
}

#pragma mark KVO & TextField

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *__unused)change context:(void *__unused)context
{
    WQBrowserTab *tab = self.activeTab;
    if (!tab || object != tab.webView) return;
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        float p = (float)tab.webView.estimatedProgress;
        _progressView.hidden = (p >= 1.0f);
        [_progressView setProgress:p animated:YES];
    } else if ([keyPath isEqualToString:@"title"]) {
        if (tab.webView.title.length) tab.pageTitle = tab.webView.title;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    [self loadUserInput:textField.text ?: @""];
    return YES;
}

#pragma mark Toolbar Actions

- (void)goBackTapped { [self.activeTab.webView goBack]; }
- (void)goFwdTapped { [self.activeTab.webView goForward]; }
- (void)reloadTapped
{
    if (self.activeTab.webView.isLoading) [self.activeTab.webView stopLoading];
    else [self.activeTab.webView reload];
}

- (void)openDownloadManager
{
    wq_haptic_selection();
    [self.navigationController pushViewController:[WQDownloadManagerViewController new] animated:YES];
}

- (void)openMediaGrabber
{
    wq_haptic_selection();
    WQBrowserTab *tab = self.activeTab;
    if (!tab) return;
    __weak typeof(self) weakSelf = self;
    WQMediaGrabberSheetViewController *vc = [[WQMediaGrabberSheetViewController alloc] initWithMedia:tab.media onClear:^{
        [tab.media removeAllObjects];
        [tab.seenURLs removeAllObjects];
        [weakSelf updateToolbarState];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openTabsSheet
{
    wq_haptic_selection();
    UIAlertController *sheet = wq_alert_controller(WQLocalizedFormat(@"Browser Tabs (%lu / 6)", (unsigned long)_tabs.count), nil, UIAlertControllerStyleActionSheet);
    for (NSUInteger i = 0; i < _tabs.count; i++) {
        WQBrowserTab *t = _tabs[i];
        NSString *prefix = (NSInteger)i == _activeIndex ? @"● " : @"";
        NSString *priv = t.incognito ? @"[Private] " : @"";
        NSString *label = [NSString stringWithFormat:@"%@%@%@", prefix, priv, t.pageTitle.length ? t.pageTitle : @"Tab"];
        [sheet addAction:wq_alert_action(WQVerbatim(label), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self switchToTabIndex:(NSInteger)i];
        })];
    }
    if (_tabs.count < 6) {
        [sheet addAction:wq_alert_action(WQLocalized(@"+ New Tab"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self openNewTabWithURL:kWQBrowserHomepage incognito:NO];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"+ New Private / Incognito Tab"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self openNewTabWithURL:kWQBrowserHomepage incognito:YES];
        })];
    }
    if (_tabs.count > 1) {
        [sheet addAction:wq_alert_action(WQLocalized(@"Close Current Tab"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            WQBrowserTab *cur = self.activeTab;
            if (!cur) return;
            @try {
                [cur.webView removeObserver:self forKeyPath:@"estimatedProgress"];
                [cur.webView removeObserver:self forKeyPath:@"title"];
            } @catch (NSException *__unused e) {}
            [cur.webView.configuration.userContentController removeScriptMessageHandlerForName:@"wqMediaSniff"];
            [self->_tabs removeObjectAtIndex:(NSUInteger)self->_activeIndex];
            [self switchToTabIndex:MAX(0, self->_activeIndex - 1)];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _tabsBtn;
    sheet.popoverPresentationController.sourceRect = _tabsBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openBrowserMenu
{
    wq_haptic_selection();
    WQBrowserTab *tab = self.activeTab;
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"1DM / IDM Browser Tools"), nil, UIAlertControllerStyleActionSheet);

    [sheet addAction:wq_alert_action(WQLocalized(@"Grab All Links & Media on Page…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self grabAllResourcesOnPage];
    })];
    [sheet addAction:wq_alert_action(_adBlockEnabled ? WQLocalized(@"Ad & Popup Blocker: ON") : WQLocalized(@"Ad & Popup Blocker: OFF"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_adBlockEnabled = !self->_adBlockEnabled;
        [NSUserDefaults.standardUserDefaults setBool:self->_adBlockEnabled forKey:kWQBrowserAdBlockPref];
        if (tab) {
            [tab.webView.configuration.userContentController removeAllContentRuleLists];
            if (self->_adBlockEnabled && self->_adBlockList) {
                [tab.webView.configuration.userContentController addContentRuleList:self->_adBlockList];
            }
            [tab.webView reload];
        }
    })];
    [sheet addAction:wq_alert_action(tab.desktopMode ? WQLocalized(@"Switch to Mobile Site") : WQLocalized(@"Request Desktop Site"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        if (!tab) return;
        tab.desktopMode = !tab.desktopMode;
        tab.webView.customUserAgent = tab.desktopMode ? kWQDesktopUA : nil;
        [tab.webView reload];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Save Webpage as PDF"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self saveCurrentPageAsPDF];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Bookmarks…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showBookmarksSheet];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Add Current Page to Bookmarks"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *u = tab.webView.URL.absoluteString;
        if (!u.length) return;
        NSMutableArray *bms = [[NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserBookmarksPref] mutableCopy] ?: [NSMutableArray new];
        [bms insertObject:@{ @"title": tab.pageTitle ?: u, @"url": u } atIndex:0];
        [NSUserDefaults.standardUserDefaults setObject:bms forKey:kWQBrowserBookmarksPref];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Clear Cookies & Browsing Data"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        NSSet<NSString *> *allTypes = [WKWebsiteDataStore allWebsiteDataTypes];
        [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:allTypes modifiedSince:NSDate.distantPast completionHandler:^{
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Cleared"), WQLocalized(@"Cookies, cache & local storage cleared."));
        }];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _menuBtn;
    sheet.popoverPresentationController.sourceRect = _menuBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showBookmarksSheet
{
    NSArray *bms = [NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserBookmarksPref];
    if (!bms.count) {
        bms = @[
            @{ @"title": @"DuckDuckGo", @"url": @"https://duckduckgo.com" },
            @{ @"title": @"GitHub", @"url": @"https://github.com" },
            @{ @"title": @"Internet Archive", @"url": @"https://archive.org" },
        ];
    }
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Bookmarks"), nil, UIAlertControllerStyleActionSheet);
    for (NSDictionary *bm in bms) {
        if (![bm isKindOfClass:NSDictionary.class]) continue;
        NSString *t = bm[@"title"] ?: bm[@"url"] ?: @"Bookmark";
        NSString *u = bm[@"url"] ?: @"";
        [sheet addAction:wq_alert_action(WQVerbatim(t), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self loadUserInput:u];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _menuBtn;
    sheet.popoverPresentationController.sourceRect = _menuBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveCurrentPageAsPDF
{
    WKWebView *wv = self.activeTab.webView;
    if (!wv) return;
    WKPDFConfiguration *cfg = [WKPDFConfiguration new];
    __weak typeof(self) weakSelf = self;
    [wv createPDFWithConfiguration:cfg completionHandler:^(NSData *pdfData, NSError *err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        if (err || !pdfData.length) {
            wq_alert(me, WQLocalized(@"PDF Failed"), err.localizedDescription ?: WQLocalized(@"Could not render page as PDF."));
            return;
        }
        NSString *dir = [wq_downloads_root_dir() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stem = me.activeTab.pageTitle.length ? me.activeTab.pageTitle : @"Webpage";
        NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
        stem = [[stem componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
        NSString *outPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%ld.pdf", stem, (long)NSDate.date.timeIntervalSince1970]];
        if ([pdfData writeToFile:outPath atomically:YES]) {
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
            share.popoverPresentationController.sourceView = me.view;
            [me presentViewController:share animated:YES completion:nil];
        }
    }];
}

- (void)grabAllResourcesOnPage
{
    WKWebView *wv = self.activeTab.webView;
    if (!wv) return;
    NSString *js = @"(function(){"
        "var seen={}, out=[];"
        "function add(raw){"
        "  try{"
        "    if(!raw || raw.indexOf('data:')===0 || raw.indexOf('blob:')===0 || raw.indexOf('javascript:')===0) return;"
        "    var u = new URL(raw, location.href).href;"
        "    if(seen[u] || out.length>=200) return;"
        "    if(!/\\.(m3u8|mp4|m4v|mov|webm|mp3|m4a|aac|flac|wav|ogg|jpg|jpeg|png|webp|gif|svg|pdf|zip|rar|7z|tar|gz|ipa|deb|dmg|epub|docx|xlsx|pptx)(\\?|#|$)/i.test(u)) return;"
        "    seen[u]=1; out.push(u);"
        "  }catch(e){}"
        "}"
        "document.querySelectorAll('a[href]').forEach(function(e){add(e.getAttribute('href'));});"
        "document.querySelectorAll('video,audio,source,img').forEach(function(e){add(e.currentSrc||e.src||e.getAttribute('src'));});"
        "return { urls: out, ref: location.href, cookie: document.cookie||'', ua: navigator.userAgent||'' };"
    "})();";

    __weak typeof(self) weakSelf = self;
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me || ![result isKindOfClass:NSDictionary.class]) return;
        NSArray *urls = result[@"urls"];
        if (![urls isKindOfClass:NSArray.class] || !urls.count) {
            wq_alert(me, WQLocalized(@"No Resources Found"), WQLocalized(@"No downloadable files, videos, audio, or images were found on this page."));
            return;
        }
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray new];
        for (id obj in urls) {
            if (![obj isKindOfClass:NSString.class]) continue;
            NSString *u = (NSString *)obj;
            NSString *name = [NSURL URLWithString:u].lastPathComponent ?: @"file";
            NSString *cat = wq_download_category_for_filename(name);
            [items addObject:@{ @"url": u, @"name": name, @"cat": cat }];
        }
        NSMutableDictionary<NSString *, NSString *> *hdrs = [NSMutableDictionary new];
        if ([result[@"ref"] isKindOfClass:NSString.class] && [result[@"ref"] length]) hdrs[@"Referer"] = result[@"ref"];
        if ([result[@"cookie"] isKindOfClass:NSString.class] && [result[@"cookie"] length]) hdrs[@"Cookie"] = result[@"cookie"];
        if ([result[@"ua"] isKindOfClass:NSString.class] && [result[@"ua"] length]) hdrs[@"User-Agent"] = result[@"ua"];

        WQPageGrabberViewController *vc = [[WQPageGrabberViewController alloc] initWithResources:items headers:hdrs];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [me presentViewController:nav animated:YES completion:nil];
    }];
}

#pragma mark WKScriptMessageHandler (Live Sniffed Media)

- (void)userContentController:(WKUserContentController *__unused)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:@"wqMediaSniff"] || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *d = (NSDictionary *)message.body;
    NSString *u = [d[@"url"] isKindOfClass:NSString.class] ? d[@"url"] : nil;
    if (!u.length) return;
    WQBrowserTab *tab = nil;
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == message.webView) { tab = t; break; }
    }
    if (!tab || [tab.seenURLs containsObject:u]) return;
    [tab.seenURLs addObject:u];

    WQSniffedMedia *m = [WQSniffedMedia new];
    m.urlString = u;
    m.kind = [d[@"kind"] isKindOfClass:NSString.class] ? d[@"kind"] : @"MEDIA";
    m.title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"";
    m.referer = [d[@"referer"] isKindOfClass:NSString.class] ? d[@"referer"] : nil;
    m.cookie = [d[@"cookie"] isKindOfClass:NSString.class] ? d[@"cookie"] : nil;
    m.userAgent = [d[@"ua"] isKindOfClass:NSString.class] ? d[@"ua"] : nil;
    m.isHLS = [u.lowercaseString containsString:@".m3u8"] || [m.kind.uppercaseString isEqualToString:@"M3U8"];
    [tab.media insertObject:m atIndex:0];
    if (tab == self.activeTab) {
        [self updateToolbarState];
    }
}

#pragma mark WKNavigationDelegate & WKUIDelegate (Download Interception + Popup Blocker)

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *__unused)navigation
{
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == webView) {
            [t.media removeAllObjects];
            [t.seenURLs removeAllObjects];
            break;
        }
    }
    if (webView == self.activeTab.webView) {
        _urlField.text = webView.URL.absoluteString ?: _urlField.text;
        [self updateToolbarState];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *__unused)navigation
{
    if (webView == self.activeTab.webView) {
        _urlField.text = webView.URL.absoluteString ?: @"";
        [self updateToolbarState];
    }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && url && wq_url_has_downloadable_ext(url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        NSString *ref = webView.URL.absoluteString;
        NSDictionary *hdrs = ref.length ? @{ @"Referer": ref } : nil;
        if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
            wq_present_hls_quality_picker(self, url.absoluteString, url.lastPathComponent, hdrs);
        } else {
            wq_present_add_download_sheet(self, url.absoluteString, url.lastPathComponent, -1, hdrs, NO, nil);
        }
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    NSURLResponse *resp = navigationResponse.response;
    NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
    BOOL isAttachment = NO;
    if (http) {
        for (NSString *k in http.allHeaderFields) {
            if ([k.lowercaseString isEqualToString:@"content-disposition"]) {
                NSString *v = [NSString stringWithFormat:@"%@", http.allHeaderFields[k]];
                if ([v.lowercaseString containsString:@"attachment"]) isAttachment = YES;
            }
        }
    }
    if (!navigationResponse.canShowMIMEType || isAttachment) {
        decisionHandler(WKNavigationResponsePolicyCancel);
        NSURL *u = resp.URL;
        if (!u) return;
        NSString *ref = webView.URL.absoluteString;
        int64_t expectedLen = resp.expectedContentLength;
        NSString *suggested = resp.suggestedFilename ?: u.lastPathComponent;
        [webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
            NSMutableArray<NSString *> *pairs = [NSMutableArray new];
            for (NSHTTPCookie *c in cookies) {
                if (u.host.length && [u.host.lowercaseString hasSuffix:c.domain.lowercaseString]) {
                    [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
                }
            }
            NSMutableDictionary<NSString *, NSString *> *hdrs = [NSMutableDictionary new];
            if (ref.length) hdrs[@"Referer"] = ref;
            if (pairs.count) hdrs[@"Cookie"] = [pairs componentsJoinedByString:@"; "];
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_present_add_download_sheet(self, u.absoluteString, suggested, expectedLen, hdrs, NO, nil);
            });
        }];
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *__unused)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *__unused)windowFeatures
{
    // Block ad popups when Ad Blocker is active; otherwise open target=_blank cleanly in current tab.
    if (!navigationAction.targetFrame.isMainFrame && navigationAction.request.URL) {
        if (_adBlockEnabled && navigationAction.navigationType != WKNavigationTypeLinkActivated) {
            return nil;
        }
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

@end
