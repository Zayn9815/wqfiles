//
//  WQTheme.m
//  WQ Glass Multi-Theme & UI Style Engine (iOS 26)
//

#import "WQTheme.h"
#import "WQUI.h"
#import <objc/runtime.h>

NSNotificationName const WQThemeDidChangeNotification = @"WQThemeDidChangeNotification";
NSString *const kWQSelectedThemeIDKey = @"WQSelectedThemeID";
NSString *const kWQSelectedUIStyleIDKey = @"WQSelectedUIStyleID";

NSString *const kWQThemeIDiPhoneDuo = @"iphone_duo";
NSString *const kWQThemeIDGlacierGlass = @"glacier_glass";
NSString *const kWQThemeIDCrimsonGlass = @"crimson_glass";
NSString *const kWQThemeIDAnodizedObsidian = @"anodized_obsidian";
NSString *const kWQThemeIDClassicNative = @"classic_native";

NSString *const kWQUIStyleIDDuoHUD = @"duo_hud";
NSString *const kWQUIStyleIDLiquidGlass = @"liquid_glass";
NSString *const kWQUIStyleIDCompactPro = @"compact_pro";

static const NSInteger kWQThemeBackdropTag = 0x57515042;
static const NSInteger kWQThemeSheenTag = 0x57515348;
static const void *kWQThemeSpringKey = &kWQThemeSpringKey;
static const void *kWQThemeCardObserverKey = &kWQThemeCardObserverKey;

static UIColor *wq_rgb(uint32_t rgb, CGFloat alpha)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

typedef struct {
    uint32_t canvasTop;
    uint32_t canvasMid;
    uint32_t canvasCyan;
    uint32_t canvasEdge;
    uint32_t glassTint;   CGFloat glassAlpha;
    uint32_t rim;         CGFloat rimAlpha;
    uint32_t rimTeal;     CGFloat rimTealAlpha;
    uint32_t primaryText;
    uint32_t secondaryText;
    uint32_t detailText;
    uint32_t hairline;    CGFloat hairlineAlpha;
    uint32_t ctaText;
    uint32_t activePill;
    uint32_t accent;
    uint32_t auroraTeal;
    uint32_t solidSurface;
    uint32_t sheen;       CGFloat sheenAlpha;
    uint32_t plainCell;   CGFloat plainCellAlpha;
} WQThemeSpec;

static const WQThemeSpec kSpeciPhoneDuo = {
    .canvasTop     = 0x090A0D,
    .canvasMid     = 0x12151B,
    .canvasCyan    = 0x1A1E26,
    .canvasEdge    = 0x050608,
    .glassTint     = 0x161920, .glassAlpha = 0.72,
    .rim           = 0xFFFFFF, .rimAlpha = 0.30,
    .rimTeal       = 0x5AC8FA, .rimTealAlpha = 0.24,
    .primaryText   = 0xFFFFFF,
    .secondaryText = 0x9BA3B0,
    .detailText    = 0xC3C9D3,
    .hairline      = 0xFFFFFF, .hairlineAlpha = 0.10,
    .ctaText       = 0xFFFFFF,
    .activePill    = 0x0A84FF,
    .accent        = 0x0A84FF,
    .auroraTeal    = 0x5AC8FA,
    .solidSurface  = 0x161920,
    .sheen         = 0xFFFFFF, .sheenAlpha = 0.07,
    .plainCell     = 0x161920, .plainCellAlpha = 0.56,
};

static const WQThemeSpec kSpecGlacierGlass = {
    .canvasTop     = 0x091524,
    .canvasMid     = 0x122B43,
    .canvasCyan    = 0x1F4D62,
    .canvasEdge    = 0x04090E,
    .glassTint     = 0x102A45, .glassAlpha = 0.48,
    .rim           = 0xE0FFFF, .rimAlpha = 0.32,
    .rimTeal       = 0x80F0FF, .rimTealAlpha = 0.22,
    .primaryText   = 0xFFFFFF,
    .secondaryText = 0xB0E2FF,
    .detailText    = 0xD1E8FA,
    .hairline      = 0xD1E8FA, .hairlineAlpha = 0.16,
    .ctaText       = 0x071A2B,
    .activePill    = 0x0E5A74,
    .accent        = 0x00F5FF,
    .auroraTeal    = 0x4FFFB0,
    .solidSurface  = 0x11283F,
    .sheen         = 0xE0FFFF, .sheenAlpha = 0.06,
    .plainCell     = 0x102A45, .plainCellAlpha = 0.36,
};

