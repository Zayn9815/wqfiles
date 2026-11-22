//
//  WQUI.m
//  WQ Glass shared UI helpers
//  GPL-3.0-or-later.
//

#import "WQUI.h"
#import "WQTheme.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

// "iPhone 17 Pro Max (iPhone18,2)\niOS 27.0.1 (24A446)"
NSString *wq_device_line(void)
{
    struct utsname u;
    NSString *machine = (uname(&u) == 0) ? @(u.machine) : @"unknown";
    char build[64] = {0};
    size_t len = sizeof(build);
    NSString *buildStr = (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0) ? @(build) : nil;
    NSDictionary *names = @{
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
        @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air",
    };
    NSString *marketing = names[machine];
    NSString *model = marketing ? [NSString stringWithFormat:@"%@ (%@)", marketing, machine] : machine;
    NSString *ver = UIDevice.currentDevice.systemVersion;
    return buildStr ? [NSString stringWithFormat:@"%@ · iOS %@ (%@)", model, ver, buildStr]
                    : [NSString stringWithFormat:@"%@ · iOS %@", model, ver];
}

// "WQ Glass 4.0 (400)": in the strip, so screenshots show the version.
NSString *wq_app_version_line(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Glass %@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
}

const CGFloat kWQDeviceStripHeight = 56;

// Frosted iPhone Duo Liquid Glass telemetry pill with aqua dot, version and device/iOS line.
UIView *wq_device_header(CGFloat width)
{
    CGFloat useWidth = width > 0 ? width : 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, useWidth, kWQDeviceStripHeight + 16)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    box.clipsToBounds = YES;
    UIVisualEffectView *pill = wq_theme_make_glass_card(18, NO);
    [box addSubview:pill];

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = wq_theme_accent();
    dot.layer.cornerRadius = 3.5;
    dot.layer.shadowColor = wq_theme_accent().CGColor;
    dot.layer.shadowOpacity = 0.90;
    dot.layer.shadowRadius = 5.0;
    dot.layer.shadowOffset = CGSizeZero;

    UILabel *header = [UILabel new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.numberOfLines = 0;
    header.lineBreakMode = NSLineBreakByWordWrapping;
    header.textAlignment = NSTextAlignmentCenter;
    header.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    header.textColor = wq_theme_detail_text();
    header.backgroundColor = [UIColor clearColor];
    header.text = [NSString stringWithFormat:@"%@\n%@", wq_app_version_line(), wq_device_line()];
    [pill.contentView addSubview:dot];
    [pill.contentView addSubview:header];

    [NSLayoutConstraint activateConstraints:@[
        [pill.topAnchor constraintEqualToAnchor:box.topAnchor constant:6],
        [pill.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [pill.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:kWQDeviceStripHeight - 4],
        [dot.widthAnchor constraintEqualToConstant:7],
        [dot.heightAnchor constraintEqualToConstant:7],
        [dot.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:14],
        [dot.centerYAnchor constraintEqualToAnchor:pill.contentView.centerYAnchor],
        [header.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:8],
        [header.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-8],
        [header.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:8],
        [header.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-14],
    ]];

    [box layoutIfNeeded];
    CGSize labelSize = [header sizeThatFits:CGSizeMake(MAX(120.0, useWidth - 72.0), CGFLOAT_MAX)];
    CGFloat pillHeight = MAX(kWQDeviceStripHeight - 4, ceil(labelSize.height) + 16.0);
    box.frame = CGRectMake(0, 0, useWidth, pillHeight + 14.0);
    return box;
}

// Private: app icon by bundle id (in UIKit; guarded with respondsToSelector).
@interface UIImage (WQPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Small grey fingerprint of an icon, to recognise iOS's blank placeholder.
static NSData *wq_icon_fingerprint(UIImage *img)
{
    const size_t s = 12;
    uint8_t px[12 * 12 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, s, s, 8, s * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    if (img.CGImage) CGContextDrawImage(ctx, CGRectMake(0, 0, s, s), img.CGImage);
    CGContextRelease(ctx);
    return [NSData dataWithBytes:px length:sizeof(px)];
}

static UIImage *wq_raw_icon(NSString *bundleID)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    CGFloat scale = 2.0; // Safe fallback for background preparation without UI context.
    if (NSThread.isMainThread) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                scale = ((UIWindowScene *)scene).screen.scale;
                break;
            }
        }
    }
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:scale];
}

