//
//  WQDownloadBrowser.m
//  WQ Glass Brave-Inspired Privacy Browser, Shields, Ad/Popup Blocker & Pro Media Sniffer
//  GPL-3.0-or-later.
//

#import "WQDownloadBrowser.h"
#import "WQDownloadManager.h"
#import "WQProMediaPlayer.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <WebKit/WebKit.h>

#pragma mark - Preferences & Constants

static NSString *const kWQBrowserBookmarksPref          = @"WQBrowserBookmarks";
static NSString *const kWQBrowserReadingListPref        = @"WQBrowserReadingList";
static NSString *const kWQBrowserHistoryPref            = @"WQBrowserHistoryLog";
static NSString *const kWQBrowserTopSitesPref           = @"WQBrowserTopSites";

static NSString *const kWQBrowserSearchEnginePref       = @"WQBrowserSearchEngineID";
static NSString *const kWQBrowserCustomSearchPref       = @"WQBrowserCustomSearchURL";

static NSString *const kWQBrowserAdBlockPref            = @"WQBrowserAdBlockEnabled";
static NSString *const kWQBrowserShieldsLevelPref       = @"WQBrowserShieldsLevel";        // 0=Off, 1=Standard, 2=Aggressive
static NSString *const kWQBrowserShieldDisabledHostsPref= @"WQBrowserShieldsDisabledHosts";
static NSString *const kWQBrowserShieldBlockAdsPref     = @"WQBrowserShieldBlockAds";
static NSString *const kWQBrowserShieldBlockPopupsPref  = @"WQBrowserShieldBlockPopups";
static NSString *const kWQBrowserShieldHTTPSUpgradePref = @"WQBrowserShieldHTTPSUpgrade";
static NSString *const kWQBrowserShieldCookieHidePref   = @"WQBrowserShieldCookieHide";
static NSString *const kWQBrowserShieldScriptHostsPref  = @"WQBrowserShieldBlockScriptsHosts";

static NSString *const kWQBrowserWebDarkModePref        = @"WQBrowserWebDarkMode";
static NSString *const kWQBrowserDesktopDefaultPref     = @"WQBrowserDesktopDefault";
static NSString *const kWQBrowserClearOnExitPref        = @"WQBrowserClearDataOnExit";

static NSString *const kWQBrowserStatsAdsPref           = @"WQBrowserTotalAdsBlocked";
static NSString *const kWQBrowserStatsPopupsPref        = @"WQBrowserTotalPopupsBlocked";
static NSString *const kWQBrowserStatsTrackersPref      = @"WQBrowserTotalTrackersStripped";
static NSString *const kWQBrowserStatsBytesPref         = @"WQBrowserEstimatedBytesSaved";

static NSString *const kWQDesktopUA = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
static NSInteger const kWQMaxBrowserTabs = 24;
static NSInteger const kWQMaxActiveWebViews = 6;
static NSUInteger const kWQMaxHistoryEntries = 500;

#pragma mark - Search Engine Registry

@interface WQBrowserSearchEngineInfo : NSObject
@property (nonatomic, copy) NSString *engineID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *searchTemplate; // uses %@ or %s
@property (nonatomic, copy) NSString *homeURL;
@property (nonatomic, copy) NSString *symbolName;
@end

@implementation WQBrowserSearchEngineInfo
@end

static NSArray<WQBrowserSearchEngineInfo *> *wq_browser_search_engines(void)
{
    static NSArray<WQBrowserSearchEngineInfo *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WQBrowserSearchEngineInfo *(^mk)(NSString *, NSString *, NSString *, NSString *, NSString *) =
            ^WQBrowserSearchEngineInfo *(NSString *eid, NSString *name, NSString *tmpl, NSString *home, NSString *sym) {
            WQBrowserSearchEngineInfo *e = [WQBrowserSearchEngineInfo new];
            e.engineID = eid;
            e.name = name;
            e.searchTemplate = tmpl;
            e.homeURL = home;
            e.symbolName = sym;
            return e;
        };
        list = @[
            mk(@"brave",      @"Brave Search",     @"https://search.brave.com/search?q=%s",          @"https://search.brave.com",  @"shield.lefthalf.filled"),
            mk(@"google",     @"Google",           @"https://www.google.com/search?q=%s",            @"https://www.google.com",    @"magnifyingglass.circle.fill"),
            mk(@"duckduckgo", @"DuckDuckGo",       @"https://duckduckgo.com/?q=%s",                  @"https://duckduckgo.com",    @"lock.shield.fill"),
            mk(@"bing",       @"Bing",             @"https://www.bing.com/search?q=%s",              @"https://www.bing.com",      @"b.circle.fill"),
            mk(@"startpage",  @"Startpage",        @"https://www.startpage.com/sp/search?query=%s",  @"https://www.startpage.com", @"eye.slash.circle.fill"),
            mk(@"ecosia",     @"Ecosia",           @"https://www.ecosia.org/search?q=%s",            @"https://www.ecosia.org",    @"leaf.fill"),
            mk(@"qwant",      @"Qwant",            @"https://www.qwant.com/?q=%s",                   @"https://www.qwant.com",     @"q.circle.fill"),
            mk(@"yahoo",      @"Yahoo",            @"https://search.yahoo.com/search?p=%s",          @"https://www.yahoo.com",     @"y.circle.fill"),
            mk(@"custom",     @"Custom URL (%s)",  @"https://search.brave.com/search?q=%s",          @"https://search.brave.com",  @"slider.horizontal.3"),
        ];
    });
    return list;
}

static WQBrowserSearchEngineInfo *wq_browser_active_search_engine(void)
{
    NSString *selID = [NSUserDefaults.standardUserDefaults stringForKey:kWQBrowserSearchEnginePref] ?: @"brave";
    NSArray<WQBrowserSearchEngineInfo *> *all = wq_browser_search_engines();
    for (WQBrowserSearchEngineInfo *e in all) {
        if ([e.engineID isEqualToString:selID]) {
            if ([e.engineID isEqualToString:@"custom"]) {
                NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:kWQBrowserCustomSearchPref];
                if (custom.length) {
                    WQBrowserSearchEngineInfo *copy = [WQBrowserSearchEngineInfo new];
                    copy.engineID = e.engineID;
                    copy.name = e.name;
                    copy.searchTemplate = custom;
                    copy.symbolName = e.symbolName;
                    NSURL *u = [NSURL URLWithString:[custom stringByReplacingOccurrencesOfString:@"%s" withString:@""]];
                    copy.homeURL = (u.scheme.length && u.host.length)
                        ? [NSString stringWithFormat:@"%@://%@", u.scheme, u.host]
                        : @"https://search.brave.com";
                    return copy;
                }
            }
            return e;
        }
    }
    return all.firstObject;
}

static NSURL *wq_browser_build_search_url(NSString *query)
{
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&+=?#/"];
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    WQBrowserSearchEngineInfo *eng = wq_browser_active_search_engine();
    NSString *tmpl = eng.searchTemplate ?: @"https://search.brave.com/search?q=%s";
    NSString *urlStr = nil;
    if ([tmpl containsString:@"%s"]) {
        urlStr = [tmpl stringByReplacingOccurrencesOfString:@"%s" withString:encoded];
    } else if ([tmpl containsString:@"%@"]) {
        urlStr = [tmpl stringByReplacingOccurrencesOfString:@"%@" withString:encoded];
    } else {
        urlStr = [tmpl stringByAppendingString:encoded];
    }
    return [NSURL URLWithString:urlStr] ?: [NSURL URLWithString:[@"https://search.brave.com/search?q=" stringByAppendingString:encoded]];
}

#pragma mark - Weak WKScriptMessageHandler Proxy

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
@property (nonatomic, copy) NSString *tabID;
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic) BOOL incognito;
@property (nonatomic) BOOL desktopMode;
@property (nonatomic) BOOL webDarkMode;
@property (nonatomic) CGFloat pageZoom;
@property (nonatomic) BOOL isNewTab;
@property (nonatomic, copy, nullable) NSString *savedURLString;
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, strong, nullable) UIImage *snapshot;
@property (nonatomic) NSTimeInterval lastActiveTime;
@property (nonatomic) NSUInteger blockedCount;
@property (nonatomic, strong) NSMutableArray<WQSniffedMedia *> *media;
@property (nonatomic, strong) NSMutableSet<NSString *> *seenURLs;
@end

@implementation WQBrowserTab
- (instancetype)init
{
    if ((self = [super init])) {
        _tabID = NSUUID.UUID.UUIDString;
        _media = [NSMutableArray new];
        _seenURLs = [NSMutableSet new];
        _pageTitle = WQLocalized(@"New Tab");
        _pageZoom = 1.0;
        _isNewTab = YES;
        _lastActiveTime = NSDate.date.timeIntervalSince1970;
    }
    return self;
}
@end

#pragma mark - Persistence Helpers (History, Bookmarks, Reading List, Top Sites, Shields)

static NSString *wq_clean_host(NSURL * _Nullable url)
{
    NSString *h = url.host.lowercaseString;
    if ([h hasPrefix:@"www."] && h.length > 4) h = [h substringFromIndex:4];
    return h ?: @"";
}

static BOOL wq_shields_global_enabled(void)
{
    id pref = [NSUserDefaults.standardUserDefaults objectForKey:kWQBrowserAdBlockPref];
    return pref ? [pref boolValue] : YES;
}

static NSInteger wq_shields_level(void)
{
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kWQBrowserShieldsLevelPref];
    if (!v) return wq_shields_global_enabled() ? 1 : 0;
    NSInteger lvl = [v integerValue];
    return MAX(0, MIN(2, lvl));
}

static BOOL wq_shields_pref_bool(NSString *key, BOOL fallback)
{
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}

static BOOL wq_shields_enabled_for_host(NSString * _Nullable host)
{
    if (!wq_shields_global_enabled() || wq_shields_level() == 0) return NO;
    if (!host.length) return YES;
    NSString *clean = [host.lowercaseString hasPrefix:@"www."] ? [host.lowercaseString substringFromIndex:4] : host.lowercaseString;
    NSArray *disabled = [NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserShieldDisabledHostsPref];
    return ![disabled containsObject:clean];
}

static void wq_shields_set_enabled_for_host(NSString *host, BOOL enabled)
{
    if (!host.length) return;
    NSString *clean = [host.lowercaseString hasPrefix:@"www."] ? [host.lowercaseString substringFromIndex:4] : host.lowercaseString;
    NSMutableArray *arr = [[NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserShieldDisabledHostsPref] mutableCopy] ?: [NSMutableArray new];
    if (enabled) [arr removeObject:clean];
    else if (![arr containsObject:clean]) [arr addObject:clean];
    [NSUserDefaults.standardUserDefaults setObject:arr forKey:kWQBrowserShieldDisabledHostsPref];
}

static BOOL wq_shields_block_scripts_for_host(NSString * _Nullable host)
{
    if (!host.length) return NO;
    NSString *clean = [host.lowercaseString hasPrefix:@"www."] ? [host.lowercaseString substringFromIndex:4] : host.lowercaseString;
    NSArray *arr = [NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserShieldScriptHostsPref];
    return [arr containsObject:clean];
}

static void wq_shields_set_block_scripts_for_host(NSString *host, BOOL block)
{
    if (!host.length) return;
    NSString *clean = [host.lowercaseString hasPrefix:@"www."] ? [host.lowercaseString substringFromIndex:4] : host.lowercaseString;
    NSMutableArray *arr = [[NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserShieldScriptHostsPref] mutableCopy] ?: [NSMutableArray new];
    if (block) {
        if (![arr containsObject:clean]) [arr addObject:clean];
    } else {
        [arr removeObject:clean];
    }
    [NSUserDefaults.standardUserDefaults setObject:arr forKey:kWQBrowserShieldScriptHostsPref];
}

static void wq_shields_record_stat(NSString *kind, NSUInteger count)
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    uint64_t bytesAdd = (uint64_t)count * 48ULL * 1024ULL;
    if ([kind isEqualToString:@"popup"] || [kind isEqualToString:@"clickjack"]) {
        [ud setInteger:[ud integerForKey:kWQBrowserStatsPopupsPref] + (NSInteger)count forKey:kWQBrowserStatsPopupsPref];
        bytesAdd = (uint64_t)count * 120ULL * 1024ULL;
    } else if ([kind isEqualToString:@"tracker"]) {
        [ud setInteger:[ud integerForKey:kWQBrowserStatsTrackersPref] + (NSInteger)count forKey:kWQBrowserStatsTrackersPref];
    } else {
        [ud setInteger:[ud integerForKey:kWQBrowserStatsAdsPref] + (NSInteger)count forKey:kWQBrowserStatsAdsPref];
    }
    long long prevBytes = [[ud objectForKey:kWQBrowserStatsBytesPref] longLongValue];
    [ud setObject:@(prevBytes + (long long)bytesAdd) forKey:kWQBrowserStatsBytesPref];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *wq_browser_load_list(NSString *prefKey, NSArray<NSDictionary<NSString *, NSString *> *> * _Nullable defaultsList)
{
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:prefKey];
    if (!raw) return defaultsList ?: @[];
    NSMutableArray *out = [NSMutableArray new];
    for (id obj in raw) {
        if ([obj isKindOfClass:NSDictionary.class] && [obj[@"url"] isKindOfClass:NSString.class]) {
            [out addObject:@{
                @"title": [obj[@"title"] isKindOfClass:NSString.class] ? obj[@"title"] : obj[@"url"],
                @"url": obj[@"url"],
            }];
        }
    }
    return out;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *wq_browser_bookmarks_list(void)
{
    return wq_browser_load_list(kWQBrowserBookmarksPref, @[
        @{ @"title": @"Brave Search", @"url": @"https://search.brave.com" },
        @{ @"title": @"DuckDuckGo", @"url": @"https://duckduckgo.com" },
        @{ @"title": @"GitHub", @"url": @"https://github.com" },
        @{ @"title": @"Internet Archive", @"url": @"https://archive.org" },
    ]);
}

static BOOL wq_browser_is_bookmarked(NSString * _Nullable urlStr)
{
    if (!urlStr.length) return NO;
    for (NSDictionary *d in wq_browser_bookmarks_list()) {
        if ([d[@"url"] isEqualToString:urlStr]) return YES;
    }
    return NO;
}

static void wq_browser_toggle_bookmark(NSString *urlStr, NSString * _Nullable title, BOOL *addedOut)
{
    if (!urlStr.length) return;
    NSMutableArray *arr = [wq_browser_bookmarks_list() mutableCopy];
    NSInteger found = -1;
    for (NSUInteger i = 0; i < arr.count; i++) {
        if ([arr[i][@"url"] isEqualToString:urlStr]) { found = (NSInteger)i; break; }
    }
    if (found >= 0) {
        [arr removeObjectAtIndex:(NSUInteger)found];
        if (addedOut) *addedOut = NO;
    } else {
        [arr insertObject:@{ @"title": title.length ? title : urlStr, @"url": urlStr } atIndex:0];
        if (addedOut) *addedOut = YES;
    }
    [NSUserDefaults.standardUserDefaults setObject:arr forKey:kWQBrowserBookmarksPref];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *wq_browser_top_sites_list(void)
{
    return wq_browser_load_list(kWQBrowserTopSitesPref, @[
        @{ @"title": @"Brave",     @"url": @"https://search.brave.com" },
        @{ @"title": @"Google",    @"url": @"https://www.google.com" },
        @{ @"title": @"GitHub",    @"url": @"https://github.com" },
        @{ @"title": @"Wikipedia", @"url": @"https://en.wikipedia.org" },
        @{ @"title": @"Archive",   @"url": @"https://archive.org" },
        @{ @"title": @"YouTube",   @"url": @"https://m.youtube.com" },
        @{ @"title": @"Apple Dev", @"url": @"https://developer.apple.com" },
    ]);
}

static void wq_browser_record_history(NSString *urlStr, NSString * _Nullable title)
{
    if (!urlStr.length || [urlStr isEqualToString:@"about:blank"]) return;
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"]) return;
    NSMutableArray *hist = [[NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserHistoryPref] mutableCopy] ?: [NSMutableArray new];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // Deduplicate immediate same-URL visit within 5 minutes
    if (hist.count) {
        NSDictionary *top = hist.firstObject;
        if ([top isKindOfClass:NSDictionary.class] && [top[@"url"] isEqualToString:urlStr]) {
            NSTimeInterval ts = [top[@"ts"] doubleValue];
            if (now - ts < 300.0) {
                if (title.length) {
                    hist[0] = @{ @"url": urlStr, @"title": title, @"ts": @(now) };
                    [NSUserDefaults.standardUserDefaults setObject:hist forKey:kWQBrowserHistoryPref];
                }
                return;
            }
        }
    }
    [hist insertObject:@{ @"url": urlStr, @"title": title.length ? title : urlStr, @"ts": @(now) } atIndex:0];
    if (hist.count > kWQMaxHistoryEntries) {
        [hist removeObjectsInRange:NSMakeRange(kWQMaxHistoryEntries, hist.count - kWQMaxHistoryEntries)];
    }
    [NSUserDefaults.standardUserDefaults setObject:hist forKey:kWQBrowserHistoryPref];
}

#pragma mark - URL Stripping, HTTPS Upgrade & Download Detection

static NSURL * _Nullable wq_strip_tracking_params(NSURL * _Nullable url, NSInteger *strippedCount)
{
    if (strippedCount) *strippedCount = 0;
    if (!url || !url.query.length) return url;
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!comps || !comps.queryItems.count) return url;

    static NSSet<NSString *> *badParams;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        badParams = [NSSet setWithArray:@[
            @"utm_source", @"utm_medium", @"utm_campaign", @"utm_term", @"utm_content", @"utm_id", @"utm_name",
            @"fbclid", @"gclid", @"dclid", @"gbraid", @"wbraid", @"msclkid",
            @"mc_cid", @"mc_eid", @"igshid", @"ref_src", @"_hsenc", @"_hsmi",
            @"yclid", @"oly_enc_id", @"oly_anon_id", @"s_kwcid", @"mkt_tok",
        ]];
    });
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray new];
    NSInteger removed = 0;
    for (NSURLQueryItem *qi in comps.queryItems) {
        NSString *lk = qi.name.lowercaseString;
        if ([badParams containsObject:lk] || [lk hasPrefix:@"utm_"]) {
            removed++;
        } else {
            [kept addObject:qi];
        }
    }
    if (removed == 0) return url;
    if (strippedCount) *strippedCount = removed;
    comps.queryItems = kept.count ? kept : nil;
    return comps.URL ?: url;
}