static const WQThemeSpec kSpecCrimsonGlass = {
    .canvasTop     = 0x1A050A,
    .canvasMid     = 0x380B16,
    .canvasCyan    = 0x4A1020,
    .canvasEdge    = 0x0D0305,
    .glassTint     = 0x3A0C18, .glassAlpha = 0.54,
    .rim           = 0xFFE0E8, .rimAlpha = 0.32,
    .rimTeal       = 0xFF6482, .rimTealAlpha = 0.26,
    .primaryText   = 0xFFFFFF,
    .secondaryText = 0xF4B8C4,
    .detailText    = 0xFFDCE4,
    .hairline      = 0xFFDCE4, .hairlineAlpha = 0.16,
    .ctaText       = 0xFFFFFF,
    .activePill    = 0xA81838,
    .accent        = 0xFF2D55,
    .auroraTeal    = 0xFF6482,
    .solidSurface  = 0x2C0811,
    .sheen         = 0xFFD6E0, .sheenAlpha = 0.07,
    .plainCell     = 0x3A0C18, .plainCellAlpha = 0.42,
};

static const WQThemeSpec kSpecAnodizedObsidian = {
    .canvasTop     = 0x090B0E,
    .canvasMid     = 0x12161D,
    .canvasCyan    = 0x171C26,
    .canvasEdge    = 0x050608,
    .glassTint     = 0x12161D, .glassAlpha = 0.74,
    .rim           = 0xDAE2EE, .rimAlpha = 0.26,
    .rimTeal       = 0x32D74B, .rimTealAlpha = 0.24,
    .primaryText   = 0xFFFFFF,
    .secondaryText = 0x8E96A4,
    .detailText    = 0xC4CCD8,
    .hairline      = 0xFFFFFF, .hairlineAlpha = 0.09,
    .ctaText       = 0x06140A,
    .activePill    = 0x1E7D32,
    .accent        = 0x32D74B,
    .auroraTeal    = 0x63E686,
    .solidSurface  = 0x141820,
    .sheen         = 0xFFFFFF, .sheenAlpha = 0.05,
    .plainCell     = 0x12161D, .plainCellAlpha = 0.60,
};

static const WQThemeSpec kSpecClassicNative = {
    .canvasTop     = 0x000000,
    .canvasMid     = 0x0E0E10,
    .canvasCyan    = 0x1C1C1E,
    .canvasEdge    = 0x000000,
    .glassTint     = 0x1C1C1E, .glassAlpha = 0.88,
    .rim           = 0xFFFFFF, .rimAlpha = 0.14,
    .rimTeal       = 0x0A84FF, .rimTealAlpha = 0.20,
    .primaryText   = 0xFFFFFF,
    .secondaryText = 0x98989F,
    .detailText    = 0xD1D1D6,
    .hairline      = 0x545458, .hairlineAlpha = 0.45,
    .ctaText       = 0xFFFFFF,
    .activePill    = 0x0A84FF,
    .accent        = 0x0A84FF,
    .auroraTeal    = 0x64D2FF,
    .solidSurface  = 0x1C1C1E,
    .sheen         = 0xFFFFFF, .sheenAlpha = 0.02,
    .plainCell     = 0x1C1C1E, .plainCellAlpha = 0.82,
};

@implementation WQThemeDescriptor
- (instancetype)initWithID:(NSString *)themeID title:(NSString *)title subtitle:(NSString *)subtitle spec:(WQThemeSpec)spec
{
    if ((self = [super init])) {
        _themeID = [themeID copy];
        _title = [title copy];
        _subtitle = [subtitle copy];
        _canvasTop = wq_rgb(spec.canvasTop, 1.0);
        _canvasMid = wq_rgb(spec.canvasMid, 1.0);
        _accent = wq_rgb(spec.accent, 1.0);
        _secondaryAccent = wq_rgb(spec.auroraTeal, 1.0);
        _rim = wq_rgb(spec.rim, spec.rimAlpha);
    }
    return self;
}
@end

@implementation WQUIStyleDescriptor
- (instancetype)initWithID:(NSString *)styleID title:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol
{
    if ((self = [super init])) {
        _styleID = [styleID copy];
        _title = [title copy];
        _subtitle = [subtitle copy];
        _symbolName = [symbol copy];
    }
    return self;
}
@end

static NSString *gCachedThemeID;
static NSString *gCachedUIStyleID;