// The real icon for bundleID, or nil when iOS only has its placeholder.
static UIImage *wq_real_icon(NSString *bundleID)
{
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ placeholder = wq_icon_fingerprint(wq_raw_icon(@"com.zayn.wqglass.no-such-app")); });
    UIImage *raw = wq_raw_icon(bundleID);
    if (!raw || !raw.CGImage) return nil;
    NSData *fp = wq_icon_fingerprint(raw);
    if (!placeholder || fp.length != placeholder.length) return raw;
    // Near-identical to the placeholder (allow small rendering differences).
    const uint8_t *a = fp.bytes, *b = placeholder.bytes;
    unsigned long diff = 0;
    for (NSUInteger i = 0; i < fp.length; i++) diff += (unsigned long)abs((int)a[i] - (int)b[i]);
    return diff / fp.length < 8 ? nil : raw;
}

// The icon from the app's own bundle, for when iOS only hands out its
// placeholder (iOS 26 refuses this app's icon requests). Reads the primary
// icon names from Info.plist and loads the matching PNG files.
// The first few outcomes go to the Log, to see why icons are missing.
static void wq_icon_note(NSString *bundleID, NSString *what)
{
    static NSUInteger notes;
    @synchronized (NSNull.null) {
        if (notes >= 8) return;
        notes++;
    }
    wq_log(@"icon: %@: %@", bundleID, what);
}

static UIImage *wq_bundle_icon(NSString *bundleID)
{
    NSString *path = wq_bundle_path_for_id(bundleID);
    if (!path.length) { wq_icon_note(bundleID, @"no bundle path in the app database"); return nil; }
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info && wq_grant(path)) info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info isKindOfClass:NSDictionary.class]) {
        int fd = open(plistPath.fileSystemRepresentation, O_RDONLY);
        int err = fd < 0 ? errno : 0;
        if (fd >= 0) close(fd);
        wq_icon_note(bundleID, [NSString stringWithFormat:@"can't read %@ (%s)", plistPath, err ? strerror(err) : "not a plist"]);
        return nil;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *primary = [info[key] isKindOfClass:NSDictionary.class] ? info[key][@"CFBundlePrimaryIcon"] : nil;
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
        NSArray *files = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : @[];
        for (id file in files.reverseObjectEnumerator) if ([file isKindOfClass:NSString.class]) [names addObject:file];
    }
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon"]];
    // Only the PNG files apps ship next to their asset catalog. Loading from
    // the catalog (UIImage imageNamed:inBundle:) aborts inside UIKit when an
    // entry exists but can't be rendered (crash on 27.0.1, build 21).
    for (NSString *name in names) {
        NSString *base = name.stringByDeletingPathExtension;
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:[base stringByAppendingString:suffix]]];
            if (image.CGImage) {
                wq_icon_note(bundleID, [NSString stringWithFormat:@"loaded %@%@ from the app", base, suffix]);
                return image;
            }
        }
    }
    wq_icon_note(bundleID, [NSString stringWithFormat:@"no icon PNG in %@ (tried %@)", path.lastPathComponent,
                            [names componentsJoinedByString:@", "]]);
    return nil;
}