static BOOL wq_is_local_or_lan_host(NSString *host)
{
    NSString *h = host.lowercaseString;
    if (!h.length) return YES;
    if ([h isEqualToString:@"localhost"] || [h isEqualToString:@"::1"] || [h hasSuffix:@".local"]) return YES;
    if ([h hasPrefix:@"127."] || [h hasPrefix:@"192.168."] || [h hasPrefix:@"10."] || [h hasPrefix:@"169.254."]) return YES;
    if ([h hasPrefix:@"172."]) {
        NSArray<NSString *> *parts = [h componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            NSInteger second = parts[1].integerValue;
            if (second >= 16 && second <= 31) return YES;
        }
    }
    return NO;
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
            @"mp4", @"m4v", @"mov", @"mkv", @"webm", @"avi", @"flv", @"ts", @"m2ts", @"mts", @"m3u8",
            @"mp3", @"m4a", @"aac", @"flac", @"wav", @"ogg", @"opus",
            @"epub", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx",
        ]];
    });
    return [dlExts containsObject:ext];
}

static BOOL wq_url_is_playable_media(NSURL *url)
{
    NSString *ext = url.pathExtension.lowercaseString;
    if (!ext.length) return NO;
    static NSSet<NSString *> *avExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        avExts = [NSSet setWithArray:@[
            @"mp4", @"m4v", @"mov", @"mkv", @"webm", @"avi", @"flv", @"ts", @"m2ts", @"mts", @"mpg", @"mpeg", @"m3u8",
            @"mp3", @"m4a", @"aac", @"flac", @"wav", @"ogg", @"opus",
        ]];
    });
    return [avExts containsObject:ext];
}

static NSDictionary<NSString *, NSString *> *wq_headers_for_sniffed(WQSniffedMedia *m)
{
    NSMutableDictionary<NSString *, NSString *> *h = [NSMutableDictionary new];
    if (m.referer.length) h[@"Referer"] = m.referer;
    if (m.cookie.length) h[@"Cookie"] = m.cookie;
    if (m.userAgent.length) h[@"User-Agent"] = m.userAgent;
    return h;
}

#pragma mark - Brave Shields Rule Lists & Injected Scripts

static NSString *wq_browser_shields_rules_json(BOOL aggressive, BOOL blockAds, BOOL hideCookies)
{
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray new];

    if (blockAds) {
        // 1. Ad & Popunder Networks
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": @".*(doubleclick\\\\.net|googlesyndication\\\\.com|googleadservices\\\\.com|adservice\\\\.google\\\\.|taboola\\\\.com|outbrain\\\\.com|popads\\\\.net|popcash\\\\.net|propellerads\\\\.com|exoclick\\\\.com|juicyads\\\\.com|trafficjunky\\\\.com|adsterra\\\\.com|hilltopads\\\\.net|clickadu\\\\.com|adcash\\\\.com|mgid\\\\.com|revcontent\\\\.com|adnxs\\\\.com|criteo\\\\.com|amazon-adsystem\\\\.com|rubiconproject\\\\.com|pubmatic\\\\.com|openx\\\\.net|casalemedia\\\\.com|adcolony\\\\.com|unityads\\\\.unity3d\\\\.com|applovin\\\\.com|vungle\\\\.com|ironsrc\\\\.com|inmobi\\\\.com|smartadserver\\\\.com|yieldmo\\\\.com|sharethrough\\\\.com|triplelift\\\\.com|33across\\\\.com|spotxchange\\\\.com|springserve\\\\.com|imasdk\\\\.googleapis\\\\.com|ads\\\\.yahoo\\\\.com|advertising\\\\.com|adform\\\\.net|bidswitch\\\\.net|contextweb\\\\.com|gumgum\\\\.com|indexexchange\\\\.com|kargo\\\\.com|lijit\\\\.com|media\\\\.net|moatads\\\\.com|quantserve\\\\.com|serving-sys\\\\.com|sizmek\\\\.com|teads\\\\.tv|undertone\\\\.com|zedo\\\\.com|bidvertiser\\\\.com|onclickalgo\\\\.com|monetag\\\\.com|ero-advertising\\\\.com|adnium\\\\.com|adxpansion\\\\.com).*"
            },
            @"action": @{ @"type": @"block" }
        }];

        // 2. Trackers, Analytics & Session Recorders
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": @".*(google-analytics\\\\.com|googletagmanager\\\\.com|connect\\\\.facebook\\\\.net|pixel\\\\.facebook\\\\.com|analytics\\\\.tiktok\\\\.com|ads-twitter\\\\.com|analytics\\\\.twitter\\\\.com|hotjar\\\\.com|fullstory\\\\.com|mixpanel\\\\.com|segment\\\\.io|amplitude\\\\.com|clarity\\\\.ms|mouseflow\\\\.com|crazyegg\\\\.com|heap\\\\.io|kissmetrics\\\\.com|newrelic\\\\.com|nr-data\\\\.net|sentry\\\\.io|bugsnag\\\\.com|scorecardresearch\\\\.com|omtrdc\\\\.net|demdex\\\\.net|bluekai\\\\.com|krxd\\\\.net|chartbeat\\\\.com|branch\\\\.io|app\\\\.link|adjust\\\\.com|appsflyer\\\\.com).*"
            },
            @"action": @{ @"type": @"block" }
        }];

        // 3. Cosmetic Ad Slots
        [rules addObject:@{
            @"trigger": @{ @"url-filter": @".*" },
            @"action": @{
                @"type": @"css-display-none",
                @"selector": @".adsbygoogle, ins.adsbygoogle, [id^='div-gpt-ad'], [class*='ad-banner'], .ad-container, .ad-slot, .sponsored-post, .outbrain-widget, .taboola-widget"
            }
        }];

        if (aggressive) {
            [rules addObject:@{
                @"trigger": @{
                    @"url-filter": @".*(adsystem|popunder|prebid|adserver|adsbox|banner_ad|track\\\\.php|pixel\\\\.gif).*",
                    @"load-type": @[@"third-party"],
                    @"resource-type": @[@"script", @"image", @"raw"]
                },
                @"action": @{ @"type": @"block" }
            }];
            [rules addObject:@{
                @"trigger": @{ @"url-filter": @".*" },
                @"action": @{
                    @"type": @"css-display-none",
                    @"selector": @"[id*='google_ads'], [class*='sponsored-'], .sticky-ad, .floating-ad, .interstitial-ad"
                }
            }];
        }
    }

    if (hideCookies) {
        [rules addObject:@{
            @"trigger": @{ @"url-filter": @".*" },
            @"action": @{
                @"type": @"css-display-none",
                @"selector": @"#onetrust-banner-sdk, .onetrust-pc-dark-filter, #CybotCookiebotDialog, .cc-window, [id*='cookie-banner'], [class*='cookie-consent'], #qc-cmp2-container, .fc-consent-root"
            }
        }];
    }

    if (!rules.count) return @"[]";
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

static NSString *wq_browser_core_shield_and_probe_js(BOOL shieldsActive, BOOL blockPopups, BOOL darkMode)
{
    return [NSString stringWithFormat:
        @"(function(){"
        "if(window.__wqCoreInstalled) return; window.__wqCoreInstalled=true;"
        "var shieldOn=%@, popupsOn=%@;"
        "function postShield(kind, url){"
        "  try{ if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wqShieldEvent){"
        "    window.webkit.messageHandlers.wqShieldEvent.postMessage({kind:kind, url:String(url||'')});"
        "  }}catch(e){}"
        "}"
        "if(shieldOn){"
        "  try{ Object.defineProperty(navigator, 'globalPrivacyControl', { get: function(){ return true; }, configurable: true }); }catch(e){}"
        "  try{ Object.defineProperty(navigator, 'doNotTrack', { get: function(){ return '1'; }, configurable: true }); }catch(e){}"
        "}"
        "var lastTap = 0;"
        "function recordHit(ev){"
        "  try{"
        "    lastTap = Date.now();"
        "    var x = 0, y = 0;"
        "    if(ev.touches && ev.touches.length){ x = ev.touches[0].clientX; y = ev.touches[0].clientY; }"
        "    else if(typeof ev.clientX === 'number'){ x = ev.clientX; y = ev.clientY; }"
        "    var els = (document.elementsFromPoint && (x||y)) ? document.elementsFromPoint(x, y) : [ev.target];"
        "    var hit = { href:'', videoSrc:'', audioSrc:'', imgSrc:'', title:'', text:'' };"
        "    function checkNode(el){"
        "      if(!el) return;"
        "      var t = (el.tagName||'').toUpperCase();"
        "      if(!hit.href && t==='A' && el.href){ hit.href = el.href; hit.text = (el.innerText||'').trim(); }"
        "      if(!hit.videoSrc && t==='VIDEO'){ hit.videoSrc = el.currentSrc || el.src || ''; if(!hit.videoSrc){ var srcEl = el.querySelector('source'); if(srcEl) hit.videoSrc = srcEl.src||''; } }"
        "      if(!hit.audioSrc && t==='AUDIO'){ hit.audioSrc = el.currentSrc || el.src || ''; if(!hit.audioSrc){ var aEl = el.querySelector('source'); if(aEl) hit.audioSrc = aEl.src||''; } }"
        "      if(!hit.imgSrc && t==='IMG' && (el.currentSrc||el.src)){ hit.imgSrc = el.currentSrc || el.src; }"
        "    }"
        "    for(var i=0;i<els.length;i++){ checkNode(els[i]); }"
        "    var cur = ev.target;"
        "    while(cur && cur !== document){ checkNode(cur); cur = cur.parentElement; }"
        "    hit.title = document.title || '';"
        "    window.__wqLastHit = hit;"
        "  }catch(e){}"
        "}"
        "document.addEventListener('touchstart', recordHit, {capture:true, passive:true});"
        "document.addEventListener('pointerdown', function(ev){"
        "  recordHit(ev);"
        "  if(!shieldOn || !popupsOn) return;"
        "  try{"
        "    var el = ev.target;"
        "    if(el && el.tagName && el !== document.body && el !== document.documentElement){"
        "      var st = getComputedStyle(el);"
        "      var r = el.getBoundingClientRect();"
        "      var full = (r.width >= window.innerWidth*0.75 && r.height >= window.innerHeight*0.75);"
        "      var invis = (parseFloat(st.opacity) < 0.08 || st.backgroundColor === 'transparent' || st.backgroundColor === 'rgba(0, 0, 0, 0)');"
        "      var z = parseInt(st.zIndex, 10) || 0;"
        "      if(full && invis && st.position === 'fixed' && z >= 999 && !el.querySelector('video,input,button')){"
        "        el.style.display = 'none';"
        "        postShield('clickjack', location.href);"
        "      }"
        "    }"
        "  }catch(e){}"
        "}, {capture:true, passive:true});"
        "document.addEventListener('contextmenu', recordHit, {capture:true, passive:true});"
        "if(shieldOn && popupsOn){"
        "  var origOpen = window.open;"
        "  var badRx = /(popads|popcash|propellerads|exoclick|juicyads|adsterra|clickadu|monetag|doubleclick|taboola|outbrain)/i;"
        "  window.open = function(u){"
        "    var urlStr = u ? String(u) : '';"
        "    var userRecent = (Date.now() - lastTap) < 650;"
        "    if(!userRecent || badRx.test(urlStr)){"
        "      postShield('popup', urlStr);"
        "      return null;"
        "    }"
        "    return origOpen.apply(window, arguments);"
        "  };"
        "  var origAClick = HTMLAnchorElement.prototype.click;"
        "  HTMLAnchorElement.prototype.click = function(){"
        "    var userRecent = (Date.now() - lastTap) < 650;"
        "    if((this.target === '_blank' || !this.isConnected) && (!userRecent || badRx.test(this.href||''))){"
        "      postShield('popup', this.href || '');"
        "      return;"
        "    }"
        "    return origAClick.apply(this, arguments);"
        "  };"
        "}"
        "window.__wqSetDarkMode = function(on){"
        "  var sid='__wqDarkCSS'; var ex=document.getElementById(sid);"
        "  if(!on){ if(ex) ex.remove(); return; }"
        "  if(!ex){"
        "    ex=document.createElement('style'); ex.id=sid;"
        "    ex.textContent='html{filter:invert(0.92) hue-rotate(180deg) !important; background:#111 !important;} img,video,picture,canvas,svg,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg) !important;}';"
        "    (document.head||document.documentElement).appendChild(ex);"
        "  }"
        "};"
        "if(%@){ document.addEventListener('DOMContentLoaded', function(){ window.__wqSetDarkMode(true); }); }"
        "})();",
        shieldsActive ? @"true" : @"false",
        blockPopups ? @"true" : @"false",
        darkMode ? @"true" : @"false"
    ];
}

static NSString *wq_browser_media_sniffer_js(void)
{
    return @"(function(){"
    "if(window.__wqSniffInstalled) return; window.__wqSniffInstalled = true;"
    "var seen = {};"
    "var rx = /\\.(m3u8|mp4|m4v|mov|mkv|webm|avi|flv|ts|m2ts|mp3|m4a|aac|flac|ogg|opus|wav)(\\?|#|$)/i;"
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

#pragma mark - 1DM/IDM Media Grabber & Quality Picker Sheet (Stream + Download)

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
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                if (strongSelf->_onClear) strongSelf->_onClear();
                strongSelf->_media = @[];
                [strongSelf.tableView reloadData];
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
    return WQLocalized(@"Tap any stream to play in WQ Pro Player or download (including HLS quality selection with captured cookies & headers).");
}

- (void)streamMediaItem:(WQSniffedMedia *)m
{
    NSURL *u = [NSURL URLWithString:m.urlString];
    if (!u) return;
    NSString *title = m.title.length ? m.title : (u.lastPathComponent.length ? u.lastPathComponent : @"Stream");
    NSDictionary<NSString *, NSString *> *hdrs = wq_headers_for_sniffed(m);
    [WQProMediaPlayerViewController presentStreamFrom:self title:title streamURL:u headers:hdrs];
}