static NSString *wq_normalize_theme_id(NSString *_Nullable raw)
{
    if ([raw isEqualToString:kWQThemeIDGlacierGlass]) return kWQThemeIDGlacierGlass;
    if ([raw isEqualToString:kWQThemeIDCrimsonGlass]) return kWQThemeIDCrimsonGlass;
    if ([raw isEqualToString:kWQThemeIDAnodizedObsidian]) return kWQThemeIDAnodizedObsidian;
    if ([raw isEqualToString:kWQThemeIDClassicNative]) return kWQThemeIDClassicNative;
    return kWQThemeIDiPhoneDuo;
}

static NSString *wq_normalize_ui_style_id(NSString *_Nullable raw)
{
    if ([raw isEqualToString:kWQUIStyleIDLiquidGlass]) return kWQUIStyleIDLiquidGlass;
    if ([raw isEqualToString:kWQUIStyleIDCompactPro]) return kWQUIStyleIDCompactPro;
    return kWQUIStyleIDDuoHUD;
}

NSString *wq_theme_selected_id(void)
{
    if (!gCachedThemeID) {
        gCachedThemeID = wq_normalize_theme_id([NSUserDefaults.standardUserDefaults stringForKey:kWQSelectedThemeIDKey]);
    }
    return gCachedThemeID;
}

NSString *wq_theme_selected_ui_style_id(void)
{
    if (!gCachedUIStyleID) {
        gCachedUIStyleID = wq_normalize_ui_style_id([NSUserDefaults.standardUserDefaults stringForKey:kWQSelectedUIStyleIDKey]);
    }
    return gCachedUIStyleID;
}

static const WQThemeSpec *wq_active_spec(void)
{
    NSString *tid = wq_theme_selected_id();
    if ([tid isEqualToString:kWQThemeIDGlacierGlass]) return &kSpecGlacierGlass;
    if ([tid isEqualToString:kWQThemeIDCrimsonGlass]) return &kSpecCrimsonGlass;
    if ([tid isEqualToString:kWQThemeIDAnodizedObsidian]) return &kSpecAnodizedObsidian;
    if ([tid isEqualToString:kWQThemeIDClassicNative]) return &kSpecClassicNative;
    return &kSpeciPhoneDuo;
}

NSArray<WQThemeDescriptor *> *wq_theme_all_themes(void)
{
    static NSArray<WQThemeDescriptor *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [[WQThemeDescriptor alloc] initWithID:kWQThemeIDiPhoneDuo
                                            title:@"iPhone Duo"
                                         subtitle:@"Space Black & Graphite glass · Apple Sapphire"
                                             spec:kSpeciPhoneDuo],
            [[WQThemeDescriptor alloc] initWithID:kWQThemeIDGlacierGlass
                                            title:@"Glacier Liquid Glass"
                                         subtitle:@"Sub-zero night-blue ice · Glacial Aqua & Aurora"
                                             spec:kSpecGlacierGlass],
            [[WQThemeDescriptor alloc] initWithID:kWQThemeIDCrimsonGlass
                                            title:@"Crimson Liquid Glass"
                                         subtitle:@"Deep burgundy & obsidian ruby · Glowing Crimson"
                                             spec:kSpecCrimsonGlass],
            [[WQThemeDescriptor alloc] initWithID:kWQThemeIDAnodizedObsidian
                                            title:@"Anodized Obsidian"
                                         subtitle:@"Matte obsidian crystal · Surgical Electric Mint"
                                             spec:kSpecAnodizedObsidian],
            [[WQThemeDescriptor alloc] initWithID:kWQThemeIDClassicNative
                                            title:@"Classic Stock"
                                         subtitle:@"Clean native iOS dark surfaces & system blue"
                                             spec:kSpecClassicNative],
        ];
    });
    return list;
}

NSArray<WQUIStyleDescriptor *> *wq_theme_all_ui_styles(void)
{
    static NSArray<WQUIStyleDescriptor *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [[WQUIStyleDescriptor alloc] initWithID:kWQUIStyleIDDuoHUD
                                              title:@"iPhone Duo Split HUD"
                                           subtitle:@"Dual-pane hero, Dynamic Island capsules & optical blur"
                                             symbol:@"rectangle.split.2x1.fill"],
            [[WQUIStyleDescriptor alloc] initWithID:kWQUIStyleIDLiquidGlass
                                              title:@"Full Liquid Glass Capsules"
                                           subtitle:@"Elevated frosted cards, luminous rims & expanded glass rails"
                                             symbol:@"sparkles.rectangle.stack.fill"],
            [[WQUIStyleDescriptor alloc] initWithID:kWQUIStyleIDCompactPro
                                              title:@"Compact Pro Utility"
                                           subtitle:@"Streamlined single-card header & high-density browsing"
                                             symbol:@"list.bullet.rectangle.portrait.fill"],
        ];
    });
    return list;
}