static UIImage *wq_round_icon(UIImage *raw)
{
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] addClip];
        [raw drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

// Symbol tile for system services and extensions that have no icon at all,
// picked from keywords in the bundle id.
static UIImage *wq_service_tile(NSString *bundleID)
{
    static NSArray<NSArray *> *rules;
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSCache new];
        // Arctic Glacier palette for fallback service tiles (zero warm/red hues).
        UIColor *blue   = [UIColor colorWithRed:0.204 green:0.452 blue:0.680 alpha:1.0];
        UIColor *green  = [UIColor colorWithRed:0.169 green:0.372 blue:0.560 alpha:1.0];
        UIColor *red    = [UIColor colorWithRed:0.212 green:0.393 blue:0.560 alpha:1.0];
        UIColor *orange = [UIColor colorWithRed:0.249 green:0.452 blue:0.640 alpha:1.0];
        UIColor *purple = [UIColor colorWithRed:0.263 green:0.449 blue:0.620 alpha:1.0];
        UIColor *indigo = [UIColor colorWithRed:0.200 green:0.377 blue:0.540 alpha:1.0];
        UIColor *teal   = [UIColor colorWithRed:0.167 green:0.423 blue:0.660 alpha:1.0];
        UIColor *pink   = [UIColor colorWithRed:0.289 green:0.492 blue:0.680 alpha:1.0];
        UIColor *gray   = [UIColor colorWithRed:0.276 green:0.382 blue:0.480 alpha:1.0];
        // keywords (lower case, any match), symbol, colour
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bundleID.lowercaseString;
    NSString *symbol = @"cube.transparent.fill";
    UIColor *color = [UIColor colorWithRed:0.232 green:0.250 blue:0.297 alpha:1.0];
    for (NSArray *rule in rules) {
        BOOL hit = NO;
        for (NSString *word in rule[0]) if ([key containsString:word]) { hit = YES; break; }
        if (hit) { symbol = rule[1]; color = rule[2]; break; }
    }
    NSString *cacheKey = [symbol stringByAppendingString:color.description];
    UIImage *tile = [tiles objectForKey:cacheKey];
    if (tile) return tile;
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    UIColor *fill = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
    tile = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, s, s);
        CGFloat radius = s * 0.24;
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [clip addClip];
        // Deep sub-zero frosted gradient from navy base into glacier tint.
        CGFloat cr = 0.09, cg = 0.22, cb = 0.35, ca = 1.0;
        [fill getRed:&cr green:&cg blue:&cb alpha:&ca];
        UIColor *top = [UIColor colorWithRed:MIN(1.0, cr * 1.15) green:MIN(1.0, cg * 1.18) blue:MIN(1.0, cb * 1.20) alpha:0.96];
        UIColor *bot = [UIColor colorWithRed:cr * 0.52 green:cg * 0.56 blue:cb * 0.64 alpha:0.98];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)top.CGColor, (id)bot.CGColor];
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointMake(0, 0), CGPointMake(s, s), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);

        // Specular icy-silver rim inside the rounded square.
        UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.75, 0.75) cornerRadius:radius - 0.75];
        rim.lineWidth = 1.0;
        [[UIColor colorWithRed:0.830 green:0.918 blue:1.000 alpha:0.34] setStroke];
        [rim stroke];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [UIImage systemImageNamed:symbol withConfiguration:cfg]
                    ?: [UIImage systemImageNamed:@"cube.transparent.fill" withConfiguration:cfg];
        UIImage *g = [sym imageWithTintColor:[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:1.0]
                               renderingMode:UIImageRenderingModeAlwaysOriginal];
        [g drawInRect:CGRectMake((s - g.size.width) / 2.0, (s - g.size.height) / 2.0, g.size.width, g.size.height)];
    }];
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