- (void)downloadMediaItem:(WQSniffedMedia *)m
{
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
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQSniffedMedia *m = _media[(NSUInteger)indexPath.row];
    NSString *tag = m.isHLS ? @"HLS · Stream / Quality" : m.kind;
    NSString *fname = [NSURL URLWithString:m.urlString].lastPathComponent;
    if (!fname.length || [fname isEqualToString:@"/"]) fname = m.title.length ? m.title : @"media";
    c.text = [NSString stringWithFormat:@"[%@] %@", tag, fname];
    c.secondaryText = m.urlString;
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:m.isHLS ? @"sparkles.tv.fill" : ([m.kind isEqualToString:@"MP3"] || [m.kind isEqualToString:@"M4A"] || [m.kind isEqualToString:@"AUDIO"] ? @"music.note" : @"film.fill")];
    c.imageProperties.tintColor = m.isHLS ? wq_theme_aurora_teal() : wq_theme_accent();
    cell.contentConfiguration = c;

    __weak typeof(self) weakSelf = self;
    UIButtonConfiguration *pCfg = [UIButtonConfiguration tintedButtonConfiguration];
    pCfg.image = [UIImage systemImageNamed:@"play.fill"];
    pCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    pCfg.baseBackgroundColor = wq_theme_aurora_teal();
    pCfg.baseForegroundColor = wq_theme_aurora_teal();
    pCfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
    UIButton *playBtn = [UIButton buttonWithConfiguration:pCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf streamMediaItem:m];
    }]];
    [playBtn sizeToFit];
    cell.accessoryView = playBtn;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_media.count) return;
    wq_haptic_selection();
    WQSniffedMedia *m = _media[(NSUInteger)indexPath.row];
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(m.title.length ? m.title : m.kind),
                                                   WQVerbatim(m.urlString),
                                                   UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Play in WQ Pro Player"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self streamMediaItem:m];
    })];
    [sheet addAction:wq_alert_action(m.isHLS ? WQLocalized(@"Pick Quality & Download…") : WQLocalized(@"Download with Cookies…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self downloadMediaItem:m];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Copy URL"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = m.urlString;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: tableView;
    sheet.popoverPresentationController.sourceRect = (cell ?: tableView).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
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
    _seg = [[UISegmentedControl alloc] initWithItems:@[
        WQLocalized(@"All"), WQLocalized(@"Videos"), WQLocalized(@"Audio"), WQLocalized(@"Images"), WQLocalized(@"Files")
    ]];
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

#pragma mark - Per-Site Brave Shields Panel

@interface WQBrowserShieldsViewController : UITableViewController
- (instancetype)initWithHost:(NSString *)host pageBlocked:(NSUInteger)pageBlocked onChanged:(void (^)(void))onChanged;
@end

@implementation WQBrowserShieldsViewController {
    NSString *_host;
    NSUInteger _pageBlocked;
    void (^_onChanged)(void);
}

- (instancetype)initWithHost:(NSString *)host pageBlocked:(NSUInteger)pageBlocked onChanged:(void (^)(void))onChanged
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _host = host.length ? [host copy] : WQLocalized(@"All Websites");
        _pageBlocked = pageBlocked;
        _onChanged = [onChanged copy];
        self.title = WQLocalized(@"Brave Shields");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = UIColor.clearColor;
    __weak typeof(self) weakSelf = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Done") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 3; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return 5;
    return 3;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return _host;
    if (section == 1) return WQLocalized(@"Shields Controls");
    return WQLocalized(@"Privacy Statistics");
}

- (UISwitch *)makeSwitch:(BOOL)on tag:(NSInteger)tag
{
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.tag = tag;
    sw.onTintColor = wq_theme_aurora_teal();
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (void)switchChanged:(UISwitch *)sw
{
    wq_haptic_selection();
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    switch (sw.tag) {
        case 1:
            if (![_host isEqualToString:WQLocalized(@"All Websites")]) {
                wq_shields_set_enabled_for_host(_host, sw.isOn);
            } else {
                [ud setBool:sw.isOn forKey:kWQBrowserAdBlockPref];
            }
            break;
        case 2: [ud setBool:sw.isOn forKey:kWQBrowserShieldBlockAdsPref]; break;
        case 3: [ud setBool:sw.isOn forKey:kWQBrowserShieldBlockPopupsPref]; break;
        case 4: [ud setBool:sw.isOn forKey:kWQBrowserShieldHTTPSUpgradePref]; break;
        case 5: [ud setBool:sw.isOn forKey:kWQBrowserShieldCookieHidePref]; break;
        case 6: wq_shields_set_block_scripts_for_host(_host, sw.isOn); break;
        default: break;
    }
    if (_onChanged) _onChanged();
    [self.tableView reloadData];
}

- (void)levelChanged:(UISegmentedControl *)seg
{
    wq_haptic_selection();
    NSInteger lvl = seg.selectedSegmentIndex; // 0=Off, 1=Standard, 2=Aggressive
    [NSUserDefaults.standardUserDefaults setInteger:lvl forKey:kWQBrowserShieldsLevelPref];
    [NSUserDefaults.standardUserDefaults setBool:(lvl > 0) forKey:kWQBrowserAdBlockPref];
    if (_onChanged) _onChanged();
    [self.tableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sh-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"sh-cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();

    BOOL siteUp = wq_shields_enabled_for_host([_host isEqualToString:WQLocalized(@"All Websites")] ? nil : _host);
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c.text = siteUp ? WQLocalized(@"Shields UP for This Site") : WQLocalized(@"Shields DOWN for This Site");
            c.secondaryText = WQLocalizedFormat(@"%lu blocked", (unsigned long)_pageBlocked);
            c.image = [UIImage systemImageNamed:siteUp ? @"shield.lefthalf.filled" : @"shield.slash"];
            c.imageProperties.tintColor = siteUp ? wq_theme_aurora_teal() : UIColor.systemOrangeColor;
            cell.contentConfiguration = c;
            cell.accessoryView = [self makeSwitch:siteUp tag:1];
        } else {
            c.text = WQLocalized(@"Blocking Level");
            c.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.contentConfiguration = c;
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
                WQLocalized(@"Off"), WQLocalized(@"Standard"), WQLocalized(@"Aggressive")
            ]];
            seg.selectedSegmentIndex = wq_shields_level();
            [seg addTarget:self action:@selector(levelChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
        }
    } else if (indexPath.section == 1) {
        NSArray<NSArray *> *rows = @[
            @[WQLocalized(@"Ads & Trackers"),        @"hand.raised.fill",     @(wq_shields_pref_bool(kWQBrowserShieldBlockAdsPref, YES)),     @2],
            @[WQLocalized(@"Popups & Redirects"),    @"macwindow.badge.plus", @(wq_shields_pref_bool(kWQBrowserShieldBlockPopupsPref, YES)),  @3],
            @[WQLocalized(@"Upgrade Connections (HTTPS)"), @"lock.shield.fill", @(wq_shields_pref_bool(kWQBrowserShieldHTTPSUpgradePref, YES)), @4],
            @[WQLocalized(@"Hide Cookie Notices"),   @"eye.slash.fill",       @(wq_shields_pref_bool(kWQBrowserShieldCookieHidePref, YES)),   @5],
            @[WQLocalized(@"Block Scripts (This Site)"), @"curlybraces",      @(wq_shields_block_scripts_for_host(_host)),                    @6],
        ];
        NSArray *r = rows[(NSUInteger)indexPath.row];
        c.text = r[0];
        c.image = [UIImage systemImageNamed:r[1]];
        c.imageProperties.tintColor = wq_theme_accent();
        cell.contentConfiguration = c;
        cell.accessoryView = [self makeSwitch:[r[2] boolValue] tag:[r[3] integerValue]];
    } else {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSInteger ads = [ud integerForKey:kWQBrowserStatsAdsPref] + [ud integerForKey:kWQBrowserStatsTrackersPref];
        NSInteger pops = [ud integerForKey:kWQBrowserStatsPopupsPref];
        unsigned long long bytes = (unsigned long long)[[ud objectForKey:kWQBrowserStatsBytesPref] unsignedLongLongValue];
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Trackers & Ads Blocked");
            c.secondaryText = [NSString stringWithFormat:@"%ld", (long)ads];
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Popups & Redirects Stopped");
            c.secondaryText = [NSString stringWithFormat:@"%ld", (long)pops];
        } else {
            c.text = WQLocalized(@"Estimated Data Saved");
            c.secondaryText = wq_size_text(bytes);
        }
        c.secondaryTextProperties.color = wq_theme_aurora_teal();
        cell.contentConfiguration = c;
    }
    return cell;
}

@end

#pragma mark - History Manager View Controller

@interface WQBrowserHistoryViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithOnOpenURL:(void (^)(NSString *url, BOOL newTab))onOpenURL;
@end

@implementation WQBrowserHistoryViewController {
    void (^_onOpenURL)(NSString *, BOOL);
    NSMutableArray<NSDictionary *> *_all;
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
    UISearchController *_search;
}

- (instancetype)initWithOnOpenURL:(void (^)(NSString *url, BOOL newTab))onOpenURL
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _onOpenURL = [onOpenURL copy];
        self.title = WQLocalized(@"History");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = UIColor.clearColor;

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = WQLocalized(@"Search History…");
    self.navigationItem.searchController = _search;

    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Clear…") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf promptClearHistory];
    }]];
    [self reloadHistory];
}

- (void)reloadHistory
{
    _all = [[NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserHistoryPref] mutableCopy] ?: [NSMutableArray new];
    [self rebuildSectionsWithFilter:_search.searchBar.text];
}

- (void)rebuildSectionsWithFilter:(NSString *)q
{
    NSString *needle = [q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSMutableArray *today = [NSMutableArray new], *yesterday = [NSMutableArray new], *earlier = [NSMutableArray new];
    for (NSDictionary *d in _all) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSString *u = d[@"url"] ?: @"";
        NSString *t = d[@"title"] ?: u;
        if (needle.length && ![u.lowercaseString containsString:needle] && ![t.lowercaseString containsString:needle]) continue;
        NSDate *dt = [NSDate dateWithTimeIntervalSince1970:[d[@"ts"] doubleValue]];
        if ([cal isDateInToday:dt]) [today addObject:d];
        else if ([cal isDateInYesterday:dt]) [yesterday addObject:d];
        else {
            NSTimeInterval diff = [now timeIntervalSinceDate:dt];
            (void)diff;
            [earlier addObject:d];
        }
    }
    NSMutableArray *secs = [NSMutableArray new], *titles = [NSMutableArray new];
    if (today.count) { [secs addObject:today]; [titles addObject:WQLocalized(@"Today")]; }
    if (yesterday.count) { [secs addObject:yesterday]; [titles addObject:WQLocalized(@"Yesterday")]; }
    if (earlier.count) { [secs addObject:earlier]; [titles addObject:WQLocalized(@"Earlier")]; }
    _sections = secs;
    _sectionTitles = titles;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self rebuildSectionsWithFilter:searchController.searchBar.text];
}

- (void)promptClearHistory
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Clear Browsing History"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Last Hour"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self clearSince:[NSDate.date dateByAddingTimeInterval:-3600]];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Today"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        NSDate *start = [NSCalendar.currentCalendar startOfDayForDate:NSDate.date];
        [self clearSince:start];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"All Time"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQBrowserHistoryPref];
        [self reloadHistory];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)clearSince:(NSDate *)cutoff
{
    NSTimeInterval cut = cutoff.timeIntervalSince1970;
    NSMutableArray *kept = [NSMutableArray new];
    for (NSDictionary *d in _all) {
        if ([d[@"ts"] doubleValue] < cut) [kept addObject:d];
    }
    [NSUserDefaults.standardUserDefaults setObject:kept forKey:kWQBrowserHistoryPref];
    [self reloadHistory];
    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return MAX(1, (NSInteger)_sections.count); }
- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (!_sections.count) return 1;
    return (NSInteger)_sections[(NSUInteger)section].count;
}
- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (!_sections.count) return nil;
    return _sectionTitles[(NSUInteger)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"hist-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hist-cell"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_sections.count) {
        c.text = WQLocalized(@"No Browsing History");
        c.secondaryText = WQLocalized(@"Pages you visit in Normal tabs appear here.");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSDictionary *d = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    c.text = d[@"title"] ?: d[@"url"];
    c.secondaryText = d[@"url"];
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:@"clock.fill"];
    c.imageProperties.tintColor = wq_theme_accent();
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_sections.count) return;
    NSDictionary *d = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *u = d[@"url"];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self->_onOpenURL && u.length) self->_onOpenURL(u, NO);
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_sections.count) return nil;
    NSDictionary *target = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:WQLocalized(@"Delete")
                                                                    handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        [self->_all removeObject:target];
        [NSUserDefaults.standardUserDefaults setObject:self->_all forKey:kWQBrowserHistoryPref];
        [self reloadHistory];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *__unused)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint __unused)point
{
    if (!_sections.count) return nil;
    NSDictionary *d = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *u = d[@"url"] ?: @"";
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        return [UIMenu menuWithTitle:@"" children:@[
            [UIAction actionWithTitle:WQLocalized(@"Open in New Tab") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf dismissViewControllerAnimated:YES completion:^{
                    WQBrowserHistoryViewController *me = weakSelf;
                    if (me && me->_onOpenURL && u.length) me->_onOpenURL(u, YES);
                }];
            }],
            [UIAction actionWithTitle:WQLocalized(@"Copy URL") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
                UIPasteboard.generalPasteboard.string = u;
            }],
        ]];
    }];
}

@end

#pragma mark - Bookmarks & Reading List Manager View Controller

@interface WQBrowserBookmarksViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithInitialSegment:(NSInteger)seg onOpenURL:(void (^)(NSString *url, BOOL newTab))onOpenURL;
@end

@implementation WQBrowserBookmarksViewController {
    NSInteger _segment; // 0 = Bookmarks, 1 = Reading List
    void (^_onOpenURL)(NSString *, BOOL);
    UISegmentedControl *_seg;
    NSMutableArray<NSMutableDictionary *> *_items;
    NSArray<NSMutableDictionary *> *_filtered;
    UISearchController *_search;
}

- (instancetype)initWithInitialSegment:(NSInteger)seg onOpenURL:(void (^)(NSString *url, BOOL newTab))onOpenURL
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _segment = seg;
        _onOpenURL = [onOpenURL copy];
        self.title = WQLocalized(@"Bookmarks & Reading List");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = UIColor.clearColor;

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = WQLocalized(@"Search Bookmarks…");
    self.navigationItem.searchController = _search;

    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Add") image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf promptAddOrEditIndex:-1];
    }]];

    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width ?: 360, 50)];
    _seg = [[UISegmentedControl alloc] initWithItems:@[WQLocalized(@"Bookmarks"), WQLocalized(@"Reading List")]];
    _seg.translatesAutoresizingMaskIntoConstraints = NO;
    _seg.selectedSegmentIndex = _segment;
    [_seg addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    [hdr addSubview:_seg];
    [NSLayoutConstraint activateConstraints:@[
        [_seg.topAnchor constraintEqualToAnchor:hdr.topAnchor constant:8],
        [_seg.bottomAnchor constraintEqualToAnchor:hdr.bottomAnchor constant:-8],
        [_seg.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor constant:16],
        [_seg.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor constant:-16],
    ]];
    self.tableView.tableHeaderView = hdr;
    [self reloadDataList];
}

- (NSString *)activePrefKey
{
    return _segment == 0 ? kWQBrowserBookmarksPref : kWQBrowserReadingListPref;
}

- (void)segmentChanged
{
    _segment = _seg.selectedSegmentIndex;
    [self reloadDataList];
}

- (void)reloadDataList
{
    NSArray *raw = _segment == 0 ? wq_browser_bookmarks_list() : wq_browser_load_list(kWQBrowserReadingListPref, @[]);
    _items = [NSMutableArray new];
    for (NSDictionary *d in raw) [_items addObject:[d mutableCopy]];
    [self applyFilter:_search.searchBar.text];
}

- (void)saveList
{
    [NSUserDefaults.standardUserDefaults setObject:_items forKey:[self activePrefKey]];
}

- (void)applyFilter:(NSString *)q
{
    NSString *needle = [q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (!needle.length) {
        _filtered = [_items copy];
    } else {
        NSMutableArray *out = [NSMutableArray new];
        for (NSMutableDictionary *d in _items) {
            NSString *t = [d[@"title"] lowercaseString] ?: @"";
            NSString *u = [d[@"url"] lowercaseString] ?: @"";
            if ([t containsString:needle] || [u containsString:needle]) [out addObject:d];
        }
        _filtered = out;
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self applyFilter:searchController.searchBar.text];
}

- (void)promptAddOrEditIndex:(NSInteger)itemIdx
{
    BOOL editing = itemIdx >= 0 && (NSUInteger)itemIdx < _items.count;
    NSMutableDictionary *existing = editing ? _items[(NSUInteger)itemIdx] : nil;
    UIAlertController *ac = wq_alert_controller(editing ? WQLocalized(@"Edit Entry") : WQLocalized(@"Add Bookmark"), nil, UIAlertControllerStyleAlert);
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Title");
        if (existing) tf.text = existing[@"title"];
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        if (existing) tf.text = existing[@"url"];
    }];
    [ac addAction:wq_alert_action(WQLocalized(@"Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *t = [ac.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *u = [ac.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!u.length) return;
        if (![u hasPrefix:@"http://"] && ![u hasPrefix:@"https://"]) u = [@"https://" stringByAppendingString:u];
        NSMutableDictionary *entry = [@{ @"title": t.length ? t : u, @"url": u } mutableCopy];
        if (editing) self->_items[(NSUInteger)itemIdx] = entry;
        else [self->_items insertObject:entry atIndex:0];
        [self saveList];
        [self applyFilter:self->_search.searchBar.text];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    })];
    [ac addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }
- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_filtered.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"bm-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"bm-cell"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_filtered.count) {
        c.text = _segment == 0 ? WQLocalized(@"No Bookmarks") : WQLocalized(@"Reading List Empty");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSDictionary *d = _filtered[(NSUInteger)indexPath.row];
    c.text = d[@"title"] ?: d[@"url"];
    c.secondaryText = d[@"url"];
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:_segment == 0 ? @"star.fill" : @"book.fill"];
    c.imageProperties.tintColor = _segment == 0 ? UIColor.systemYellowColor : wq_theme_aurora_teal();
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_filtered.count) return;
    NSString *u = _filtered[(NSUInteger)indexPath.row][@"url"];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self->_onOpenURL && u.length) self->_onOpenURL(u, NO);
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_filtered.count) return nil;
    NSMutableDictionary *d = _filtered[(NSUInteger)indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:WQLocalized(@"Delete")
                                                                    handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        [self->_items removeObject:d];
        [self saveList];
        [self applyFilter:self->_search.searchBar.text];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *__unused)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint __unused)point
{
    if (!_filtered.count) return nil;
    NSMutableDictionary *d = _filtered[(NSUInteger)indexPath.row];
    NSString *u = d[@"url"] ?: @"";
    NSInteger fullIdx = (NSInteger)[_items indexOfObject:d];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        return [UIMenu menuWithTitle:@"" children:@[
            [UIAction actionWithTitle:WQLocalized(@"Open in New Tab") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf dismissViewControllerAnimated:YES completion:^{
                    WQBrowserBookmarksViewController *me = weakSelf;
                    if (me && me->_onOpenURL && u.length) me->_onOpenURL(u, YES);
                }];
            }],
            [UIAction actionWithTitle:WQLocalized(@"Edit") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf promptAddOrEditIndex:fullIdx];
            }],
            [UIAction actionWithTitle:WQLocalized(@"Copy URL") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
                UIPasteboard.generalPasteboard.string = u;
            }],
        ]];
    }];
}

@end

#pragma mark - Visual Tab Grid Switcher (Up to 24 Tabs, Normal + Private)

@interface WQBrowserTabCardCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *previewImage;
@property (nonatomic, strong) UIImageView *badgeIcon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hostLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@end

@implementation WQBrowserTabCardCell
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.contentView.layer.cornerRadius = 18;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.clipsToBounds = YES;
        self.contentView.backgroundColor = [wq_theme_glass_tint() colorWithAlphaComponent:0.55];
        self.contentView.layer.borderWidth = 1.0;
        self.contentView.layer.borderColor = wq_theme_rim().CGColor;

        _badgeIcon = [UIImageView new];
        _badgeIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeIcon.contentMode = UIViewContentModeScaleAspectFit;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        _titleLabel.textColor = wq_theme_primary_text();

        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [_closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        _closeBtn.tintColor = wq_theme_secondary_text();
        [_closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];

        _previewImage = [UIImageView new];
        _previewImage.translatesAutoresizingMaskIntoConstraints = NO;
        _previewImage.contentMode = UIViewContentModeScaleAspectFill;
        _previewImage.clipsToBounds = YES;
        _previewImage.backgroundColor = [wq_theme_canvas_bottom() colorWithAlphaComponent:0.7];

        _hostLabel = [UILabel new];
        _hostLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _hostLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightMedium];
        _hostLabel.textColor = wq_theme_secondary_text();

        [self.contentView addSubview:_badgeIcon];
        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_closeBtn];
        [self.contentView addSubview:_previewImage];
        [self.contentView addSubview:_hostLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_badgeIcon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_badgeIcon.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_badgeIcon.widthAnchor constraintEqualToConstant:16],
            [_badgeIcon.heightAnchor constraintEqualToConstant:16],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_badgeIcon.trailingAnchor constant:6],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:_badgeIcon.centerYAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_closeBtn.leadingAnchor constant:-4],

            [_closeBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
            [_closeBtn.centerYAnchor constraintEqualToAnchor:_badgeIcon.centerYAnchor],
            [_closeBtn.widthAnchor constraintEqualToConstant:28],
            [_closeBtn.heightAnchor constraintEqualToConstant:28],

            [_previewImage.topAnchor constraintEqualToAnchor:_badgeIcon.bottomAnchor constant:8],
            [_previewImage.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [_previewImage.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [_previewImage.bottomAnchor constraintEqualToAnchor:_hostLabel.topAnchor constant:-6],

            [_hostLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_hostLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_hostLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
    }
    return self;
}
- (void)closeTapped
{
    if (_onClose) _onClose();
}
@end

@interface WQBrowserTabGridViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, copy) void (^onSelectTab)(NSInteger index);
@property (nonatomic, copy) void (^onCloseTab)(NSInteger index);
@property (nonatomic, copy) void (^onNewTab)(BOOL incognito);
@property (nonatomic, copy) void (^onReopenClosed)(void);
@property (nonatomic, copy) void (^onCloseAll)(BOOL incognito);
@property (nonatomic) BOOL hasClosedHistory;
- (instancetype)initWithTabs:(NSArray<WQBrowserTab *> *)tabs activeIndex:(NSInteger)activeIndex;
@end

@implementation WQBrowserTabGridViewController {
    NSArray<WQBrowserTab *> *_allTabs;
    NSInteger _activeIndex;
    BOOL _showingPrivate;
    UISegmentedControl *_modeSeg;
    UICollectionView *_cv;
}

- (instancetype)initWithTabs:(NSArray<WQBrowserTab *> *)tabs activeIndex:(NSInteger)activeIndex
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _allTabs = [tabs copy];
        _activeIndex = activeIndex;
        if (activeIndex >= 0 && (NSUInteger)activeIndex < _allTabs.count) {
            _showingPrivate = _allTabs[(NSUInteger)activeIndex].incognito;
        }
        self.title = WQLocalized(@"Tabs");
    }
    return self;
}