BOOL wq_theme_is_compact_pro(void)      { return [wq_theme_selected_ui_style_id() isEqualToString:kWQUIStyleIDCompactPro]; }
BOOL wq_theme_is_full_liquid_glass(void){ return [wq_theme_selected_ui_style_id() isEqualToString:kWQUIStyleIDLiquidGlass]; }
BOOL wq_theme_is_classic_stock(void)    { return [wq_theme_selected_id() isEqualToString:kWQThemeIDClassicNative]; }

CGFloat wq_theme_card_border_width(void)
{
    if (wq_theme_is_classic_stock()) return 0.5;
    if (wq_theme_is_full_liquid_glass()) return 1.0;
    if (wq_theme_is_compact_pro()) return 0.5;
    return 0.5;
}

CGFloat wq_theme_card_corner_radius(CGFloat baseRadius)
{
    if (wq_theme_is_compact_pro()) return MAX(12.0, baseRadius - 6.0);
    if (wq_theme_is_full_liquid_glass()) return baseRadius + 4.0;
    return baseRadius;
}

#pragma mark - Active Dynamic Palette

UIColor *wq_theme_canvas_top(void)     { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->canvasTop, 1.0); }
UIColor *wq_theme_canvas_mid(void)     { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->canvasMid, 1.0); }
UIColor *wq_theme_canvas_cyan(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->canvasCyan, 1.0); }
UIColor *wq_theme_canvas_edge(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->canvasEdge, 1.0); }
UIColor *wq_theme_glass_tint(void)     { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->glassTint, s->glassAlpha); }
UIColor *wq_theme_rim(void)            { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->rim, wq_theme_is_full_liquid_glass() ? MIN(1.0, s->rimAlpha + 0.12) : s->rimAlpha); }
UIColor *wq_theme_rim_teal(void)       { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->rimTeal, s->rimTealAlpha); }
UIColor *wq_theme_primary_text(void)   { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->primaryText, 1.0); }
UIColor *wq_theme_secondary_text(void) { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->secondaryText, 1.0); }
UIColor *wq_theme_detail_text(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->detailText, 1.0); }
UIColor *wq_theme_hairline(void)       { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->hairline, s->hairlineAlpha); }
UIColor *wq_theme_cta_text(void)       { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->ctaText, 1.0); }
UIColor *wq_theme_active_pill(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->activePill, 1.0); }
UIColor *wq_theme_accent(void)         { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->accent, 1.0); }
UIColor *wq_theme_aurora_teal(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->auroraTeal, 1.0); }
UIColor *wq_theme_solid_surface(void)  { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->solidSurface, 1.0); }
UIColor *wq_theme_sheen_color(void)    { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->sheen, s->sheenAlpha); }

static UIColor *wq_theme_pressed(void)     { return [wq_theme_accent() colorWithAlphaComponent:0.22]; }
static UIColor *wq_theme_plain_cell(void)  { const WQThemeSpec *s = wq_active_spec(); return wq_rgb(s->plainCell, s->plainCellAlpha); }

#pragma mark - Live Theme & UI Switching

static void wq_theme_configure_nav_appearances(UINavigationBarAppearance **stdOut, UINavigationBarAppearance **edgeOut)
{
    UINavigationBarAppearance *navStandard = [UINavigationBarAppearance new];
    [navStandard configureWithOpaqueBackground];
    navStandard.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    navStandard.backgroundColor = [wq_theme_canvas_top() colorWithAlphaComponent:0.92];
    navStandard.shadowColor = wq_theme_rim_teal();
    navStandard.titleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};
    navStandard.largeTitleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};

    UINavigationBarAppearance *navScrollEdge = [UINavigationBarAppearance new];
    [navScrollEdge configureWithDefaultBackground];
    navScrollEdge.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    navScrollEdge.backgroundColor = [wq_theme_canvas_top() colorWithAlphaComponent:0.86];
    navScrollEdge.shadowColor = UIColor.clearColor;
    navScrollEdge.titleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};
    navScrollEdge.largeTitleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};

    if (stdOut) *stdOut = navStandard;
    if (edgeOut) *edgeOut = navScrollEdge;
}