UIImage *wq_glacier_symbol_badge(NSString *symbolName, CGFloat size)
{
    static NSCache *badgeCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ badgeCache = [NSCache new]; });
    CGFloat s = size > 0 ? size : 36.0;
    NSString *sym = symbolName.length ? symbolName : @"cube.transparent.fill";
    NSString *key = [NSString stringWithFormat:@"%@_%.0f", sym, s];
    UIImage *cached = [badgeCache objectForKey:key];
    if (cached) return cached;

    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, s, s);
        CGFloat radius = s * 0.25;
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [clip addClip];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[
            (id)[UIColor colorWithRed:0.229 green:0.247 blue:0.293 alpha:0.96].CGColor,
            (id)[UIColor colorWithRed:0.130 green:0.140 blue:0.167 alpha:0.98].CGColor,
        ];
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointMake(0, 0), CGPointMake(s, s), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);

        UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.75, 0.75) cornerRadius:radius - 0.75];
        rim.lineWidth = 1.0;
        [[UIColor colorWithRed:0.575 green:0.796 blue:1.000 alpha:0.36] setStroke];
        [rim stroke];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:s * 0.48
                                                                                          weight:UIImageSymbolWeightSemibold];
        UIImage *raw = [UIImage systemImageNamed:sym withConfiguration:cfg]
                    ?: [UIImage systemImageNamed:@"cube.transparent.fill" withConfiguration:cfg];
        UIImage *tinted = [raw imageWithTintColor:[UIColor colorWithRed:0.703 green:0.857 blue:1.000 alpha:1.0]
                                    renderingMode:UIImageRenderingModeAlwaysOriginal];
        [tinted drawInRect:CGRectMake((s - tinted.size.width) / 2.0, (s - tinted.size.height) / 2.0,
                                      tinted.size.width, tinted.size.height)];
    }];
    if (img) [badgeCache setObject:img forKey:key];
    return img;
}

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
UIImage *wq_app_icon(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    // The bundle fallback reads files and may ask for access: never on the
    // main thread. Lists warm the cache from their background passes; a
    // main-thread miss gets the tile without caching it.
    BOOL background = !NSThread.isMainThread;
    UIImage *system = wq_real_icon(bundleID);
    if (system && background) wq_icon_note(bundleID, @"iOS returned an icon");
    UIImage *raw = system ?: (background ? wq_bundle_icon(bundleID) : nil);
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
    {
        NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        raw = wq_real_icon(parent) ?: (background ? wq_bundle_icon(parent) : nil);
    }
    UIImage *icon = raw ? wq_round_icon(raw) : wq_service_tile(bundleID);
    if (raw || background) [cache setObject:icon forKey:bundleID];
    return icon;
}

dispatch_queue_t wq_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

NSNotificationName const WQSafeReadOnlyDidChangeNotification = @"WQSafeReadOnlyDidChangeNotification";
static NSString *const kWQSafeReadOnlyPref = @"WQSafeReadOnlyMode";
static NSString *const kWQDeletingDisabledPref = @"WQDeletingDisabled";

BOOL wq_safe_read_only_enabled(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQSafeReadOnlyPref];
}

void wq_set_safe_read_only_enabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kWQSafeReadOnlyPref];
    [NSNotificationCenter.defaultCenter postNotificationName:WQSafeReadOnlyDidChangeNotification object:nil];
}

BOOL wq_deleting_allowed(void)
{
    if (wq_safe_read_only_enabled()) return NO;
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDeletingDisabledPref];
}

void wq_set_deleting_allowed(BOOL allowed)
{
    [NSUserDefaults.standardUserDefaults setBool:!allowed forKey:kWQDeletingDisabledPref];
}

static NSString *const kWQDiscardBeforeRestorePref = @"WQDiscardBeforeRestore";

BOOL wq_keep_before_restore(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDiscardBeforeRestorePref];
}

void wq_set_keep_before_restore(BOOL keep)
{
    [NSUserDefaults.standardUserDefaults setBool:!keep forKey:kWQDiscardBeforeRestorePref];
}

BOOL wq_refuse_if_deleting_off(UIViewController *host)
{
    if (wq_deleting_allowed()) return NO;
    if (wq_safe_read_only_enabled()) {
        UIAlertController *alert = wq_alert_controller(@"Safe Read-Only Mode Active",
            @"Safe Mode is currently protecting your files from writes and deletions. Turn off Safe Mode on the Home screen to proceed.", UIAlertControllerStyleAlert);
        [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
        [host presentViewController:alert animated:YES completion:nil];
        return YES;
    }
    UIAlertController *alert = wq_alert_controller(@"Deleting is turned off",
        @"Turn on Allow Deleting on the start screen of WQ Glass to delete, clear or clean.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
    return YES;
}

UIAlertController *wq_alert_controller(NSString *title, NSString *message, UIAlertControllerStyle style)
{
    return [UIAlertController alertControllerWithTitle:WQLocalizedNullable(title)
                                               message:WQLocalizedNullable(message)
                                        preferredStyle:style];
}

UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^handler)(UIAlertAction *))
{
    return [UIAlertAction actionWithTitle:WQLocalized(title) style:style handler:handler];
}