- (NSArray<NSNumber *> *)visibleTabIndices
{
    NSMutableArray<NSNumber *> *idx = [NSMutableArray new];
    for (NSUInteger i = 0; i < _allTabs.count; i++) {
        if (_allTabs[i].incognito == _showingPrivate) [idx addObject:@((NSInteger)i)];
    }
    return idx;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    __weak typeof(self) weakSelf = self;

    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[WQLocalized(@"Normal"), WQLocalized(@"Private")]];
    _modeSeg.selectedSegmentIndex = _showingPrivate ? 1 : 0;
    [_modeSeg addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _modeSeg;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Done") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    if (_hasClosedHistory) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Reopen") image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf dismissViewControllerAnimated:YES completion:^{
                if (weakSelf && weakSelf.onReopenClosed) weakSelf.onReopenClosed();
            }];
        }]];
    }

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(12, 14, 12, 14);

    _cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _cv.translatesAutoresizingMaskIntoConstraints = NO;
    _cv.backgroundColor = UIColor.clearColor;
    _cv.dataSource = self;
    _cv.delegate = self;
    [_cv registerClass:WQBrowserTabCardCell.class forCellWithReuseIdentifier:@"tab-card"];

    UIVisualEffectView *bar = wq_theme_make_glass_card(20.0, YES);
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *newBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [newBtn setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    [newBtn setTitle:[@" " stringByAppendingString:WQLocalized(@"New Tab")] forState:UIControlStateNormal];
    newBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    newBtn.tintColor = wq_theme_aurora_teal();
    [newBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        WQBrowserTabGridViewController *me = weakSelf;
        BOOL priv = me ? me->_showingPrivate : NO;
        [me dismissViewControllerAnimated:YES completion:^{
            if (me && me.onNewTab) me.onNewTab(priv);
        }];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *closeAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeAllBtn setTitle:WQLocalized(@"Close All") forState:UIControlStateNormal];
    closeAllBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    closeAllBtn.tintColor = UIColor.systemRedColor;
    [closeAllBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        WQBrowserTabGridViewController *me = weakSelf;
        BOOL priv = me ? me->_showingPrivate : NO;
        [me dismissViewControllerAnimated:YES completion:^{
            if (me && me.onCloseAll) me.onCloseAll(priv);
        }];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[closeAllBtn, [UIView new], newBtn]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    [bar.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-16],
    ]];

    [self.view addSubview:_cv];
    [self.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [_cv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_cv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_cv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_cv.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-8],

        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [bar.heightAnchor constraintEqualToConstant:48],
    ]];
}

- (void)modeChanged
{
    _showingPrivate = (_modeSeg.selectedSegmentIndex == 1);
    [_cv reloadData];
}

- (void)refreshTabs:(NSArray<WQBrowserTab *> *)tabs activeIndex:(NSInteger)activeIndex
{
    _allTabs = [tabs copy];
    _activeIndex = activeIndex;
    [_cv reloadData];
}

- (NSInteger)collectionView:(UICollectionView *__unused)collectionView numberOfItemsInSection:(NSInteger __unused)section
{
    return (NSInteger)[self visibleTabIndices].count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *__unused)layout sizeForItemAtIndexPath:(NSIndexPath *__unused)indexPath
{
    CGFloat w = floor((CGRectGetWidth(collectionView.bounds) - 40.0) / 2.0);
    return CGSizeMake(MAX(140.0, w), 196.0);
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    WQBrowserTabCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"tab-card" forIndexPath:indexPath];
    NSArray<NSNumber *> *indices = [self visibleTabIndices];
    NSInteger realIndex = indices[(NSUInteger)indexPath.item].integerValue;
    WQBrowserTab *tab = _allTabs[(NSUInteger)realIndex];

    cell.titleLabel.text = tab.pageTitle.length ? tab.pageTitle : WQLocalized(@"New Tab");
    NSURL *u = tab.savedURLString.length ? [NSURL URLWithString:tab.savedURLString] : tab.webView.URL;
    cell.hostLabel.text = tab.isNewTab ? WQLocalized(@"Start Page") : (u.host ?: tab.savedURLString ?: @"about:blank");
    cell.badgeIcon.image = [UIImage systemImageNamed:tab.incognito ? @"eye.slash.fill" : (tab.isNewTab ? @"sparkles" : @"globe")];
    cell.badgeIcon.tintColor = tab.incognito ? UIColor.systemIndigoColor : wq_theme_aurora_teal();
    cell.previewImage.image = tab.snapshot;
    BOOL isActive = (realIndex == _activeIndex);
    cell.contentView.layer.borderWidth = isActive ? 2.0 : 0.8;
    cell.contentView.layer.borderColor = isActive
        ? (tab.incognito ? UIColor.systemIndigoColor : wq_theme_aurora_teal()).CGColor
        : wq_theme_rim().CGColor;

    __weak typeof(self) weakSelf = self;
    cell.onClose = ^{
        if (weakSelf && weakSelf.onCloseTab) weakSelf.onCloseTab(realIndex);
    };
    return cell;
}

- (void)collectionView:(UICollectionView *__unused)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<NSNumber *> *indices = [self visibleTabIndices];
    NSInteger realIndex = indices[(NSUInteger)indexPath.item].integerValue;
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        if (weakSelf && weakSelf.onSelectTab) weakSelf.onSelectTab(realIndex);
    }];
}

@end

#pragma mark - Reader Mode Sheet View Controller

@interface WQBrowserReaderViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title urlString:(NSString *)urlString bodyText:(NSString *)bodyText;
@end

@implementation WQBrowserReaderViewController {
    NSString *_articleTitle;
    NSString *_urlString;
    NSString *_bodyText;
    UITextView *_textView;
    CGFloat _fontSize;
    NSInteger _themeMode; // 0 = Match App, 1 = Warm Paper, 2 = Pure Dark
}

- (instancetype)initWithTitle:(NSString *)title urlString:(NSString *)urlString bodyText:(NSString *)bodyText
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _articleTitle = [title copy] ?: @"Reader";
        _urlString = [urlString copy] ?: @"";
        _bodyText = [bodyText copy] ?: @"";
        _fontSize = 17.0;
        _themeMode = 0;
        self.title = WQLocalized(@"Reader Mode");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];
    UIBarButtonItem *dec = [[UIBarButtonItem alloc] initWithTitle:@"A-" style:UIBarButtonItemStylePlain target:self action:@selector(smallerFont)];
    UIBarButtonItem *inc = [[UIBarButtonItem alloc] initWithTitle:@"A+" style:UIBarButtonItemStylePlain target:self action:@selector(largerFont)];
    UIBarButtonItem *thm = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"circle.lefthalf.filled"] style:UIBarButtonItemStylePlain target:self action:@selector(cycleTheme)];
    self.navigationItem.rightBarButtonItems = @[thm, inc, dec];

    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.textContainerInset = UIEdgeInsetsMake(20, 18, 28, 18);
    _textView.backgroundColor = UIColor.clearColor;
    [self.view addSubview:_textView];
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [self refreshStyle];
}

- (void)smallerFont { _fontSize = MAX(13.0, _fontSize - 2.0); [self refreshStyle]; }
- (void)largerFont  { _fontSize = MIN(28.0, _fontSize + 2.0); [self refreshStyle]; }
- (void)cycleTheme  { _themeMode = (_themeMode + 1) % 3; [self refreshStyle]; }

- (void)refreshStyle
{
    UIColor *bg = UIColor.clearColor;
    UIColor *fg = wq_theme_primary_text();
    UIColor *sec = wq_theme_secondary_text();
    if (_themeMode == 1) {
        bg = [UIColor colorWithRed:0.965 green:0.941 blue:0.882 alpha:1.0];
        fg = [UIColor colorWithRed:0.16 green:0.12 blue:0.08 alpha:1.0];
        sec = [UIColor colorWithRed:0.42 green:0.35 blue:0.26 alpha:1.0];
    } else if (_themeMode == 2) {
        bg = [UIColor colorWithWhite:0.05 alpha:1.0];
        fg = [UIColor colorWithWhite:0.92 alpha:1.0];
        sec = [UIColor colorWithWhite:0.60 alpha:1.0];
    }
    _textView.backgroundColor = bg;

    NSMutableAttributedString *attr = [NSMutableAttributedString new];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", _articleTitle]
        attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:_fontSize + 7 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: fg,
        }]];
    if (_urlString.length) {
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n\n", _urlString]
            attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: sec,
            }]];
    }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineSpacing = 6.0;
    ps.paragraphSpacing = 12.0;
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:_bodyText
        attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:_fontSize weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: fg,
            NSParagraphStyleAttributeName: ps,
        }]];
    _textView.attributedText = attr;
}

@end

#pragma mark - WQDownloadBrowserViewController

@interface WQDownloadBrowserViewController () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UITextFieldDelegate, UIScrollViewDelegate, UITableViewDataSource, UITableViewDelegate>
@end

@implementation WQDownloadBrowserViewController {
    NSString *_initialURL;
    NSMutableArray<WQBrowserTab *> *_tabs;
    NSMutableArray<NSDictionary *> *_closedTabHistory;
    NSMutableSet<NSString *> *_httpFallbackHosts;
    NSInteger _activeIndex;

    WKContentRuleList *_activeRuleList;

    UIVisualEffectView *_topBar;
    NSLayoutConstraint *_topBarHeightConstraint;
    UIImageView *_lockView;
    UIButton *_shieldBtn;
    UITextField *_urlField;
    UIButton *_starBtn;
    UIButton *_reloadBtn;
    UIProgressView *_progressView;

    UIView *_webContainer;
    UIScrollView *_startPageScroll;
    UIView *_startPageContainer;
    UILabel *_statsAdsLabel;
    UILabel *_statsPopupsLabel;
    UILabel *_statsDataLabel;
    UIButton *_startEngineBtn;
    UIStackView *_speedDialStack;
    UIStackView *_startBookmarksStack;

    UIVisualEffectView *_autocompleteCard;
    UITableView *_autocompleteTable;
    NSArray<NSDictionary *> *_autocompleteItems;

    UIVisualEffectView *_findBar;
    UITextField *_findField;
    UILabel *_findCountLabel;

    UIVisualEffectView *_botBar;
    NSLayoutConstraint *_botBarBottomConstraint;
    UIButton *_backBtn;
    UIButton *_fwdBtn;
    UIButton *_mediaBtn;
    UIButton *_tabsBtn;
    UIButton *_dlBtn;
    UIButton *_menuBtn;

    CGFloat _lastScrollY;
    BOOL _chromeHidden;
    __weak WQBrowserTabGridViewController *_presentedTabGrid;
}

- (instancetype)initWithInitialURL:(NSString *)urlString
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _initialURL = [urlString copy];
        _tabs = [NSMutableArray new];
        _closedTabHistory = [NSMutableArray new];
        _httpFallbackHosts = [NSMutableSet new];
        _activeIndex = 0;
        self.title = WQLocalized(@"Brave Privacy Browser");
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)dealloc
{
    for (WQBrowserTab *t in _tabs) {
        [self detachWebViewFromTab:t];
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (wq_shields_pref_bool(kWQBrowserClearOnExitPref, NO)) {
        NSSet<NSString *> *allTypes = [WKWebsiteDataStore allWebsiteDataTypes];
        [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:allTypes modifiedSince:NSDate.distantPast completionHandler:^{}];
    }
}

- (void)detachWebViewFromTab:(WQBrowserTab *)t
{
    if (!t.webView) return;
    t.webView.scrollView.delegate = nil;
    @try {
        [t.webView removeObserver:self forKeyPath:@"estimatedProgress"];
        [t.webView removeObserver:self forKeyPath:@"title"];
    } @catch (NSException *__unused e) {}
    [t.webView.configuration.userContentController removeScriptMessageHandlerForName:@"wqMediaSniff"];
    [t.webView.configuration.userContentController removeScriptMessageHandlerForName:@"wqShieldEvent"];
    t.webView = nil;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    [self buildChrome];
    [self buildStartPageDashboard];
    [self buildAutocompleteOverlay];
    [self buildFindBar];
    [self rebuildMoreMenu];
    [self compileShieldsAndOpenFirstTab];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateDownloadsBadge) name:WQDownloadManagerDidUpdateNotification object:nil];
    [self updateDownloadsBadge];
}

#pragma mark Chrome & Overlays