static void wq_theme_refresh_view_hierarchy(UIView *view, UINavigationBarAppearance *navStd, UINavigationBarAppearance *navEdge)
{
    if (!view) return;
    if ([view isKindOfClass:UINavigationBar.class]) {
        UINavigationBar *bar = (UINavigationBar *)view;
        bar.standardAppearance = navStd;
        bar.compactAppearance = navStd;
        bar.scrollEdgeAppearance = navEdge;
        bar.compactScrollEdgeAppearance = navEdge;
        bar.tintColor = wq_theme_primary_text();
    } else if ([view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)view;
        table.separatorColor = table.style == UITableViewStylePlain ? UIColor.clearColor : wq_theme_hairline();
        for (UITableViewCell *cell in table.visibleCells) {
            [cell setNeedsUpdateConfiguration];
        }
    } else if ([view isKindOfClass:UISwitch.class]) {
        ((UISwitch *)view).onTintColor = wq_theme_accent();
    } else if ([view isKindOfClass:UISearchBar.class]) {
        ((UISearchBar *)view).tintColor = wq_theme_accent();
    }
    for (UIView *sub in view.subviews) {
        wq_theme_refresh_view_hierarchy(sub, navStd, navEdge);
    }
}

void wq_theme_apply_live_appearance(void)
{
    [UISwitch appearance].onTintColor = wq_theme_accent();
    [UIProgressView appearance].progressTintColor = wq_theme_accent();
    [UIProgressView appearance].trackTintColor = wq_theme_hairline();
    [UIRefreshControl appearance].tintColor = wq_theme_accent();
    [UIActivityIndicatorView appearance].color = wq_theme_accent();
    [UITableView appearance].separatorColor = wq_theme_hairline();
    [UISearchBar appearance].tintColor = wq_theme_accent();
    [UITextField appearanceWhenContainedInInstancesOfClasses:@[UISearchBar.class]].textColor = wq_theme_primary_text();
    [UILabel appearanceWhenContainedInInstancesOfClasses:@[UITableViewHeaderFooterView.class]].textColor = wq_theme_secondary_text();

    UINavigationBarAppearance *navStd = nil;
    UINavigationBarAppearance *navEdge = nil;
    wq_theme_configure_nav_appearances(&navStd, &navEdge);

    [UINavigationBar appearance].standardAppearance = navStd;
    [UINavigationBar appearance].compactAppearance = navStd;
    [UINavigationBar appearance].scrollEdgeAppearance = navEdge;
    [UINavigationBar appearance].compactScrollEdgeAppearance = navEdge;
    [UINavigationBar appearance].tintColor = wq_theme_primary_text();

    if (!NSThread.isMainThread) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            window.tintColor = wq_theme_accent();
            window.backgroundColor = wq_theme_canvas_edge();
            wq_theme_refresh_view_hierarchy(window, navStd, navEdge);
        }
    }
}

void wq_theme_set_selected_id(NSString *themeID)
{
    NSString *normalized = wq_normalize_theme_id(themeID);
    gCachedThemeID = normalized;
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:kWQSelectedThemeIDKey];
    void (^notify)(void) = ^{
        wq_theme_apply_live_appearance();
        [NSNotificationCenter.defaultCenter postNotificationName:WQThemeDidChangeNotification object:normalized];
    };
    if (NSThread.isMainThread) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}

void wq_theme_set_selected_ui_style_id(NSString *styleID)
{
    NSString *normalized = wq_normalize_ui_style_id(styleID);
    gCachedUIStyleID = normalized;
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:kWQSelectedUIStyleIDKey];
    void (^notify)(void) = ^{
        wq_theme_apply_live_appearance();
        [NSNotificationCenter.defaultCenter postNotificationName:WQThemeDidChangeNotification object:normalized];
    };
    if (NSThread.isMainThread) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}

#pragma mark - Spring interaction

@interface WQThemeSpringTarget : NSObject
@end

@implementation WQThemeSpringTarget
- (void)animate:(UIControl *)sender pressed:(BOOL)pressed
{
    BOOL reduced = UIAccessibilityIsReduceMotionEnabled();
    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.28 dampingRatio:reduced ? 1.0 : 0.84 animations:^{
        CGFloat k = reduced ? 0.99 : 0.97;
        sender.transform = pressed ? CGAffineTransformMakeScale(k, k) : CGAffineTransformIdentity;
        sender.alpha = pressed ? 0.94 : 1.0;
    }];
    anim.interruptible = YES;
    [anim startAnimation];
}
- (void)down:(UIControl *)sender
{
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [self animate:sender pressed:YES];
}
- (void)up:(UIControl *)sender
{
    [self animate:sender pressed:NO];
}
@end