void wq_alert(UIViewController *host, NSString *title, NSString *message)
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    UIAlertController *alert = wq_alert_controller(title, message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
}

NSString *wq_size_text(unsigned long long size)
{
    if (size == 0) return @"0 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile];
}

// WQ Prism: iPhone Duo Liquid Glass backdrop with drifting polar-glow shimmers.
@interface WQPrismBackgroundView : UIView
@end

@implementation WQPrismBackgroundView {
    CAGradientLayer *_base;
    CAGradientLayer *_polarBand;
    NSArray<CAGradientLayer *> *_glows;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        _base = [CAGradientLayer layer];
        _base.startPoint = CGPointMake(0.35, 0.0);
        _base.endPoint = CGPointMake(0.65, 1.0);
        [self.layer addSublayer:_base];

        // Subtle sweeping polar-glow ribbon drifting across the sub-zero backdrop.
        _polarBand = [CAGradientLayer layer];
        _polarBand.startPoint = CGPointMake(0.0, 0.25);
        _polarBand.endPoint = CGPointMake(1.0, 0.75);
        [self.layer addSublayer:_polarBand];

        NSMutableArray *glows = [NSMutableArray new];
        for (NSInteger i = 0; i < 4; i++) {
            CAGradientLayer *g = [CAGradientLayer layer];
            g.type = kCAGradientLayerRadial;
            g.startPoint = CGPointMake(0.5, 0.5);
            g.endPoint = CGPointMake(1.0, 1.0);
            [self.layer addSublayer:g];
            [glows addObject:g];
        }
        _glows = glows;
        [self updateColors];
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withAction:@selector(updateColors)];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(updateColors)
                                                   name:WQThemeDidChangeNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(updateShimmerAnimations)
                                                   name:UIAccessibilityReduceMotionStatusDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self updateShimmerAnimations];
}

- (void)updateColors
{
    BOOL classic = wq_theme_is_classic_stock();
    CGFloat glowScale = classic ? 0.12 : 1.0;
    _base.colors = @[(id)wq_theme_canvas_top().CGColor,
                     (id)wq_theme_canvas_mid().CGColor,
                     (id)wq_theme_canvas_cyan().CGColor,
                     (id)wq_theme_canvas_edge().CGColor];
    _base.locations = @[@0.0, @0.32, @0.64, @1.0];

    _polarBand.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[wq_theme_accent() colorWithAlphaComponent:0.10 * glowScale].CGColor,
        (id)[wq_theme_aurora_teal() colorWithAlphaComponent:0.08 * glowScale].CGColor,
        (id)[UIColor clearColor].CGColor,
    ];
    _polarBand.locations = @[@0.0, @0.35, @0.65, @1.0];

    _glows[0].colors = @[(id)[wq_theme_accent() colorWithAlphaComponent:0.20 * glowScale].CGColor, (id)[UIColor clearColor].CGColor];
    _glows[1].colors = @[(id)[wq_theme_aurora_teal() colorWithAlphaComponent:0.12 * glowScale].CGColor, (id)[UIColor clearColor].CGColor];
    _glows[2].colors = @[(id)[wq_theme_canvas_cyan() colorWithAlphaComponent:0.46 * glowScale].CGColor, (id)[UIColor clearColor].CGColor];
    _glows[3].colors = @[(id)[wq_theme_canvas_edge() colorWithAlphaComponent:0.60].CGColor, (id)[UIColor clearColor].CGColor];
    [self updateShimmerAnimations];
}