- (void)buildChrome
{
    _topBar = wq_theme_make_glass_card(18.0, YES);
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;

    _lockView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    _lockView.translatesAutoresizingMaskIntoConstraints = NO;
    _lockView.contentMode = UIViewContentModeScaleAspectFit;
    _lockView.tintColor = wq_theme_aurora_teal();

    _shieldBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _shieldBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *scfg = [UIButtonConfiguration tintedButtonConfiguration];
    scfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    scfg.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
    scfg.title = @"0";
    scfg.imagePadding = 3;
    scfg.contentInsets = NSDirectionalEdgeInsetsMake(3, 7, 3, 7);
    scfg.baseForegroundColor = wq_theme_aurora_teal();
    scfg.baseBackgroundColor = wq_theme_aurora_teal();
    scfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *inAttr) {
        NSMutableDictionary *d = [inAttr mutableCopy] ?: [NSMutableDictionary new];
        d[NSFontAttributeName] = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
        return d;
    };
    _shieldBtn.configuration = scfg;
    [_shieldBtn addTarget:self action:@selector(openShieldsPanel) forControlEvents:UIControlEventTouchUpInside];

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
    [_urlField addTarget:self action:@selector(urlFieldChanged) forControlEvents:UIControlEventEditingChanged];

    _starBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _starBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_starBtn setImage:[UIImage systemImageNamed:@"star"] forState:UIControlStateNormal];
    _starBtn.tintColor = wq_theme_secondary_text();
    [_starBtn addTarget:self action:@selector(toggleCurrentBookmark) forControlEvents:UIControlEventTouchUpInside];

    _reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _reloadBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_reloadBtn setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    _reloadBtn.tintColor = wq_theme_accent();
    [_reloadBtn addTarget:self action:@selector(reloadTapped) forControlEvents:UIControlEventTouchUpInside];

    [_topBar.contentView addSubview:_lockView];
    [_topBar.contentView addSubview:_shieldBtn];
    [_topBar.contentView addSubview:_urlField];
    [_topBar.contentView addSubview:_starBtn];
    [_topBar.contentView addSubview:_reloadBtn];

    [_lockView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_shieldBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_starBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_reloadBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_urlField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [_shieldBtn.leadingAnchor constraintEqualToAnchor:_topBar.contentView.leadingAnchor constant:7],
        [_shieldBtn.centerYAnchor constraintEqualToAnchor:_topBar.contentView.centerYAnchor],

        [_lockView.leadingAnchor constraintEqualToAnchor:_shieldBtn.trailingAnchor constant:6],
        [_lockView.centerYAnchor constraintEqualToAnchor:_topBar.contentView.centerYAnchor],
        [_lockView.widthAnchor constraintEqualToConstant:14],
        [_lockView.heightAnchor constraintEqualToConstant:14],

        [_urlField.leadingAnchor constraintEqualToAnchor:_lockView.trailingAnchor constant:6],
        [_urlField.topAnchor constraintEqualToAnchor:_topBar.contentView.topAnchor constant:4],
        [_urlField.bottomAnchor constraintEqualToAnchor:_topBar.contentView.bottomAnchor constant:-4],

        [_starBtn.leadingAnchor constraintEqualToAnchor:_urlField.trailingAnchor constant:4],
        [_starBtn.centerYAnchor constraintEqualToAnchor:_topBar.contentView.centerYAnchor],
        [_starBtn.widthAnchor constraintEqualToConstant:28],

        [_reloadBtn.leadingAnchor constraintEqualToAnchor:_starBtn.trailingAnchor constant:2],
        [_reloadBtn.trailingAnchor constraintEqualToAnchor:_topBar.contentView.trailingAnchor constant:-7],
        [_reloadBtn.centerYAnchor constraintEqualToAnchor:_topBar.contentView.centerYAnchor],
        [_reloadBtn.widthAnchor constraintEqualToConstant:28],
    ]];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.progressTintColor = wq_theme_aurora_teal();
    _progressView.trackTintColor = UIColor.clearColor;
    _progressView.hidden = YES;

    _webContainer = [UIView new];
    _webContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _webContainer.backgroundColor = UIColor.clearColor;

    _botBar = wq_theme_make_glass_card(20.0, YES);
    _botBar.translatesAutoresizingMaskIntoConstraints = NO;

    _backBtn = [self makeBarBtn:@"chevron.backward" action:@selector(goBackTapped)];
    _fwdBtn = [self makeBarBtn:@"chevron.forward" action:@selector(goFwdTapped)];
    _mediaBtn = [self makeBarBtn:@"arrow.down.circle.fill" action:@selector(openMediaGrabber)];
    [_mediaBtn setTitle:@" 0" forState:UIControlStateNormal];
    _mediaBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    _tabsBtn = [self makeBarBtn:@"square.on.square" action:@selector(openTabsSheet)];
    [_tabsBtn setTitle:@" 1" forState:UIControlStateNormal];
    _tabsBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    _dlBtn = [self makeBarBtn:@"tray.and.arrow.down.fill" action:@selector(openDownloadManager)];
    _dlBtn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];

    _menuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_menuBtn setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    _menuBtn.tintColor = wq_theme_primary_text();
    _menuBtn.showsMenuAsPrimaryAction = YES;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_backBtn, _fwdBtn, _mediaBtn, _tabsBtn, _dlBtn, _menuBtn]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    [_botBar.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:_botBar.contentView.topAnchor constant:4],
        [row.bottomAnchor constraintEqualToAnchor:_botBar.contentView.bottomAnchor constant:-4],
        [row.leadingAnchor constraintEqualToAnchor:_botBar.contentView.leadingAnchor constant:6],
        [row.trailingAnchor constraintEqualToAnchor:_botBar.contentView.trailingAnchor constant:-6],
    ]];

    [self.view addSubview:_topBar];
    [self.view addSubview:_progressView];
    [self.view addSubview:_webContainer];
    [self.view addSubview:_botBar];

    _topBarHeightConstraint = [_topBar.heightAnchor constraintEqualToConstant:44];
    _botBarBottomConstraint = [_botBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-4];

    [NSLayoutConstraint activateConstraints:@[
        [_topBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        _topBarHeightConstraint,

        [_progressView.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor constant:2],
        [_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_progressView.heightAnchor constraintEqualToConstant:2],

        [_webContainer.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor],
        [_webContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_webContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_webContainer.bottomAnchor constraintEqualToAnchor:_botBar.topAnchor constant:-6],

        [_botBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [_botBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        _botBarBottomConstraint,
        [_botBar.heightAnchor constraintEqualToConstant:48],
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

- (void)buildStartPageDashboard
{
    _startPageContainer = [UIView new];
    _startPageContainer.frame = _webContainer.bounds;
    _startPageContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _startPageScroll = [UIScrollView new];
    _startPageScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _startPageScroll.alwaysBounceVertical = YES;
    [_startPageContainer addSubview:_startPageScroll];

    UIStackView *root = [UIStackView new];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 14;
    [_startPageScroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [_startPageScroll.topAnchor constraintEqualToAnchor:_startPageContainer.topAnchor],
        [_startPageScroll.bottomAnchor constraintEqualToAnchor:_startPageContainer.bottomAnchor],
        [_startPageScroll.leadingAnchor constraintEqualToAnchor:_startPageContainer.leadingAnchor],
        [_startPageScroll.trailingAnchor constraintEqualToAnchor:_startPageContainer.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:_startPageScroll.contentLayoutGuide.topAnchor constant:16],
        [root.bottomAnchor constraintEqualToAnchor:_startPageScroll.contentLayoutGuide.bottomAnchor constant:-24],
        [root.leadingAnchor constraintEqualToAnchor:_startPageScroll.contentLayoutGuide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:_startPageScroll.contentLayoutGuide.trailingAnchor constant:-16],
        [root.widthAnchor constraintEqualToAnchor:_startPageScroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // 1. Search Engine Selector + Hero Prompt Card
    UIVisualEffectView *heroCard = wq_theme_make_glass_card(22.0, YES);
    _startEngineBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _startEngineBtn.showsMenuAsPrimaryAction = YES;

    UIButton *searchBarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *sbCfg = wq_theme_secondary_button_configuration();
    sbCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    sbCfg.image = [UIImage systemImageNamed:@"magnifyingglass"];
    sbCfg.imagePadding = 8;
    sbCfg.title = WQLocalized(@"Search the web privately or enter URL…");
    sbCfg.contentInsets = NSDirectionalEdgeInsetsMake(11, 14, 11, 14);
    searchBarBtn.configuration = sbCfg;
    searchBarBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    __weak typeof(self) weakSelf = self;
    [searchBarBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (me) [me->_urlField becomeFirstResponder];
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *heroStack = [[UIStackView alloc] initWithArrangedSubviews:@[_startEngineBtn, searchBarBtn]];
    heroStack.translatesAutoresizingMaskIntoConstraints = NO;
    heroStack.axis = UILayoutConstraintAxisVertical;
    heroStack.spacing = 10;
    [heroCard.contentView addSubview:heroStack];
    [NSLayoutConstraint activateConstraints:@[
        [heroStack.topAnchor constraintEqualToAnchor:heroCard.contentView.topAnchor constant:14],
        [heroStack.bottomAnchor constraintEqualToAnchor:heroCard.contentView.bottomAnchor constant:-14],
        [heroStack.leadingAnchor constraintEqualToAnchor:heroCard.contentView.leadingAnchor constant:14],
        [heroStack.trailingAnchor constraintEqualToAnchor:heroCard.contentView.trailingAnchor constant:-14],
    ]];
    [root addArrangedSubview:heroCard];

    // 2. Brave Shields Telemetry Card
    UIVisualEffectView *statsCard = wq_theme_make_glass_card(22.0, NO);
    UILabel *statsHdr = [UILabel new];
    statsHdr.text = WQLocalized(@"Brave Shields Privacy Stats");
    statsHdr.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    statsHdr.textColor = wq_theme_primary_text();

    _statsAdsLabel = [UILabel new];
    _statsPopupsLabel = [UILabel new];
    _statsDataLabel = [UILabel new];
    UIView *(^statTile)(UILabel *, NSString *, UIColor *) = ^UIView *(UILabel *valLbl, NSString *cap, UIColor *col) {
        valLbl.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightHeavy];
        valLbl.textColor = col;
        UILabel *cLbl = [UILabel new];
        cLbl.text = cap;
        cLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        cLbl.textColor = wq_theme_secondary_text();
        cLbl.numberOfLines = 2;
        UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[valLbl, cLbl]];
        s.axis = UILayoutConstraintAxisVertical;
        s.spacing = 2;
        return s;
    };
    UIStackView *statRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        statTile(_statsAdsLabel, WQLocalized(@"Trackers & Ads Blocked"), wq_theme_aurora_teal()),
        statTile(_statsPopupsLabel, WQLocalized(@"Popups Stopped"), wq_theme_accent()),
        statTile(_statsDataLabel, WQLocalized(@"Data Saved"), UIColor.systemGreenColor),
    ]];
    statRow.axis = UILayoutConstraintAxisHorizontal;
    statRow.distribution = UIStackViewDistributionFillEqually;
    statRow.spacing = 8;

    UIStackView *statsStack = [[UIStackView alloc] initWithArrangedSubviews:@[statsHdr, statRow]];
    statsStack.translatesAutoresizingMaskIntoConstraints = NO;
    statsStack.axis = UILayoutConstraintAxisVertical;
    statsStack.spacing = 10;
    [statsCard.contentView addSubview:statsStack];
    [NSLayoutConstraint activateConstraints:@[
        [statsStack.topAnchor constraintEqualToAnchor:statsCard.contentView.topAnchor constant:14],
        [statsStack.bottomAnchor constraintEqualToAnchor:statsCard.contentView.bottomAnchor constant:-14],
        [statsStack.leadingAnchor constraintEqualToAnchor:statsCard.contentView.leadingAnchor constant:14],
        [statsStack.trailingAnchor constraintEqualToAnchor:statsCard.contentView.trailingAnchor constant:-14],
    ]];
    [root addArrangedSubview:statsCard];

    // 3. Speed Dial Top Sites
    UILabel *sdHdr = [UILabel new];
    sdHdr.text = WQLocalized(@"Top Sites & Speed Dial");
    sdHdr.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    sdHdr.textColor = wq_theme_primary_text();
    [root addArrangedSubview:sdHdr];

    _speedDialStack = [UIStackView new];
    _speedDialStack.axis = UILayoutConstraintAxisVertical;
    _speedDialStack.spacing = 10;
    [root addArrangedSubview:_speedDialStack];

    // 4. Recent Bookmarks
    UILabel *bmHdr = [UILabel new];
    bmHdr.text = WQLocalized(@"Bookmarks");
    bmHdr.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    bmHdr.textColor = wq_theme_primary_text();
    [root addArrangedSubview:bmHdr];

    _startBookmarksStack = [UIStackView new];
    _startBookmarksStack.axis = UILayoutConstraintAxisVertical;
    _startBookmarksStack.spacing = 8;
    [root addArrangedSubview:_startBookmarksStack];

    [self refreshStartPageDashboard];
}

- (UIMenu *)buildSearchEngineMenu
{
    WQBrowserSearchEngineInfo *cur = wq_browser_active_search_engine();
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    for (WQBrowserSearchEngineInfo *eng in wq_browser_search_engines()) {
        UIAction *act = [UIAction actionWithTitle:WQLocalized(eng.name)
                                            image:[UIImage systemImageNamed:eng.symbolName]
                                       identifier:nil
                                          handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setObject:eng.engineID forKey:kWQBrowserSearchEnginePref];
            if ([eng.engineID isEqualToString:@"custom"]) {
                [weakSelf promptCustomSearchURL];
            } else {
                [weakSelf refreshStartPageDashboard];
                [weakSelf rebuildMoreMenu];
                wq_haptic_selection();
            }
        }];
        if ([eng.engineID isEqualToString:cur.engineID]) act.state = UIMenuElementStateOn;
        [items addObject:act];
    }
    return [UIMenu menuWithTitle:WQLocalized(@"Search Engine") children:items];
}

- (void)promptCustomSearchURL
{
    UIAlertController *ac = wq_alert_controller(WQLocalized(@"Custom Search Engine"),
                                                WQLocalized(@"Enter a search URL template containing %s where the query goes."),
                                                UIAlertControllerStyleAlert);
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://search.brave.com/search?q=%s";
        tf.text = [NSUserDefaults.standardUserDefaults stringForKey:kWQBrowserCustomSearchPref] ?: @"https://search.brave.com/search?q=%s";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.keyboardType = UIKeyboardTypeURL;
    }];
    [ac addAction:wq_alert_action(WQLocalized(@"Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *u = [ac.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (u.length) {
            [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:kWQBrowserSearchEnginePref];
            [NSUserDefaults.standardUserDefaults setObject:u forKey:kWQBrowserCustomSearchPref];
            [self refreshStartPageDashboard];
            [self rebuildMoreMenu];
        }
    })];
    [ac addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)refreshStartPageDashboard
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger ads = [ud integerForKey:kWQBrowserStatsAdsPref] + [ud integerForKey:kWQBrowserStatsTrackersPref];
    NSInteger pops = [ud integerForKey:kWQBrowserStatsPopupsPref];
    unsigned long long bytes = (unsigned long long)[[ud objectForKey:kWQBrowserStatsBytesPref] unsignedLongLongValue];
    _statsAdsLabel.text = [NSString stringWithFormat:@"%ld", (long)ads];
    _statsPopupsLabel.text = [NSString stringWithFormat:@"%ld", (long)pops];
    _statsDataLabel.text = wq_size_text(bytes);

    WQBrowserSearchEngineInfo *eng = wq_browser_active_search_engine();
    UIButtonConfiguration *ecfg = [UIButtonConfiguration tintedButtonConfiguration];
    ecfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    ecfg.image = [UIImage systemImageNamed:eng.symbolName];
    ecfg.title = [NSString stringWithFormat:@"%@: %@", WQLocalized(@"Search Engine"), WQLocalized(eng.name)];
    ecfg.imagePadding = 6;
    ecfg.baseForegroundColor = wq_theme_aurora_teal();
    ecfg.baseBackgroundColor = wq_theme_aurora_teal();
    _startEngineBtn.configuration = ecfg;
    _startEngineBtn.menu = [self buildSearchEngineMenu];

    // Speed Dial grid (4 columns)
    for (UIView *v in _speedDialStack.arrangedSubviews) {
        [_speedDialStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<NSDictionary<NSString *, NSString *> *> *sites = wq_browser_top_sites_list();
    NSMutableArray<UIButton *> *tiles = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < sites.count; i++) {
        NSDictionary *site = sites[i];
        NSString *u = site[@"url"] ?: @"";
        NSString *t = site[@"title"] ?: u;
        UIButtonConfiguration *cfg = wq_theme_secondary_button_configuration();
        cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        cfg.title = t;
        cfg.image = [UIImage systemImageNamed:@"globe"];
        cfg.imagePlacement = NSDirectionalRectEdgeTop;
        cfg.imagePadding = 5;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 4, 10, 4);
        cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *inAttr) {
            NSMutableDictionary *d = [inAttr mutableCopy] ?: [NSMutableDictionary new];
            d[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            return d;
        };
        UIButton *btn = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [weakSelf loadUserInput:u];
        }]];
        btn.tintColor = wq_theme_accent();
        btn.menu = [UIMenu menuWithTitle:t children:@[
            [UIAction actionWithTitle:WQLocalized(@"Open in New Tab") image:[UIImage systemImageNamed:@"plus.square"] identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openNewTabWithURL:u incognito:NO switchToTab:YES];
            }],
            [UIAction actionWithTitle:WQLocalized(@"Open in Private Tab") image:[UIImage systemImageNamed:@"eye.slash"] identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openNewTabWithURL:u incognito:YES switchToTab:YES];
            }],
            [UIAction actionWithTitle:WQLocalized(@"Remove") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *__unused a) {
                NSMutableArray *mut = [wq_browser_top_sites_list() mutableCopy];
                if (i < mut.count) {
                    [mut removeObjectAtIndex:i];
                    [NSUserDefaults.standardUserDefaults setObject:mut forKey:kWQBrowserTopSitesPref];
                    [weakSelf refreshStartPageDashboard];
                }
            }],
        ]];
        [tiles addObject:btn];
    }
    // Add "+ Shortcut" button
    UIButtonConfiguration *addCfg = wq_theme_secondary_button_configuration();
    addCfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    addCfg.title = WQLocalized(@"Add");
    addCfg.image = [UIImage systemImageNamed:@"plus.circle.fill"];
    addCfg.imagePlacement = NSDirectionalRectEdgeTop;
    addCfg.imagePadding = 5;
    addCfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 4, 10, 4);
    UIButton *addTile = [UIButton buttonWithConfiguration:addCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf promptAddSpeedDialSite];
    }]];
    addTile.tintColor = wq_theme_aurora_teal();
    [tiles addObject:addTile];

    for (NSUInteger i = 0; i < tiles.count; i += 4) {
        UIStackView *r = [UIStackView new];
        r.axis = UILayoutConstraintAxisHorizontal;
        r.distribution = UIStackViewDistributionFillEqually;
        r.spacing = 8;
        for (NSUInteger j = 0; j < 4; j++) {
            if (i + j < tiles.count) [r addArrangedSubview:tiles[i + j]];
            else [r addArrangedSubview:[UIView new]];
        }
        [_speedDialStack addArrangedSubview:r];
    }

    // Recent bookmarks quick chips
    for (UIView *v in _startBookmarksStack.arrangedSubviews) {
        [_startBookmarksStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray *bms = wq_browser_bookmarks_list();
    NSUInteger bmCap = MIN((NSUInteger)6, bms.count);
    for (NSUInteger i = 0; i < bmCap; i++) {
        NSDictionary *bm = bms[i];
        UIButtonConfiguration *bcfg = wq_theme_secondary_button_configuration();
        bcfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        bcfg.title = bm[@"title"] ?: bm[@"url"];
        bcfg.image = [UIImage systemImageNamed:@"star.fill"];
        bcfg.imagePadding = 8;
        bcfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
        UIButton *b = [UIButton buttonWithConfiguration:bcfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [weakSelf loadUserInput:bm[@"url"] ?: @""];
        }]];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        b.tintColor = UIColor.systemYellowColor;
        [_startBookmarksStack addArrangedSubview:b];
    }
}

- (void)promptAddSpeedDialSite
{
    UIAlertController *ac = wq_alert_controller(WQLocalized(@"Add Top Site"), nil, UIAlertControllerStyleAlert);
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = WQLocalized(@"Title"); }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:wq_alert_action(WQLocalized(@"Add"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *t = [ac.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *u = [ac.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!u.length) return;
        if (![u hasPrefix:@"http://"] && ![u hasPrefix:@"https://"]) u = [@"https://" stringByAppendingString:u];
        NSMutableArray *mut = [wq_browser_top_sites_list() mutableCopy];
        [mut addObject:@{ @"title": t.length ? t : u, @"url": u }];
        [NSUserDefaults.standardUserDefaults setObject:mut forKey:kWQBrowserTopSitesPref];
        [self refreshStartPageDashboard];
    })];
    [ac addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Autocomplete Overlay & Find in Page Bar

- (void)buildAutocompleteOverlay
{
    _autocompleteCard = wq_theme_make_glass_card(18.0, YES);
    _autocompleteCard.translatesAutoresizingMaskIntoConstraints = NO;
    _autocompleteCard.hidden = YES;

    _autocompleteTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _autocompleteTable.translatesAutoresizingMaskIntoConstraints = NO;
    _autocompleteTable.backgroundColor = UIColor.clearColor;
    _autocompleteTable.dataSource = self;
    _autocompleteTable.delegate = self;
    _autocompleteTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_autocompleteCard.contentView addSubview:_autocompleteTable];

    [self.view addSubview:_autocompleteCard];
    [NSLayoutConstraint activateConstraints:@[
        [_autocompleteCard.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor constant:6],
        [_autocompleteCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_autocompleteCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_autocompleteCard.heightAnchor constraintEqualToConstant:260],

        [_autocompleteTable.topAnchor constraintEqualToAnchor:_autocompleteCard.contentView.topAnchor],
        [_autocompleteTable.bottomAnchor constraintEqualToAnchor:_autocompleteCard.contentView.bottomAnchor],
        [_autocompleteTable.leadingAnchor constraintEqualToAnchor:_autocompleteCard.contentView.leadingAnchor],
        [_autocompleteTable.trailingAnchor constraintEqualToAnchor:_autocompleteCard.contentView.trailingAnchor],
    ]];
}