void wq_theme_add_spring_tap(UIControl *control)
{
    if (!control || objc_getAssociatedObject(control, kWQThemeSpringKey)) return;
    WQThemeSpringTarget *target = [WQThemeSpringTarget new];
    objc_setAssociatedObject(control, kWQThemeSpringKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [control addTarget:target action:@selector(up:)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

#pragma mark - Liquid Glass

@interface WQThemeCardObserver : NSObject
@property (nonatomic, weak) UIVisualEffectView *card;
@property (nonatomic) BOOL interactive;
@property (nonatomic) CGFloat baseRadius;
@end

@implementation WQThemeCardObserver
- (instancetype)initWithCard:(UIVisualEffectView *)card interactive:(BOOL)interactive baseRadius:(CGFloat)baseRadius
{
    if ((self = [super init])) {
        _card = card;
        _interactive = interactive;
        _baseRadius = baseRadius;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(refresh)
                                                   name:WQThemeDidChangeNotification
                                                 object:nil];
    }
    return self;
}
- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)refresh
{
    UIVisualEffectView *card = _card;
    if (!card) return;
    UIVisualEffect *effect = wq_theme_glass_effect(_interactive);
    card.effect = effect;
    card.backgroundColor = effect ? UIColor.clearColor : wq_theme_solid_surface();
    card.layer.cornerRadius = wq_theme_card_corner_radius(_baseRadius);
    card.layer.borderWidth = wq_theme_card_border_width();
    card.layer.borderColor = wq_theme_rim().CGColor;
    UIView *sheen = [card.contentView viewWithTag:kWQThemeSheenTag];
    if (sheen) sheen.backgroundColor = wq_theme_sheen_color();
}
@end

UIVisualEffect *wq_theme_glass_effect(BOOL interactive)
{
    if (UIAccessibilityIsReduceTransparencyEnabled() || NSProcessInfo.processInfo.isLowPowerModeEnabled) return nil;
    if (wq_theme_is_classic_stock()) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    }
    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    glass.tintColor = wq_theme_glass_tint();
    glass.interactive = interactive;
    return glass;
}

UIVisualEffectView *wq_theme_make_glass_card(CGFloat cornerRadius, BOOL interactive)
{
    UIVisualEffect *effect = wq_theme_glass_effect(interactive);
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:effect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = wq_theme_card_corner_radius(cornerRadius);
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = wq_theme_card_border_width();
    card.layer.borderColor = wq_theme_rim().CGColor;
    card.clipsToBounds = YES;
    if (!effect) card.backgroundColor = wq_theme_solid_surface();

    UIView *sheen = [UIView new];
    sheen.tag = kWQThemeSheenTag;
    sheen.userInteractionEnabled = NO;
    sheen.frame = card.contentView.bounds;
    sheen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sheen.backgroundColor = wq_theme_sheen_color();
    [card.contentView insertSubview:sheen atIndex:0];

    WQThemeCardObserver *obs = [[WQThemeCardObserver alloc] initWithCard:card interactive:interactive baseRadius:cornerRadius];
    objc_setAssociatedObject(card, kWQThemeCardObserverKey, obs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return card;
}

UIButtonConfiguration *wq_theme_primary_button_configuration(void)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    UIColor *cta = wq_theme_cta_text();
    UIColor *bg = wq_theme_accent();
    cfg.baseBackgroundColor = bg;
    cfg.baseForegroundColor = cta;
    cfg.background.backgroundColor = bg;
    cfg.background.strokeColor = [wq_theme_aurora_teal() colorWithAlphaComponent:0.65];
    cfg.background.strokeWidth = 0.85;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.imagePadding = 7;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary new];
        out[NSForegroundColorAttributeName] = cta;
        if (!out[NSFontAttributeName]) {
            out[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        }
        return out;
    };
    cfg.imageColorTransformer = ^UIColor *(UIColor *__unused color) {
        return cta;
    };
    return cfg;
}

UIButtonConfiguration *wq_theme_secondary_button_configuration(void)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.baseBackgroundColor = wq_theme_glass_tint();
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.imagePadding = 6;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    cfg.background.strokeColor = wq_theme_rim();
    cfg.background.strokeWidth = 0.75;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary new];
        out[NSForegroundColorAttributeName] = UIColor.whiteColor;
        return out;
    };
    cfg.imageColorTransformer = ^UIColor *(UIColor *__unused color) {
        return UIColor.whiteColor;
    };
    return cfg;
}