- (void)updateShimmerAnimations
{
    static NSString *const kBandKey = @"wq.polar.band";
    static NSString *const kDriftKey = @"wq.polar.drift";
    static NSString *const kPulseKey = @"wq.polar.pulse";
    // Keep the theme backdrop completely static at rest so ProMotion drops to 1-10Hz
    // with zero continuous GPU wake-ups.
    [_polarBand removeAnimationForKey:kBandKey];
    for (CAGradientLayer *g in _glows) {
        [g removeAnimationForKey:kDriftKey];
        [g removeAnimationForKey:kPulseKey];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _base.frame = self.bounds;
    _polarBand.frame = self.bounds;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _glows[0].frame = CGRectMake(-w * 0.34, -h * 0.08, w * 0.94, w * 0.94);
    _glows[1].frame = CGRectMake(w * 0.40, -h * 0.12, w * 0.86, w * 0.86);
    _glows[2].frame = CGRectMake(w * 0.24, h * 0.54, w * 0.96, w * 0.96);
    _glows[3].frame = CGRectMake(-w * 0.30, h * 0.68, w * 0.78, w * 0.78);
}

@end

UIView *wq_prism_background_view(void)
{
    return [[WQPrismBackgroundView alloc] initWithFrame:CGRectZero];
}

void wq_prism_install_background(UIViewController *vc)
{
    if (!wq_prism_enabled() || !vc.isViewLoaded) return;
    if ([vc.view viewWithTag:0x57515042]) return;
    if ([vc.view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)vc.view;
        table.backgroundColor = [UIColor clearColor];
        table.backgroundView = wq_prism_background_view();
        return;
    }
    UIView *bg = wq_prism_background_view();
    bg.tag = 0x57515042;
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view insertSubview:bg atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [bg.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
        [bg.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [bg.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [bg.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];
    vc.view.backgroundColor = [UIColor clearColor];
}


static NSString *const kWQClassicDesignPref = @"WQClassicDesign";

BOOL wq_prism_enabled(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQClassicDesignPref];
}

void wq_set_prism_enabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:!enabled forKey:kWQClassicDesignPref];
}

#pragma mark - Glacier Header Shield (Anti-Bleed)

@interface WQGlacierHeaderShieldView : UIView
@end

@implementation WQGlacierHeaderShieldView {
    CAGradientLayer *_backdrop;
    UIVisualEffectView *_frost;
    UIView *_hairline;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.zPosition = 999.0;

        _backdrop = [CAGradientLayer layer];
        _backdrop.locations = @[@0.0, @0.72, @1.0];
        [self.layer addSublayer:_backdrop];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _frost = [[UIVisualEffectView alloc] initWithEffect:blur];
        _frost.alpha = 0.55;
        _frost.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_frost];

        _hairline = [UIView new];
        _hairline.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_hairline];

        [self applyThemeColors];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applyThemeColors)
                                                   name:WQThemeDidChangeNotification
                                                 object:nil];

        [NSLayoutConstraint activateConstraints:@[
            [_frost.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_frost.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_frost.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_frost.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_hairline.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_hairline.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_hairline.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_hairline.heightAnchor constraintEqualToConstant:0.5],
        ]];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applyThemeColors
{
    _backdrop.colors = @[
        (id)[wq_theme_canvas_top() colorWithAlphaComponent:0.98].CGColor,
        (id)[wq_theme_canvas_mid() colorWithAlphaComponent:0.94].CGColor,
        (id)[wq_theme_canvas_top() colorWithAlphaComponent:0.90].CGColor,
    ];
    _hairline.backgroundColor = wq_theme_rim_teal();
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _backdrop.frame = self.bounds;
}

@end