- (void)urlFieldChanged
{
    NSString *raw = [_urlField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!raw.length) {
        _autocompleteCard.hidden = YES;
        _autocompleteItems = @[];
        return;
    }
    NSString *needle = raw.lowercaseString;
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray new];
    WQBrowserSearchEngineInfo *eng = wq_browser_active_search_engine();
    [matches addObject:@{
        @"kind": @"search",
        @"title": WQLocalizedFormat(@"Search %@ for “%@”", WQLocalized(eng.name), raw),
        @"url": wq_browser_build_search_url(raw).absoluteString ?: @"",
    }];

    for (NSDictionary *bm in wq_browser_bookmarks_list()) {
        if (matches.count >= 8) break;
        if ([[bm[@"title"] lowercaseString] containsString:needle] || [[bm[@"url"] lowercaseString] containsString:needle]) {
            [matches addObject:@{ @"kind": @"bookmark", @"title": bm[@"title"] ?: @"", @"url": bm[@"url"] ?: @"" }];
        }
    }
    for (NSDictionary *h in [NSUserDefaults.standardUserDefaults arrayForKey:kWQBrowserHistoryPref]) {
        if (matches.count >= 8) break;
        if (![h isKindOfClass:NSDictionary.class]) continue;
        NSString *t = [h[@"title"] isKindOfClass:NSString.class] ? h[@"title"] : @"";
        NSString *u = [h[@"url"] isKindOfClass:NSString.class] ? h[@"url"] : @"";
        if ([[t lowercaseString] containsString:needle] || [[u lowercaseString] containsString:needle]) {
            [matches addObject:@{ @"kind": @"history", @"title": t.length ? t : u, @"url": u }];
        }
    }
    _autocompleteItems = matches;
    _autocompleteCard.hidden = NO;
    [self.view bringSubviewToFront:_autocompleteCard];
    [_autocompleteTable reloadData];
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return (NSInteger)_autocompleteItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ac-cell"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ac-cell"];
    cell.backgroundColor = UIColor.clearColor;
    NSDictionary *item = _autocompleteItems[(NSUInteger)indexPath.row];
    NSString *kind = item[@"kind"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = item[@"title"];
    c.secondaryText = [kind isEqualToString:@"search"] ? nil : item[@"url"];
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.textProperties.color = wq_theme_primary_text();
    NSString *sym = [kind isEqualToString:@"bookmark"] ? @"star.fill" : ([kind isEqualToString:@"history"] ? @"clock" : @"magnifyingglass");
    c.image = [UIImage systemImageNamed:sym];
    c.imageProperties.tintColor = [kind isEqualToString:@"bookmark"] ? UIColor.systemYellowColor : wq_theme_aurora_teal();
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _autocompleteItems[(NSUInteger)indexPath.row];
    NSString *u = item[@"url"];
    _autocompleteCard.hidden = YES;
    [_urlField resignFirstResponder];
    if (u.length) [self loadUserInput:u];
}

- (void)buildFindBar
{
    _findBar = wq_theme_make_glass_card(16.0, YES);
    _findBar.translatesAutoresizingMaskIntoConstraints = NO;
    _findBar.hidden = YES;

    _findField = [UITextField new];
    _findField.placeholder = WQLocalized(@"Find in page…");
    _findField.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _findField.textColor = wq_theme_primary_text();
    _findField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _findField.returnKeyType = UIReturnKeySearch;
    [_findField addTarget:self action:@selector(findTextChanged) forControlEvents:UIControlEventEditingChanged];

    _findCountLabel = [UILabel new];
    _findCountLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
    _findCountLabel.textColor = wq_theme_secondary_text();
    _findCountLabel.text = @"0/0";

    __weak typeof(self) weakSelf = self;
    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setImage:[UIImage systemImageNamed:@"chevron.up"] forState:UIControlStateNormal];
    [prev addAction:[UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf stepFind:-1]; }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    [next setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    [next addAction:[UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf stepFind:1]; }] forControlEvents:UIControlEventTouchUpInside];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    [done addAction:[UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf closeFindBar]; }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_findField, _findCountLabel, prev, next, done]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [_findField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_findCountLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_findBar.contentView addSubview:row];
    [self.view addSubview:_findBar];

    [NSLayoutConstraint activateConstraints:@[
        [_findBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_findBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_findBar.bottomAnchor constraintEqualToAnchor:_botBar.topAnchor constant:-8],
        [_findBar.heightAnchor constraintEqualToConstant:44],

        [row.topAnchor constraintEqualToAnchor:_findBar.contentView.topAnchor constant:4],
        [row.bottomAnchor constraintEqualToAnchor:_findBar.contentView.bottomAnchor constant:-4],
        [row.leadingAnchor constraintEqualToAnchor:_findBar.contentView.leadingAnchor constant:12],
        [row.trailingAnchor constraintEqualToAnchor:_findBar.contentView.trailingAnchor constant:-10],
    ]];
}

- (void)openFindInPage
{
    _findBar.hidden = NO;
    [self.view bringSubviewToFront:_findBar];
    [_findField becomeFirstResponder];
}

- (void)closeFindBar
{
    _findBar.hidden = YES;
    [_findField resignFirstResponder];
    _findField.text = @"";
    _findCountLabel.text = @"0/0";
    [self.activeTab.webView evaluateJavaScript:@"if(window.__wqFindClear) window.__wqFindClear();" completionHandler:nil];
}

- (void)findTextChanged
{
    NSString *q = _findField.text ?: @"";
    NSData *qd = [NSJSONSerialization dataWithJSONObject:@[q] options:0 error:nil];
    NSString *qJSON = qd ? [[NSString alloc] initWithData:qd encoding:NSUTF8StringEncoding] : @"[\"\"]";
    NSString *js = [NSString stringWithFormat:
        @"(function(q){"
        "window.__wqFindClear=function(){"
        "  document.querySelectorAll('mark.__wqMark').forEach(function(m){"
        "    var p=m.parentNode; if(p){ p.replaceChild(document.createTextNode(m.textContent), m); p.normalize(); }"
        "  });"
        "  window.__wqMarks=[]; window.__wqMarkIdx=0;"
        "};"
        "window.__wqFindClear();"
        "if(!q || q.length<1) return {total:0, idx:0};"
        "var ql=q.toLowerCase(), marks=[];"
        "function walk(n){"
        "  if(n.nodeType===3){"
        "    var idx=n.nodeValue.toLowerCase().indexOf(ql);"
        "    if(idx>=0 && marks.length<400){"
        "      var span=n.splitText(idx); var after=span.splitText(q.length);"
        "      var mk=document.createElement('mark'); mk.className='__wqMark';"
        "      mk.style.cssText='background:#ffd54f;color:#000;border-radius:3px;padding:0 2px;';"
        "      mk.appendChild(span.cloneNode(true)); span.parentNode.replaceChild(mk, span);"
        "      marks.push(mk); walk(after);"
        "    }"
        "  }else if(n.nodeType===1 && !/^(SCRIPT|STYLE|TEXTAREA|INPUT)$/.test(n.tagName)){"
        "    for(var i=0;i<n.childNodes.length;i++) walk(n.childNodes[i]);"
        "  }"
        "}"
        "if(document.body) walk(document.body);"
        "window.__wqMarks=marks; window.__wqMarkIdx=0;"
        "if(marks.length){ marks[0].style.background='#ff9800'; marks[0].scrollIntoView({behavior:'smooth',block:'center'}); }"
        "return {total:marks.length, idx:marks.length?1:0};"
        "})(%@[0]);", qJSON];
    __weak typeof(self) weakSelf = self;
    [self.activeTab.webView evaluateJavaScript:js completionHandler:^(id res, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if ([res isKindOfClass:NSDictionary.class] && me) {
            NSInteger tot = [res[@"total"] integerValue];
            NSInteger idx = [res[@"idx"] integerValue];
            me->_findCountLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)idx, (long)tot];
        }
    }];
}

- (void)stepFind:(NSInteger)delta
{
    NSString *js = [NSString stringWithFormat:
        @"(function(d){"
        "var m=window.__wqMarks||[]; if(!m.length) return {total:0, idx:0};"
        "m[window.__wqMarkIdx||0].style.background='#ffd54f';"
        "window.__wqMarkIdx=((window.__wqMarkIdx||0)+d+m.length)%%m.length;"
        "var cur=m[window.__wqMarkIdx]; cur.style.background='#ff9800';"
        "cur.scrollIntoView({behavior:'smooth',block:'center'});"
        "return {total:m.length, idx:window.__wqMarkIdx+1};"
        "})(%ld);", (long)delta];
    __weak typeof(self) weakSelf = self;
    [self.activeTab.webView evaluateJavaScript:js completionHandler:^(id res, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if ([res isKindOfClass:NSDictionary.class] && me) {
            NSInteger tot = [res[@"total"] integerValue];
            NSInteger idx = [res[@"idx"] integerValue];
            me->_findCountLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)idx, (long)tot];
        }
    }];
}

#pragma mark Shields Compilation & Tab Lifecycle

- (void)compileShieldsRuleListWithCompletion:(void (^ _Nullable)(void))done
{
    NSInteger level = wq_shields_level();
    BOOL blockAds = wq_shields_pref_bool(kWQBrowserShieldBlockAdsPref, YES);
    BOOL hideCookies = wq_shields_pref_bool(kWQBrowserShieldCookieHidePref, YES);
    if (level == 0 || (!blockAds && !hideCookies)) {
        _activeRuleList = nil;
        if (done) done();
        return;
    }
    NSString *ident = (level >= 2) ? @"wqglass_shields_aggressive_v2" : @"wqglass_shields_standard_v2";
    if (!blockAds || !hideCookies) ident = [ident stringByAppendingFormat:@"_a%d_c%d", (int)blockAds, (int)hideCookies];

    NSString *json = wq_browser_shields_rules_json(level >= 2, blockAds, hideCookies);
    __weak typeof(self) weakSelf = self;
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:ident
                                                      encodedContentRuleList:json
                                                           completionHandler:^(WKContentRuleList *list, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        me->_activeRuleList = list;
        if (done) done();
    }];
}

- (void)compileShieldsAndOpenFirstTab
{
    __weak typeof(self) weakSelf = self;
    [self compileShieldsRuleListWithCompletion:^{
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        NSString *initURL = me->_initialURL.length ? me->_initialURL : nil;
        [me openNewTabWithURL:initURL incognito:NO switchToTab:YES];
    }];
}

- (void)applyShieldsToTab:(WQBrowserTab *)tab
{
    if (!tab.webView) return;
    WKUserContentController *ucc = tab.webView.configuration.userContentController;
    [ucc removeAllContentRuleLists];
    [ucc removeAllUserScripts];

    NSURL *curURL = tab.webView.URL ?: (tab.savedURLString.length ? [NSURL URLWithString:tab.savedURLString] : nil);
    BOOL shieldsUp = wq_shields_enabled_for_host(curURL.host);
    BOOL popups = wq_shields_pref_bool(kWQBrowserShieldBlockPopupsPref, YES);

    [ucc addUserScript:[[WKUserScript alloc] initWithSource:wq_browser_core_shield_and_probe_js(shieldsUp, popups, tab.webDarkMode)
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:wq_browser_media_sniffer_js()
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO]];
    if (shieldsUp && _activeRuleList) {
        [ucc addContentRuleList:_activeRuleList];
    }
}

- (WKWebView *)createWebViewForTab:(WQBrowserTab *)tab
{
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.websiteDataStore = tab.incognito ? [WKWebsiteDataStore nonPersistentDataStore] : [WKWebsiteDataStore defaultDataStore];

    WKUserContentController *ucc = [WKUserContentController new];
    WQWeakScriptMessageHandler *mediaProxy = [WQWeakScriptMessageHandler new];
    mediaProxy.target = self;
    WQWeakScriptMessageHandler *shieldProxy = [WQWeakScriptMessageHandler new];
    shieldProxy.target = self;
    [ucc addScriptMessageHandler:mediaProxy name:@"wqMediaSniff"];
    [ucc addScriptMessageHandler:shieldProxy name:@"wqShieldEvent"];
    cfg.userContentController = ucc;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:_webContainer.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.navigationDelegate = self;
    wv.UIDelegate = self;
    wv.allowsBackForwardNavigationGestures = YES;
    wv.scrollView.delegate = self;
    if (tab.desktopMode) wv.customUserAgent = kWQDesktopUA;
    wv.pageZoom = tab.pageZoom > 0 ? tab.pageZoom : 1.0;

    UIRefreshControl *rc = [UIRefreshControl new];
    rc.tintColor = wq_theme_aurora_teal();
    [rc addTarget:self action:@selector(pullToRefresh:) forControlEvents:UIControlEventValueChanged];
    wv.scrollView.refreshControl = rc;

    [wv addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:NULL];
    [wv addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:NULL];

    tab.webView = wv;
    [self applyShieldsToTab:tab];
    return wv;
}

- (void)pullToRefresh:(UIRefreshControl *)rc
{
    [rc endRefreshing];
    [self.activeTab.webView reload];
}