void wq_theme_style_primary_button(UIButton *button, NSString *title, NSString *symbolName)
{
    if (!button) return;
    UIColor *cta = wq_theme_cta_text();
    UIButtonConfiguration *cfg = wq_theme_primary_button_configuration();
    if (title) {
        cfg.title = title;
        cfg.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSForegroundColorAttributeName: cta,
            NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
        }];
    }
    if (symbolName.length) {
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
        cfg.image = [[UIImage systemImageNamed:symbolName withConfiguration:sym] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = cta;
    [button setTitleColor:cta forState:UIControlStateNormal];
    [button setTitleColor:cta forState:UIControlStateHighlighted];
    [button setTitleColor:cta forState:UIControlStateSelected];
    [button setTitleColor:[cta colorWithAlphaComponent:0.55] forState:UIControlStateDisabled];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.78;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.configurationUpdateHandler = ^(UIButton *b) {
        b.alpha = b.enabled ? 1.0 : 0.56;
    };
    wq_theme_add_spring_tap(button);
}

void wq_theme_style_secondary_button(UIButton *button, NSString *title, NSString *symbolName)
{
    if (!button) return;
    UIButtonConfiguration *cfg = wq_theme_secondary_button_configuration();
    if (title) cfg.title = title;
    if (symbolName.length) {
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        cfg.image = [[UIImage systemImageNamed:symbolName withConfiguration:sym] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:wq_theme_secondary_text() forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.6] forState:UIControlStateDisabled];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.78;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.configurationUpdateHandler = ^(UIButton *b) {
        b.alpha = b.enabled ? 1.0 : 0.48;
    };
    wq_theme_add_spring_tap(button);
}

void wq_theme_update_pill_button(UIButton *button, BOOL active)
{
    if (!button) return;
    UIButtonConfiguration *cfg = [button.configuration copy] ?: [UIButtonConfiguration glassButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.baseBackgroundColor = active ? wq_theme_active_pill() : wq_theme_plain_cell();
    cfg.baseForegroundColor = active ? UIColor.whiteColor : wq_theme_secondary_text();
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(7, 14, 7, 14);
    cfg.background.strokeWidth = active ? 1.0 : 0.75;
    cfg.background.strokeColor = active ? [wq_theme_aurora_teal() colorWithAlphaComponent:0.72] : wq_theme_rim_teal();
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary new];
        out[NSForegroundColorAttributeName] = active ? UIColor.whiteColor : wq_theme_secondary_text();
        out[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:active ? UIFontWeightBold : UIFontWeightSemibold];
        return out;
    };
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = active ? wq_theme_accent() : wq_theme_secondary_text();
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.80;
}

UIButton *wq_theme_pill_button(NSString *title, BOOL active)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.title = title;
    button.configuration = cfg;
    wq_theme_update_pill_button(button, active);
    wq_theme_add_spring_tap(button);
    return button;
}

void wq_theme_apply_scroll_insets(UIScrollView *scrollView, CGFloat bottomPadding)
{
    if (!scrollView) return;
    UIEdgeInsets insets = scrollView.contentInset;
    if (insets.bottom < bottomPadding) {
        insets.bottom = bottomPadding;
        scrollView.contentInset = insets;
    }
    UIEdgeInsets indicators = scrollView.verticalScrollIndicatorInsets;
    if (indicators.bottom < bottomPadding) {
        indicators.bottom = bottomPadding;
        scrollView.verticalScrollIndicatorInsets = indicators;
    }
}

UIView *wq_theme_glass_container(UIView *content, CGFloat spacing)
{
    UIGlassContainerEffect *effect = [UIGlassContainerEffect new];
    effect.spacing = spacing;
    UIVisualEffectView *container = [[UIVisualEffectView alloc] initWithEffect:effect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [container.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:container.contentView.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:container.contentView.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor],
    ]];
    return container;
}

#pragma mark - Canvas

static BOOL wq_theme_is_backdrop(UIView *_Nullable view)
{
    static Class backdropClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ backdropClass = NSClassFromString(@"WQPrismBackgroundView"); });
    return view && backdropClass && [view isKindOfClass:backdropClass];
}

void wq_theme_install_backdrop(UIViewController *vc)
{
    if (!vc.isViewLoaded) return;
    UIView *view = vc.view;
    if ([view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)view;
        if (!wq_theme_is_backdrop(table.backgroundView)) table.backgroundView = wq_prism_background_view();
        table.backgroundColor = UIColor.clearColor;
        table.separatorColor = table.style == UITableViewStylePlain ? UIColor.clearColor : wq_theme_hairline();
        wq_theme_apply_scroll_insets(table, 28.0);
        return;
    }
    if ([view isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)view;
        if (!wq_theme_is_backdrop(collection.backgroundView)) collection.backgroundView = wq_prism_background_view();
        collection.backgroundColor = UIColor.clearColor;
        wq_theme_apply_scroll_insets(collection, 28.0);
        return;
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        view.backgroundColor = wq_theme_canvas_mid();
        wq_theme_apply_scroll_insets((UIScrollView *)view, 28.0);
        return;
    }
    if ([view viewWithTag:kWQThemeBackdropTag]) return;
    UIView *backdrop = wq_prism_background_view();
    backdrop.tag = kWQThemeBackdropTag;
    backdrop.frame = view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view insertSubview:backdrop atIndex:0];
}