void wq_install_header_shield(UIViewController *vc)
{
    if (!vc || !vc.isViewLoaded) return;
    static const NSInteger kShieldTag = 0x57514853;
    if ([vc.view viewWithTag:kShieldTag]) return;

    WQGlacierHeaderShieldView *shield = [[WQGlacierHeaderShieldView alloc] initWithFrame:CGRectZero];
    shield.tag = kShieldTag;
    shield.translatesAutoresizingMaskIntoConstraints = NO;
    // Rows slide cleanly underneath the fixed Duo header instead of bleeding over it.
    if ([vc.view isKindOfClass:UIScrollView.class]) vc.view.clipsToBounds = YES;
    [vc.view addSubview:shield];

    NSLayoutYAxisAnchor *topAnchor = vc.view.topAnchor;
    NSLayoutXAxisAnchor *leadingAnchor = vc.view.leadingAnchor;
    NSLayoutXAxisAnchor *trailingAnchor = vc.view.trailingAnchor;
    if ([vc.view isKindOfClass:UIScrollView.class]) {
        UILayoutGuide *frameGuide = ((UIScrollView *)vc.view).frameLayoutGuide;
        topAnchor = frameGuide.topAnchor;
        leadingAnchor = frameGuide.leadingAnchor;
        trailingAnchor = frameGuide.trailingAnchor;
    }

    [NSLayoutConstraint activateConstraints:@[
        [shield.topAnchor constraintEqualToAnchor:topAnchor],
        [shield.leadingAnchor constraintEqualToAnchor:leadingAnchor],
        [shield.trailingAnchor constraintEqualToAnchor:trailingAnchor],
        [shield.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
    ]];
}

#pragma mark - iPhone Duo Liquid Glass Confirmation Modal

@interface WQGlassConfirmViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *_Nullable)message
                 confirmTitle:(NSString *)confirmTitle
                  destructive:(BOOL)destructive
                    onConfirm:(void (^)(void))onConfirm;
@end