- (void)hibernateOldTabsIfNeeded
{
    NSMutableArray<WQBrowserTab *> *live = [NSMutableArray new];
    WQBrowserTab *active = self.activeTab;
    for (WQBrowserTab *t in _tabs) {
        if (t.webView && t != active) [live addObject:t];
    }
    if ((NSInteger)live.count + 1 <= kWQMaxActiveWebViews) return;
    [live sortUsingComparator:^NSComparisonResult(WQBrowserTab *a, WQBrowserTab *b) {
        if (a.lastActiveTime < b.lastActiveTime) return NSOrderedAscending;
        if (a.lastActiveTime > b.lastActiveTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSInteger toHibernate = ((NSInteger)live.count + 1) - kWQMaxActiveWebViews;
    for (NSInteger i = 0; i < toHibernate && i < (NSInteger)live.count; i++) {
        WQBrowserTab *t = live[(NSUInteger)i];
        t.savedURLString = t.webView.URL.absoluteString ?: t.savedURLString;
        [self detachWebViewFromTab:t];
    }
}

- (WQBrowserTab *)activeTab
{
    if (_activeIndex >= 0 && (NSUInteger)_activeIndex < _tabs.count) {
        return _tabs[(NSUInteger)_activeIndex];
    }
    return nil;
}

- (void)openNewTabWithURL:(NSString * _Nullable)urlStr incognito:(BOOL)incognito switchToTab:(BOOL)switchNow
{
    if ((NSInteger)_tabs.count >= kWQMaxBrowserTabs) {
        wq_alert(self, WQLocalized(@"Tab Limit Reached"), WQLocalized(@"Close one of your 24 browser tabs before opening another."));
        return;
    }
    WQBrowserTab *tab = [WQBrowserTab new];
    tab.incognito = incognito;
    tab.desktopMode = wq_shields_pref_bool(kWQBrowserDesktopDefaultPref, NO);
    tab.webDarkMode = wq_shields_pref_bool(kWQBrowserWebDarkModePref, NO);
    tab.isNewTab = (urlStr.length == 0);
    tab.savedURLString = urlStr;
    [self createWebViewForTab:tab];
    [_tabs addObject:tab];
    [self hibernateOldTabsIfNeeded];

    if (switchNow) {
        [self switchToTabIndex:(NSInteger)_tabs.count - 1];
    } else {
        [self updateToolbarState];
        wq_haptic_selection();
    }
    if (urlStr.length) {
        NSURL *u = [NSURL URLWithString:urlStr];
        if (!u) u = wq_browser_build_search_url(urlStr);
        if (u) [tab.webView loadRequest:[NSURLRequest requestWithURL:u]];
    }
}

- (void)switchToTabIndex:(NSInteger)index
{
    if (index < 0 || (NSUInteger)index >= _tabs.count) return;
    WQBrowserTab *prev = self.activeTab;
    if (prev && prev.webView && !prev.isNewTab) {
        WKSnapshotConfiguration *scfg = [WKSnapshotConfiguration new];
        [prev.webView takeSnapshotWithConfiguration:scfg completionHandler:^(UIImage *img, NSError *__unused e) {
            if (img) prev.snapshot = img;
        }];
    }

    _activeIndex = index;
    WQBrowserTab *tab = self.activeTab;
    tab.lastActiveTime = NSDate.date.timeIntervalSince1970;
    if (!tab.webView) {
        [self createWebViewForTab:tab];
        if (tab.savedURLString.length && !tab.isNewTab) {
            NSURL *u = [NSURL URLWithString:tab.savedURLString];
            if (u) [tab.webView loadRequest:[NSURLRequest requestWithURL:u]];
        }
    }
    [self hibernateOldTabsIfNeeded];

    for (UIView *sub in _webContainer.subviews) [sub removeFromSuperview];
    if (tab.isNewTab) {
        [self refreshStartPageDashboard];
        _startPageContainer.frame = _webContainer.bounds;
        [_webContainer addSubview:_startPageContainer];
        _urlField.text = @"";
    } else {
        tab.webView.frame = _webContainer.bounds;
        [_webContainer addSubview:tab.webView];
        [self refreshOmniboxDisplay];
    }
    self.title = tab.incognito ? WQLocalized(@"Private Browser") : WQLocalized(@"Brave Privacy Browser");
    [self setChromeHidden:NO];
    [self updateToolbarState];
    [self rebuildMoreMenu];
}

- (void)closeTabAtIndex:(NSInteger)index
{
    if (index < 0 || (NSUInteger)index >= _tabs.count) return;
    WQBrowserTab *target = _tabs[(NSUInteger)index];
    if (!target.incognito && !target.isNewTab && (target.webView.URL.absoluteString.length || target.savedURLString.length)) {
        [_closedTabHistory insertObject:@{
            @"url": target.webView.URL.absoluteString ?: target.savedURLString ?: @"",
            @"title": target.pageTitle ?: @"",
        } atIndex:0];
        if (_closedTabHistory.count > 10) [_closedTabHistory removeLastObject];
    }
    [self detachWebViewFromTab:target];
    [_tabs removeObjectAtIndex:(NSUInteger)index];
    if (!_tabs.count) {
        [self openNewTabWithURL:nil incognito:NO switchToTab:YES];
        return;
    }
    NSInteger nextIdx = _activeIndex;
    if (index < _activeIndex) nextIdx = _activeIndex - 1;
    else if (index == _activeIndex) nextIdx = MIN(_activeIndex, (NSInteger)_tabs.count - 1);
    [self switchToTabIndex:nextIdx];
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
        url = wq_browser_build_search_url(trimmed);
    }
    if (!url) return;

    WQBrowserTab *tab = self.activeTab;
    if (!tab) return;
    if (!tab.webView) [self createWebViewForTab:tab];
    tab.isNewTab = NO;
    tab.savedURLString = url.absoluteString;
    if (tab.webView.superview != _webContainer) {
        for (UIView *sub in _webContainer.subviews) [sub removeFromSuperview];
        tab.webView.frame = _webContainer.bounds;
        [_webContainer addSubview:tab.webView];
    }
    [tab.webView loadRequest:[NSURLRequest requestWithURL:url]];
    [self refreshOmniboxDisplay];
}

#pragma mark Omnibox, Toolbar & Auto-Hide Chrome

- (void)refreshOmniboxDisplay
{
    WQBrowserTab *tab = self.activeTab;
    if (!tab || tab.isNewTab) {
        if (!_urlField.isFirstResponder) _urlField.text = @"";
        _lockView.image = [UIImage systemImageNamed:(tab.incognito ? @"eye.slash.fill" : @"sparkles")];
        _lockView.tintColor = tab.incognito ? UIColor.systemIndigoColor : wq_theme_aurora_teal();
        _starBtn.tintColor = wq_theme_secondary_text();
        return;
    }
    NSURL *u = tab.webView.URL ?: (tab.savedURLString.length ? [NSURL URLWithString:tab.savedURLString] : nil);
    if (!_urlField.isFirstResponder) {
        _urlField.text = u.host.length ? wq_clean_host(u) : (u.absoluteString ?: @"");
    }
    BOOL isHTTPS = [u.scheme.lowercaseString isEqualToString:@"https"];
    _lockView.image = [UIImage systemImageNamed:isHTTPS ? @"lock.fill" : @"exclamationmark.triangle.fill"];
    _lockView.tintColor = isHTTPS ? wq_theme_aurora_teal() : UIColor.systemOrangeColor;

    BOOL starred = wq_browser_is_bookmarked(u.absoluteString);
    [_starBtn setImage:[UIImage systemImageNamed:starred ? @"star.fill" : @"star"] forState:UIControlStateNormal];
    _starBtn.tintColor = starred ? UIColor.systemYellowColor : wq_theme_secondary_text();

    BOOL shieldsUp = wq_shields_enabled_for_host(u.host);
    UIButtonConfiguration *scfg = _shieldBtn.configuration;
    scfg.title = [NSString stringWithFormat:@"%lu", (unsigned long)tab.blockedCount];
    scfg.image = [UIImage systemImageNamed:shieldsUp ? @"shield.lefthalf.filled" : @"shield.slash"];
    scfg.baseForegroundColor = shieldsUp ? wq_theme_aurora_teal() : UIColor.systemOrangeColor;
    scfg.baseBackgroundColor = shieldsUp ? wq_theme_aurora_teal() : UIColor.systemOrangeColor;
    _shieldBtn.configuration = scfg;
}

- (void)updateToolbarState
{
    WQBrowserTab *tab = self.activeTab;
    _backBtn.enabled = !tab.isNewTab && tab.webView.canGoBack;
    _fwdBtn.enabled = !tab.isNewTab && tab.webView.canGoForward;
    NSUInteger mCount = tab.media.count;
    [_mediaBtn setTitle:[NSString stringWithFormat:@" %lu", (unsigned long)mCount] forState:UIControlStateNormal];
    _mediaBtn.tintColor = mCount > 0 ? wq_theme_aurora_teal() : wq_theme_secondary_text();
    [_tabsBtn setTitle:[NSString stringWithFormat:@" %lu", (unsigned long)_tabs.count] forState:UIControlStateNormal];
    [_reloadBtn setImage:[UIImage systemImageNamed:(tab.webView.isLoading ? @"xmark" : @"arrow.clockwise")] forState:UIControlStateNormal];
    [self refreshOmniboxDisplay];
}

- (void)updateDownloadsBadge
{
    NSUInteger active = WQDownloadManager.sharedManager.activeCount;
    [_dlBtn setTitle:(active > 0 ? [NSString stringWithFormat:@" %lu", (unsigned long)active] : @"") forState:UIControlStateNormal];
    _dlBtn.tintColor = active > 0 ? wq_theme_accent() : wq_theme_primary_text();
}

- (void)setChromeHidden:(BOOL)hidden
{
    if (_chromeHidden == hidden) return;
    _chromeHidden = hidden;
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_topBarHeightConstraint.constant = hidden ? 34.0 : 44.0;
        self->_botBarBottomConstraint.constant = hidden ? 72.0 : -4.0;
        self->_botBar.alpha = hidden ? 0.0 : 1.0;
        self->_shieldBtn.alpha = hidden ? 0.55 : 1.0;
        self->_starBtn.hidden = hidden;
        self->_reloadBtn.hidden = hidden;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (scrollView == _startPageScroll || scrollView != self.activeTab.webView.scrollView) return;
    if (_urlField.isFirstResponder || !_findBar.hidden) return;
    CGFloat y = scrollView.contentOffset.y;
    CGFloat dy = y - _lastScrollY;
    _lastScrollY = y;
    if (y <= 16.0) {
        [self setChromeHidden:NO];
    } else if (dy > 14.0 && y > 60.0) {
        [self setChromeHidden:YES];
    } else if (dy < -14.0) {
        [self setChromeHidden:NO];
    }
}

#pragma mark KVO & UITextFieldDelegate

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

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    if (textField != _urlField) return;
    WQBrowserTab *tab = self.activeTab;
    if (tab && !tab.isNewTab) {
        _urlField.text = tab.webView.URL.absoluteString ?: tab.savedURLString ?: @"";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [textField selectAll:nil];
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField != _urlField) return;
    _autocompleteCard.hidden = YES;
    [self refreshOmniboxDisplay];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField == _urlField) {
        _autocompleteCard.hidden = YES;
        [textField resignFirstResponder];
        [self loadUserInput:textField.text ?: @""];
    }
    return YES;
}

#pragma mark Toolbar Actions & Unified Menu

- (void)goBackTapped { [self.activeTab.webView goBack]; }
- (void)goFwdTapped { [self.activeTab.webView goForward]; }
- (void)reloadTapped
{
    WQBrowserTab *tab = self.activeTab;
    if (!tab || tab.isNewTab) {
        [self refreshStartPageDashboard];
        return;
    }
    if (tab.webView.isLoading) [tab.webView stopLoading];
    else [tab.webView reload];
}

- (void)toggleCurrentBookmark
{
    WQBrowserTab *tab = self.activeTab;
    NSString *u = tab.webView.URL.absoluteString;
    if (!u.length || tab.isNewTab) return;
    BOOL added = NO;
    wq_browser_toggle_bookmark(u, tab.pageTitle, &added);
    wq_haptic_notify(added ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning);
    [self refreshOmniboxDisplay];
    [self rebuildMoreMenu];
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

- (void)openShieldsPanel
{
    wq_haptic_selection();
    WQBrowserTab *tab = self.activeTab;
    NSString *host = tab.webView.URL.host ?: @"";
    __weak typeof(self) weakSelf = self;
    WQBrowserShieldsViewController *vc = [[WQBrowserShieldsViewController alloc] initWithHost:host pageBlocked:(tab ? tab.blockedCount : 0) onChanged:^{
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        [me compileShieldsRuleListWithCompletion:^{
            WQBrowserTab *cur = me.activeTab;
            if (cur) {
                [me applyShieldsToTab:cur];
                if (!cur.isNewTab) [cur.webView reload];
            }
            [me updateToolbarState];
            [me rebuildMoreMenu];
        }];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openTabsSheet
{
    wq_haptic_selection();
    WQBrowserTab *cur = self.activeTab;
    if (cur && cur.webView && !cur.isNewTab) {
        [cur.webView takeSnapshotWithConfiguration:[WKSnapshotConfiguration new] completionHandler:^(UIImage *img, NSError *__unused e) {
            if (img) cur.snapshot = img;
            [self presentTabGrid];
        }];
    } else {
        [self presentTabGrid];
    }
}

- (void)presentTabGrid
{
    WQBrowserTabGridViewController *grid = [[WQBrowserTabGridViewController alloc] initWithTabs:_tabs activeIndex:_activeIndex];
    grid.hasClosedHistory = (_closedTabHistory.count > 0);
    _presentedTabGrid = grid;
    __weak typeof(self) weakSelf = self;
    grid.onSelectTab = ^(NSInteger idx) {
        [weakSelf switchToTabIndex:idx];
    };
    grid.onCloseTab = ^(NSInteger idx) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        [me closeTabAtIndex:idx];
        if (me->_presentedTabGrid) {
            [me->_presentedTabGrid refreshTabs:me->_tabs activeIndex:me->_activeIndex];
        }
    };
    grid.onNewTab = ^(BOOL priv) {
        [weakSelf openNewTabWithURL:nil incognito:priv switchToTab:YES];
    };
    grid.onReopenClosed = ^{
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me || !me->_closedTabHistory.count) return;
        NSDictionary *last = me->_closedTabHistory.firstObject;
        [me->_closedTabHistory removeObjectAtIndex:0];
        [me openNewTabWithURL:last[@"url"] incognito:NO switchToTab:YES];
    };
    grid.onCloseAll = ^(BOOL priv) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) return;
        for (NSInteger i = (NSInteger)me->_tabs.count - 1; i >= 0; i--) {
            if (me->_tabs[(NSUInteger)i].incognito == priv) {
                [me detachWebViewFromTab:me->_tabs[(NSUInteger)i]];
                [me->_tabs removeObjectAtIndex:(NSUInteger)i];
            }
        }
        if (!me->_tabs.count) [me openNewTabWithURL:nil incognito:priv switchToTab:YES];
        else [me switchToTabIndex:0];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:grid];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openHistoryManager
{
    __weak typeof(self) weakSelf = self;
    WQBrowserHistoryViewController *vc = [[WQBrowserHistoryViewController alloc] initWithOnOpenURL:^(NSString *url, BOOL newTab) {
        if (newTab) [weakSelf openNewTabWithURL:url incognito:NO switchToTab:YES];
        else [weakSelf loadUserInput:url];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openBookmarksManagerSegment:(NSInteger)seg
{
    __weak typeof(self) weakSelf = self;
    WQBrowserBookmarksViewController *vc = [[WQBrowserBookmarksViewController alloc] initWithInitialSegment:seg onOpenURL:^(NSString *url, BOOL newTab) {
        if (newTab) [weakSelf openNewTabWithURL:url incognito:NO switchToTab:YES];
        else [weakSelf loadUserInput:url];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openReaderMode
{
    WQBrowserTab *tab = self.activeTab;
    if (!tab || tab.isNewTab || !tab.webView) return;
    NSString *js = @"(function(){"
        "var el = document.querySelector('article,main,[role=\"main\"]') || document.body;"
        "var clone = el.cloneNode(true);"
        "clone.querySelectorAll('script,style,nav,aside,footer,header,.ad,.ads').forEach(function(n){n.remove();});"
        "var blocks = clone.querySelectorAll('p,h1,h2,h3,li,blockquote');"
        "var txt = []; blocks.forEach(function(b){ var s=(b.innerText||'').trim(); if(s.length>15) txt.push(s); });"
        "var body = txt.length ? txt.join('\\n\\n') : (clone.innerText||'');"
        "return { title: document.title || '', url: location.href, body: body };"
    "})();";
    __weak typeof(self) weakSelf = self;
    [tab.webView evaluateJavaScript:js completionHandler:^(id res, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me || ![res isKindOfClass:NSDictionary.class]) return;
        NSString *body = [res[@"body"] isKindOfClass:NSString.class] ? res[@"body"] : @"";
        if (body.length < 40) {
            wq_alert(me, WQLocalized(@"Reader Unavailable"), WQLocalized(@"No readable article body was found on this page."));
            return;
        }
        WQBrowserReaderViewController *vc = [[WQBrowserReaderViewController alloc] initWithTitle:res[@"title"] urlString:res[@"url"] bodyText:body];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [me presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)rebuildMoreMenu
{
    if (!_menuBtn) return;
    WQBrowserTab *tab = self.activeTab;
    __weak typeof(self) weakSelf = self;

    // 1. Page Actions
    NSMutableArray<UIAction *> *pageActions = [NSMutableArray new];
    BOOL bookmarked = wq_browser_is_bookmarked(tab.webView.URL.absoluteString);
    [pageActions addObject:[UIAction actionWithTitle:WQLocalized(bookmarked ? @"Remove Bookmark" : @"Add Bookmark")
                                               image:[UIImage systemImageNamed:bookmarked ? @"star.slash" : @"star"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        [weakSelf toggleCurrentBookmark];
    }]];
    [pageActions addObject:[UIAction actionWithTitle:WQLocalized(@"Add to Reading List")
                                               image:[UIImage systemImageNamed:@"eyeglasses"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        WQBrowserTab *cur = weakSelf.activeTab;
        NSString *u = cur.webView.URL.absoluteString;
        if (!u.length || cur.isNewTab) return;
        NSMutableArray *arr = [wq_browser_load_list(kWQBrowserReadingListPref, @[]) mutableCopy];
        [arr insertObject:@{ @"title": cur.pageTitle ?: u, @"url": u } atIndex:0];
        [NSUserDefaults.standardUserDefaults setObject:arr forKey:kWQBrowserReadingListPref];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    }]];
    [pageActions addObject:[UIAction actionWithTitle:WQLocalized(@"Share Page…")
                                               image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        WQDownloadBrowserViewController *me = weakSelf;
        NSURL *u = me.activeTab.webView.URL;
        if (!me || !u) return;
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[u] applicationActivities:nil];
        av.popoverPresentationController.sourceView = me->_menuBtn;
        [me presentViewController:av animated:YES completion:nil];
    }]];
    [pageActions addObject:[UIAction actionWithTitle:WQLocalized(@"Save Webpage as PDF")
                                               image:[UIImage systemImageNamed:@"doc.richtext"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        [weakSelf saveCurrentPageAsPDF];
    }]];

    // 2. In-Page & Power Tools
    NSMutableArray<UIMenuElement *> *toolActions = [NSMutableArray new];
    [toolActions addObject:[UIAction actionWithTitle:WQLocalized(@"Find in Page")
                                               image:[UIImage systemImageNamed:@"doc.text.magnifyingglass"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        [weakSelf openFindInPage];
    }]];
    [toolActions addObject:[UIAction actionWithTitle:WQLocalized(@"Reader Mode")
                                               image:[UIImage systemImageNamed:@"doc.plaintext"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        [weakSelf openReaderMode];
    }]];
    UIAction *darkAct = [UIAction actionWithTitle:WQLocalized(@"Web Dark Mode")
                                            image:[UIImage systemImageNamed:@"moon.stars.fill"]
                                       identifier:nil
                                          handler:^(UIAction *__unused a) {
        WQBrowserTab *cur = weakSelf.activeTab;
        if (!cur) return;
        cur.webDarkMode = !cur.webDarkMode;
        [cur.webView evaluateJavaScript:[NSString stringWithFormat:@"if(window.__wqSetDarkMode) window.__wqSetDarkMode(%@);", cur.webDarkMode ? @"true" : @"false"] completionHandler:nil];
        [weakSelf rebuildMoreMenu];
    }];
    if (tab.webDarkMode) darkAct.state = UIMenuElementStateOn;
    [toolActions addObject:darkAct];

    // Zoom Submenu
    NSMutableArray<UIAction *> *zoomActs = [NSMutableArray new];
    NSArray<NSNumber *> *zoomLevels = @[@0.5, @0.75, @0.85, @1.0, @1.15, @1.25, @1.5, @2.0];
    CGFloat curZoom = tab.pageZoom > 0 ? tab.pageZoom : 1.0;
    for (NSNumber *z in zoomLevels) {
        CGFloat zv = z.doubleValue;
        UIAction *za = [UIAction actionWithTitle:[NSString stringWithFormat:@"%.0f%%", zv * 100.0]
                                           image:nil
                                      identifier:nil
                                         handler:^(UIAction *__unused a) {
            WQBrowserTab *cur = weakSelf.activeTab;
            if (!cur) return;
            cur.pageZoom = zv;
            cur.webView.pageZoom = zv;
            [weakSelf rebuildMoreMenu];
        }];
        if (fabs(curZoom - zv) < 0.02) za.state = UIMenuElementStateOn;
        [zoomActs addObject:za];
    }
    [toolActions addObject:[UIMenu menuWithTitle:[NSString stringWithFormat:@"%@ (%.0f%%)", WQLocalized(@"Page Zoom"), curZoom * 100.0]
                                           image:[UIImage systemImageNamed:@"plus.magnifyingglass"]
                                      identifier:nil
                                         options:0
                                        children:zoomActs]];

    UIAction *deskAct = [UIAction actionWithTitle:tab.desktopMode ? WQLocalized(@"Switch to Mobile Site") : WQLocalized(@"Request Desktop Site")
                                            image:[UIImage systemImageNamed:@"desktopcomputer"]
                                       identifier:nil
                                          handler:^(UIAction *__unused a) {
        WQBrowserTab *cur = weakSelf.activeTab;
        if (!cur) return;
        cur.desktopMode = !cur.desktopMode;
        cur.webView.customUserAgent = cur.desktopMode ? kWQDesktopUA : nil;
        if (!cur.isNewTab) [cur.webView reload];
        [weakSelf rebuildMoreMenu];
    }];
    if (tab.desktopMode) deskAct.state = UIMenuElementStateOn;
    [toolActions addObject:deskAct];

    [toolActions addObject:[UIAction actionWithTitle:WQLocalized(@"Grab All Links & Media on Page…")
                                               image:[UIImage systemImageNamed:@"arrow.down.doc"]
                                          identifier:nil
                                             handler:^(UIAction *__unused a) {
        [weakSelf grabAllResourcesOnPage];
    }]];

    // 3. Library, Search Engines & Privacy
    BOOL clearOnExit = wq_shields_pref_bool(kWQBrowserClearOnExitPref, NO);
    UIAction *clearExitAct = [UIAction actionWithTitle:WQLocalized(@"Clear Data on Exit")
                                                 image:[UIImage systemImageNamed:@"flame"]
                                            identifier:nil
                                               handler:^(UIAction *__unused a) {
        [NSUserDefaults.standardUserDefaults setBool:!clearOnExit forKey:kWQBrowserClearOnExitPref];
        [weakSelf rebuildMoreMenu];
    }];
    if (clearOnExit) clearExitAct.state = UIMenuElementStateOn;

    UIMenu *libraryAndPrivacy = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:WQLocalized(@"History…") image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf openHistoryManager];
        }],
        [UIAction actionWithTitle:WQLocalized(@"Bookmarks & Reading List…") image:[UIImage systemImageNamed:@"book"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf openBookmarksManagerSegment:0];
        }],
        [self buildSearchEngineMenu],
        [UIAction actionWithTitle:WQLocalized(@"Brave Shields Settings…") image:[UIImage systemImageNamed:@"shield.lefthalf.filled"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf openShieldsPanel];
        }],
        clearExitAct,
        [UIAction actionWithTitle:WQLocalized(@"Clear Cookies & Browsing Data") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *__unused a) {
            NSSet<NSString *> *allTypes = [WKWebsiteDataStore allWebsiteDataTypes];
            [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:allTypes modifiedSince:NSDate.distantPast completionHandler:^{
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(weakSelf, WQLocalized(@"Cleared"), WQLocalized(@"Cookies, cache & local storage cleared."));
            }];
        }],
    ]];

    UIMenu *pageSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:pageActions];
    UIMenu *toolsSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:toolActions];
    _menuBtn.menu = [UIMenu menuWithTitle:WQLocalized(@"Browser Tools") children:@[pageSection, toolsSection, libraryAndPrivacy]];
}