#pragma mark - Hooks

static IMP wq_orig_view_did_load;
static IMP wq_orig_cell_update;

static void wq_theme_hook(Class cls, SEL sel, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
}

static void wq_theme_view_did_load(UIViewController *vc, SEL cmd)
{
    if (wq_orig_view_did_load) ((void (*)(id, SEL))wq_orig_view_did_load)(vc, cmd);
    if ([vc isKindOfClass:UINavigationController.class] || [vc isKindOfClass:UITabBarController.class]) return;
    if (![NSStringFromClass(vc.class) hasPrefix:@"WQ"]) return;
    vc.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    wq_theme_install_backdrop(vc);
}

static void wq_theme_cell_update(UITableViewCell *cell, SEL cmd, UICellConfigurationState *state)
{
    if (wq_orig_cell_update) ((void (*)(id, SEL, id))wq_orig_cell_update)(cell, cmd, state);
    UITableView *table = nil;
    UIView *view = cell.superview;
    for (NSInteger depth = 0; view && depth < 4; depth++, view = view.superview) {
        if ([view isKindOfClass:UITableView.class]) { table = (UITableView *)view; break; }
    }
    if (!table || !wq_theme_is_backdrop(table.backgroundView)) return;
    UIBackgroundConfiguration *background = cell.backgroundConfiguration
        ? [cell.backgroundConfiguration copy]
        : [UIBackgroundConfiguration clearConfiguration];
    BOOL pressed = state.isHighlighted || (state.isSelected && !state.isEditing);
    BOOL isPlain = table.style == UITableViewStylePlain;
    BOOL reduceTransparency = UIAccessibilityIsReduceTransparencyEnabled() || NSProcessInfo.processInfo.isLowPowerModeEnabled;
    BOOL compact = wq_theme_is_compact_pro();
    BOOL fullGlass = wq_theme_is_full_liquid_glass();
    if (pressed) {
        background.backgroundColor = wq_theme_pressed();
    } else if (isPlain) {
        background.backgroundColor = reduceTransparency ? wq_theme_solid_surface() : wq_theme_plain_cell();
    } else {
        background.backgroundColor = reduceTransparency ? wq_theme_solid_surface() : wq_theme_glass_tint();
    }
    background.strokeColor = pressed ? [wq_theme_aurora_teal() colorWithAlphaComponent:0.58] : (isPlain ? wq_theme_rim_teal() : wq_theme_rim());
    background.strokeWidth = pressed ? 1.0 : (fullGlass ? 1.0 : (isPlain ? 0.65 : 0.75));
    if (isPlain) {
        background.cornerRadius = compact ? 10.0 : (fullGlass ? 18.0 : 14.0);
        background.backgroundInsets = compact
            ? NSDirectionalEdgeInsetsMake(1.5, 8.0, 1.5, 8.0)
            : NSDirectionalEdgeInsetsMake(3.0, 10.0, 3.0, 10.0);
    }
    background.visualEffect = nil;
    cell.backgroundConfiguration = background;
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        cell.layer.shadowOpacity = 0.0f;
        cell.layer.shouldRasterize = NO;
    }
    cell.clipsToBounds = YES;
    cell.contentView.clipsToBounds = YES;

    if ([cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
        if (!content.textProperties.color) content.textProperties.color = wq_theme_primary_text();
        if (content.secondaryText.length || content.secondaryAttributedText.length)
            content.secondaryTextProperties.color = wq_theme_secondary_text();
        if (compact) {
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(6, 12, 6, 12);
        }
        cell.contentConfiguration = content;
    }
}

void wq_theme_install(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wq_theme_hook(UIViewController.class, @selector(viewDidLoad),
                      (IMP)wq_theme_view_did_load, &wq_orig_view_did_load);
        wq_theme_hook(UITableViewCell.class, @selector(updateConfigurationUsingState:),
                      (IMP)wq_theme_cell_update, &wq_orig_cell_update);
        wq_theme_apply_live_appearance();
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *__unused note) {
            wq_theme_apply_live_appearance();
            [NSNotificationCenter.defaultCenter postNotificationName:WQThemeDidChangeNotification
                                                              object:wq_theme_selected_id()];
        }];
    });
}

void wq_theme_prepare_window(UIWindow *window)
{
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.tintColor = wq_theme_accent();
    window.backgroundColor = wq_theme_canvas_edge();
}