@implementation WQGlassConfirmViewController {
    NSString *_alertTitle;
    NSString *_alertMessage;
    NSString *_confirmTitle;
    BOOL _destructive;
    void (^_onConfirm)(void);
    UIVisualEffectView *_dimView;
    UIVisualEffectView *_cardView;
}

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 confirmTitle:(NSString *)confirmTitle
                  destructive:(BOOL)destructive
                    onConfirm:(void (^)(void))onConfirm
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _alertTitle = [WQLocalizedNullable(title) copy] ?: @"";
        _alertMessage = [WQLocalizedNullable(message) copy];
        _confirmTitle = [WQLocalized(confirmTitle) copy];
        _destructive = destructive;
        _onConfirm = [onConfirm copy];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _dimView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _dimView.translatesAutoresizingMaskIntoConstraints = NO;
    _dimView.backgroundColor = [UIColor colorWithRed:0.060 green:0.064 blue:0.076 alpha:0.58];
    _dimView.alpha = 0.0;
    [self.view addSubview:_dimView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelTapped)];
    [_dimView addGestureRecognizer:tap];

    _cardView = wq_theme_make_glass_card(24.0, NO);
    _cardView.layer.borderColor = [UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.42].CGColor;
    _cardView.layer.borderWidth = 1.0;
    _cardView.layer.shadowColor = [UIColor colorWithRed:0.150 green:0.592 blue:1.000 alpha:0.22].CGColor;
    _cardView.layer.shadowRadius = 24.0;
    _cardView.layer.shadowOpacity = 1.0;
    _cardView.layer.shadowOffset = CGSizeMake(0, 12);
    _cardView.alpha = 0.0;
    _cardView.transform = UIAccessibilityIsReduceMotionEnabled()
        ? CGAffineTransformIdentity
        : CGAffineTransformMakeScale(0.90, 0.90);
    [self.view addSubview:_cardView];

    // Top icy-aqua specular hairline accent.
    UIView *topAccent = [UIView new];
    topAccent.translatesAutoresizingMaskIntoConstraints = NO;
    topAccent.backgroundColor = _destructive ? [UIColor colorWithRed:0.878 green:0.192 blue:0.294 alpha:1.0] : wq_theme_accent();
    topAccent.layer.cornerRadius = 1.5;
    topAccent.layer.shadowColor = topAccent.backgroundColor.CGColor;
    topAccent.layer.shadowRadius = 6.0;
    topAccent.layer.shadowOpacity = 0.85;
    topAccent.layer.shadowOffset = CGSizeZero;

    UILabel *titleLabel = [UILabel new];
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    titleLabel.textColor = wq_theme_primary_text();
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    titleLabel.text = _alertTitle;

    UILabel *messageLabel = [UILabel new];
    messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    messageLabel.textColor = wq_theme_secondary_text();
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.text = _alertMessage;
    messageLabel.hidden = (_alertMessage.length == 0);

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *cancelCfg = [UIButtonConfiguration plainButtonConfiguration];
    cancelCfg.title = WQLocalized(@"Cancel");
    cancelCfg.baseForegroundColor = wq_theme_detail_text();
    cancelCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cancelCfg.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    cancelCfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *inAttr) {
        NSMutableDictionary *outAttr = [inAttr mutableCopy];
        outAttr[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return outAttr;
    };
    cancelCfg.background.backgroundColor = [UIColor colorWithRed:0.212 green:0.229 blue:0.272 alpha:0.65];
    cancelCfg.background.strokeColor = wq_theme_rim();
    cancelCfg.background.strokeWidth = 0.75;
    cancelBtn.configuration = cancelCfg;
    [cancelBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    confirmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *confirmCfg = [UIButtonConfiguration filledButtonConfiguration];
    confirmCfg.title = _confirmTitle;
    confirmCfg.baseBackgroundColor = _destructive ? [UIColor colorWithRed:0.878 green:0.192 blue:0.294 alpha:1.0] : wq_theme_accent();
    confirmCfg.baseForegroundColor = UIColor.whiteColor;
    confirmCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    confirmCfg.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    confirmCfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *inAttr) {
        NSMutableDictionary *outAttr = [inAttr mutableCopy];
        outAttr[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        return outAttr;
    };
    confirmBtn.configuration = confirmCfg;
    confirmBtn.layer.shadowColor = confirmCfg.baseBackgroundColor.CGColor;
    confirmBtn.layer.shadowRadius = 10.0;
    confirmBtn.layer.shadowOpacity = 0.45;
    confirmBtn.layer.shadowOffset = CGSizeMake(0, 4);
    [confirmBtn addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[cancelBtn, confirmBtn]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 10;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, messageLabel, buttons]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:messageLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [_cardView.contentView addSubview:topAccent];
    [_cardView.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_cardView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_cardView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_cardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_cardView.widthAnchor constraintLessThanOrEqualToConstant:340],
        [_cardView.widthAnchor constraintGreaterThanOrEqualToConstant:286],
        [topAccent.topAnchor constraintEqualToAnchor:_cardView.contentView.topAnchor constant:12],
        [topAccent.centerXAnchor constraintEqualToAnchor:_cardView.contentView.centerXAnchor],
        [topAccent.widthAnchor constraintEqualToConstant:40],
        [topAccent.heightAnchor constraintEqualToConstant:3],
        [stack.topAnchor constraintEqualToAnchor:topAccent.bottomAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:_cardView.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_cardView.contentView.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_cardView.contentView.bottomAnchor constant:-20],
    ]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:0.18 animations:^{
            self->_dimView.alpha = 1.0;
            self->_cardView.alpha = 1.0;
        }];
        return;
    }
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithDampingRatio:0.84 initialVelocity:CGVectorMake(0.3, 0.3)];
    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.28 timingParameters:spring];
    [anim addAnimations:^{
        self->_dimView.alpha = 1.0;
        self->_cardView.alpha = 1.0;
        self->_cardView.transform = CGAffineTransformIdentity;
    }];
    [anim startAnimation];
}

- (void)dismissWithCompletion:(void (^_Nullable)(void))completion
{
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [self dismissViewControllerAnimated:NO completion:completion];
        return;
    }
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_dimView.alpha = 0.0;
        self->_cardView.alpha = 0.0;
        self->_cardView.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL __unused finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (void)cancelTapped
{
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    [self dismissWithCompletion:nil];
}

- (void)confirmTapped
{
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    void (^action)(void) = _onConfirm;
    [self dismissWithCompletion:^{
        if (action) action();
    }];
}

@end

void wq_present_glass_confirm(UIViewController *host,
                              NSString *title,
                              NSString *message,
                              NSString *confirmTitle,
                              BOOL destructive,
                              void (^onConfirm)(void))
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    WQGlassConfirmViewController *modal = [[WQGlassConfirmViewController alloc] initWithTitle:title
                                                                                      message:message
                                                                                 confirmTitle:confirmTitle
                                                                                  destructive:destructive
                                                                                    onConfirm:onConfirm];
    [host presentViewController:modal animated:NO completion:nil];
}