- (void)saveCurrentPageAsPDF
{
    WKWebView *wv = self.activeTab.webView;
    if (!wv || self.activeTab.isNewTab) return;
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
    if (!wv || self.activeTab.isNewTab) return;
    NSString *js = @"(function(){"
        "var seen={}, out=[];"
        "function add(raw){"
        "  try{"
        "    if(!raw || raw.indexOf('data:')===0 || raw.indexOf('blob:')===0 || raw.indexOf('javascript:')===0) return;"
        "    var u = new URL(raw, location.href).href;"
        "    if(seen[u] || out.length>=200) return;"
        "    if(!/\\.(m3u8|mp4|m4v|mov|mkv|webm|avi|flv|ts|mp3|m4a|aac|flac|wav|ogg|opus|jpg|jpeg|png|webp|gif|svg|pdf|zip|rar|7z|tar|gz|ipa|deb|dmg|epub|docx|xlsx|pptx)(\\?|#|$)/i.test(u)) return;"
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

#pragma mark WKScriptMessageHandler (Media Sniff + Shields Telemetry)

- (void)userContentController:(WKUserContentController *__unused)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    WQBrowserTab *tab = nil;
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == message.webView) { tab = t; break; }
    }
    if ([message.name isEqualToString:@"wqShieldEvent"] && [message.body isKindOfClass:NSDictionary.class]) {
        NSString *kind = [message.body[@"kind"] isKindOfClass:NSString.class] ? message.body[@"kind"] : @"ad";
        wq_shields_record_stat(kind, 1);
        if (tab) {
            tab.blockedCount++;
            if (tab == self.activeTab) [self refreshOmniboxDisplay];
        }
        return;
    }

    if (![message.name isEqualToString:@"wqMediaSniff"] || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *d = (NSDictionary *)message.body;
    NSString *u = [d[@"url"] isKindOfClass:NSString.class] ? d[@"url"] : nil;
    if (!u.length || !tab || [tab.seenURLs containsObject:u]) return;
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

#pragma mark WKNavigationDelegate (Stripping, HTTPS Upgrade, Scripts & Downloads)

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *__unused)navigation
{
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == webView) {
            [t.media removeAllObjects];
            [t.seenURLs removeAllObjects];
            t.blockedCount = 0;
            break;
        }
    }
    if (webView == self.activeTab.webView) {
        [self updateToolbarState];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *__unused)navigation
{
    [webView.scrollView.refreshControl endRefreshing];
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == webView) {
            t.savedURLString = webView.URL.absoluteString;
            if (!t.incognito && !t.isNewTab && webView.URL.absoluteString.length) {
                wq_browser_record_history(webView.URL.absoluteString, webView.title ?: t.pageTitle);
            }
            if (t.webDarkMode) {
                [webView evaluateJavaScript:@"if(window.__wqSetDarkMode) window.__wqSetDarkMode(true);" completionHandler:nil];
            }
            break;
        }
    }
    if (webView == self.activeTab.webView) {
        [self updateToolbarState];
        [self rebuildMoreMenu];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *__unused)navigation withError:(NSError *)error
{
    [webView.scrollView.refreshControl endRefreshing];
    NSURL *failedURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    if ([failedURL.scheme.lowercaseString isEqualToString:@"https"] &&
        failedURL.host.length &&
        wq_shields_pref_bool(kWQBrowserShieldHTTPSUpgradePref, YES) &&
        ![_httpFallbackHosts containsObject:failedURL.host.lowercaseString]) {
        [_httpFallbackHosts addObject:failedURL.host.lowercaseString];
        NSURLComponents *c = [NSURLComponents componentsWithURL:failedURL resolvingAgainstBaseURL:NO];
        c.scheme = @"http";
        if (c.URL) {
            [webView loadRequest:[NSURLRequest requestWithURL:c.URL]];
            return;
        }
    }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    preferences:(WKWebpagePreferences *)preferences
                decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    WQBrowserTab *tab = nil;
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == webView) { tab = t; break; }
    }

    if (url.host.length) {
        preferences.allowsContentJavaScript = !wq_shields_block_scripts_for_host(url.host);
    }

    // Main-frame tracking param stripper + HTTPS upgrade
    if (navigationAction.targetFrame.isMainFrame && url &&
        ([url.scheme.lowercaseString isEqualToString:@"http"] || [url.scheme.lowercaseString isEqualToString:@"https"])) {
        BOOL shieldsUp = wq_shields_enabled_for_host(url.host);
        NSURL *candidate = url;
        BOOL modified = NO;

        if (shieldsUp) {
            NSInteger stripped = 0;
            NSURL *clean = wq_strip_tracking_params(candidate, &stripped);
            if (stripped > 0 && clean && ![clean.absoluteString isEqualToString:candidate.absoluteString]) {
                candidate = clean;
                modified = YES;
                wq_shields_record_stat(@"tracker", (NSUInteger)stripped);
                if (tab) tab.blockedCount += (NSUInteger)stripped;
            }
            if ([candidate.scheme.lowercaseString isEqualToString:@"http"] &&
                wq_shields_pref_bool(kWQBrowserShieldHTTPSUpgradePref, YES) &&
                !wq_is_local_or_lan_host(candidate.host) &&
                ![_httpFallbackHosts containsObject:candidate.host.lowercaseString]) {
                NSURLComponents *up = [NSURLComponents componentsWithURL:candidate resolvingAgainstBaseURL:NO];
                up.scheme = @"https";
                if (up.URL) {
                    candidate = up.URL;
                    modified = YES;
                }
            }
        }
        if (modified && candidate && ![candidate.absoluteString isEqualToString:url.absoluteString]) {
            decisionHandler(WKNavigationActionPolicyCancel, preferences);
            [webView loadRequest:[NSURLRequest requestWithURL:candidate]];
            return;
        }
    }

    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && url && wq_url_has_downloadable_ext(url)) {
        decisionHandler(WKNavigationActionPolicyCancel, preferences);
        NSString *ref = webView.URL.absoluteString;
        NSDictionary *hdrs = ref.length ? @{ @"Referer": ref } : nil;
        if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
            wq_present_hls_quality_picker(self, url.absoluteString, url.lastPathComponent, hdrs);
        } else {
            wq_present_add_download_sheet(self, url.absoluteString, url.lastPathComponent, -1, hdrs, NO, nil);
        }
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
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

#pragma mark WKUIDelegate (Popup Blocker + Long-Press Context Menus for Links / Videos / Images)

- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *__unused)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *__unused)windowFeatures
{
    WQBrowserTab *tab = nil;
    for (WQBrowserTab *t in _tabs) {
        if (t.webView == webView) { tab = t; break; }
    }
    BOOL shieldsUp = wq_shields_enabled_for_host(webView.URL.host) && wq_shields_pref_bool(kWQBrowserShieldBlockPopupsPref, YES);
    NSURL *u = navigationAction.request.URL;
    if (u) {
        if (shieldsUp && navigationAction.navigationType != WKNavigationTypeLinkActivated) {
            wq_shields_record_stat(@"popup", 1);
            if (tab) {
                tab.blockedCount++;
                if (tab == self.activeTab) [self refreshOmniboxDisplay];
            }
            return nil;
        }
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

- (void)collectHeadersForWebView:(WKWebView *)webView url:(NSURL *)targetURL completion:(void (^)(NSDictionary<NSString *, NSString *> *headers))done
{
    NSString *ref = webView.URL.absoluteString;
    NSString *ua = webView.customUserAgent;
    [webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray<NSString *> *pairs = [NSMutableArray new];
        for (NSHTTPCookie *c in cookies) {
            if (targetURL.host.length && [targetURL.host.lowercaseString hasSuffix:c.domain.lowercaseString]) {
                [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
            }
        }
        NSMutableDictionary<NSString *, NSString *> *hdrs = [NSMutableDictionary new];
        if (ref.length) hdrs[@"Referer"] = ref;
        if (pairs.count) hdrs[@"Cookie"] = [pairs componentsJoinedByString:@"; "];
        if (ua.length) hdrs[@"User-Agent"] = ua;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(hdrs);
        });
    }];
}

- (void)saveImageURLToPhotos:(NSURL *)imageURL webView:(WKWebView *)webView
{
    [self collectHeadersForWebView:webView url:imageURL completion:^(NSDictionary<NSString *, NSString *> *hdrs) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:imageURL];
        for (NSString *k in hdrs) [req setValue:hdrs[k] forHTTPHeaderField:k];
        __weak typeof(self) weakSelf = self;
        [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *__unused r, NSError *err) {
            UIImage *img = (data.length && !err) ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!img) {
                    wq_alert(weakSelf, WQLocalized(@"Save Failed"), err.localizedDescription ?: WQLocalized(@"Could not download image."));
                    return;
                }
                UIImageWriteToSavedPhotosAlbum(img, nil, NULL, NULL);
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(weakSelf, WQLocalized(@"Saved to Photos"), WQVerbatim(imageURL.lastPathComponent ?: @"Image"));
            });
        }] resume];
    }];
}

- (void)webView:(WKWebView *)webView
contextMenuConfigurationForElement:(WKContextMenuElementInfo *)elementInfo
                 completionHandler:(void (^)(UIContextMenuConfiguration * _Nullable configuration))completionHandler
{
    NSURL *nativeLink = elementInfo.linkURL;
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:@"window.__wqLastHit || null" completionHandler:^(id res, NSError *__unused err) {
        WQDownloadBrowserViewController *me = weakSelf;
        if (!me) { completionHandler(nil); return; }

        NSDictionary *hit = [res isKindOfClass:NSDictionary.class] ? (NSDictionary *)res : nil;
        NSString *hrefStr = ([hit[@"href"] isKindOfClass:NSString.class] && [hit[@"href"] length]) ? hit[@"href"] : nativeLink.absoluteString;
        NSString *videoStr = ([hit[@"videoSrc"] isKindOfClass:NSString.class] && [hit[@"videoSrc"] length]) ? hit[@"videoSrc"] : nil;
        NSString *audioStr = ([hit[@"audioSrc"] isKindOfClass:NSString.class] && [hit[@"audioSrc"] length]) ? hit[@"audioSrc"] : nil;
        NSString *imgStr = ([hit[@"imgSrc"] isKindOfClass:NSString.class] && [hit[@"imgSrc"] length]) ? hit[@"imgSrc"] : nil;
        NSString *mediaStr = videoStr.length ? videoStr : audioStr;

        NSURL *linkURL = hrefStr.length ? [NSURL URLWithString:hrefStr] : nil;
        NSURL *mediaURL = mediaStr.length ? [NSURL URLWithString:mediaStr] : nil;
        if (!mediaURL && linkURL && wq_url_is_playable_media(linkURL)) {
            mediaURL = linkURL;
        }
        NSURL *imgURL = imgStr.length ? [NSURL URLWithString:imgStr] : nil;

        if (!linkURL && !mediaURL && !imgURL) {
            completionHandler(nil);
            return;
        }

        NSString *menuTitle = mediaURL.lastPathComponent ?: linkURL.host ?: imgURL.lastPathComponent ?: @"";
        NSMutableArray<UIMenuElement *> *sections = [NSMutableArray new];

        if (mediaURL) {
            NSString *mAbs = mediaURL.absoluteString;
            NSString *mTitle = ([hit[@"title"] isKindOfClass:NSString.class] && [hit[@"title"] length]) ? hit[@"title"] : (mediaURL.lastPathComponent ?: @"Media");
            UIMenu *mediaMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
                [UIAction actionWithTitle:WQLocalized(@"Play in WQ Pro Player") image:[UIImage systemImageNamed:@"play.circle.fill"] identifier:nil handler:^(UIAction *__unused a) {
                    [me collectHeadersForWebView:webView url:mediaURL completion:^(NSDictionary<NSString *, NSString *> *hdrs) {
                        [WQProMediaPlayerViewController presentStreamFrom:me title:mTitle streamURL:mediaURL headers:hdrs];
                    }];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Download Video / Audio") image:[UIImage systemImageNamed:@"arrow.down.circle.fill"] identifier:nil handler:^(UIAction *__unused a) {
                    [me collectHeadersForWebView:webView url:mediaURL completion:^(NSDictionary<NSString *, NSString *> *hdrs) {
                        if ([mAbs.lowercaseString containsString:@".m3u8"]) {
                            wq_present_hls_quality_picker(me, mAbs, mTitle, hdrs);
                        } else {
                            wq_present_add_download_sheet(me, mAbs, mediaURL.lastPathComponent ?: mTitle, -1, hdrs, NO, nil);
                        }
                    }];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Open Media in New Tab") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *__unused a) {
                    [me openNewTabWithURL:mAbs incognito:NO switchToTab:YES];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Copy Media URL") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
                    UIPasteboard.generalPasteboard.string = mAbs;
                    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                }],
            ]];
            [sections addObject:mediaMenu];
        }

        if (linkURL) {
            NSString *lAbs = linkURL.absoluteString;
            UIMenu *linkMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
                [UIAction actionWithTitle:WQLocalized(@"Open in New Tab") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *__unused a) {
                    [me openNewTabWithURL:lAbs incognito:me.activeTab.incognito switchToTab:YES];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Open in Background Tab") image:[UIImage systemImageNamed:@"rectangle.stack.badge.plus"] identifier:nil handler:^(UIAction *__unused a) {
                    [me openNewTabWithURL:lAbs incognito:me.activeTab.incognito switchToTab:NO];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Open in Private Tab") image:[UIImage systemImageNamed:@"eye.slash.fill"] identifier:nil handler:^(UIAction *__unused a) {
                    [me openNewTabWithURL:lAbs incognito:YES switchToTab:YES];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Download Link") image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(UIAction *__unused a) {
                    [me collectHeadersForWebView:webView url:linkURL completion:^(NSDictionary<NSString *, NSString *> *hdrs) {
                        wq_present_add_download_sheet(me, lAbs, linkURL.lastPathComponent, -1, hdrs, [lAbs.lowercaseString containsString:@".m3u8"], nil);
                    }];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Copy Link") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *__unused a) {
                    UIPasteboard.generalPasteboard.string = lAbs;
                    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                }],
                [UIAction actionWithTitle:WQLocalized(@"Share Link") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *__unused a) {
                    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[linkURL] applicationActivities:nil];
                    av.popoverPresentationController.sourceView = me.view;
                    [me presentViewController:av animated:YES completion:nil];
                }],
            ]];
            [sections addObject:linkMenu];
        }

        if (imgURL) {
            NSString *iAbs = imgURL.absoluteString;
            UIMenu *imgMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
                [UIAction actionWithTitle:WQLocalized(@"Open Image in New Tab") image:[UIImage systemImageNamed:@"photo"] identifier:nil handler:^(UIAction *__unused a) {
                    [me openNewTabWithURL:iAbs incognito:me.activeTab.incognito switchToTab:YES];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Download Image") image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(UIAction *__unused a) {
                    [me collectHeadersForWebView:webView url:imgURL completion:^(NSDictionary<NSString *, NSString *> *hdrs) {
                        wq_present_add_download_sheet(me, iAbs, imgURL.lastPathComponent, -1, hdrs, NO, nil);
                    }];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Save to Photos") image:[UIImage systemImageNamed:@"square.and.arrow.down.on.square"] identifier:nil handler:^(UIAction *__unused a) {
                    [me saveImageURLToPhotos:imgURL webView:webView];
                }],
                [UIAction actionWithTitle:WQLocalized(@"Copy Image URL") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *__unused a) {
                    UIPasteboard.generalPasteboard.string = iAbs;
                    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                }],
            ]];
            [sections addObject:imgMenu];
        }

        UIContextMenuConfiguration *cfg = [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                                                 previewProvider:nil
                                                                                  actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
            return [UIMenu menuWithTitle:menuTitle children:sections];
        }];
        completionHandler(cfg);
    }];
}

@end
