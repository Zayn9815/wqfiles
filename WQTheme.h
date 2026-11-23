//
//  WQTheme.h
//  WQ Glass Multi-Theme & UI Style Engine (iOS 26)
//
//  One place for the 5 live-switchable color themes, 3 UI layout presets,
//  Liquid Glass surfaces, and global appearance hooks.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread whenever the selected color theme or UI layout preset changes.
extern NSNotificationName const WQThemeDidChangeNotification;

// NSUserDefaults persistence keys.
extern NSString *const kWQSelectedThemeIDKey;
extern NSString *const kWQSelectedUIStyleIDKey;

// Theme identifiers.
extern NSString *const kWQThemeIDiPhoneDuo;        // @"iphone_duo" (default)
extern NSString *const kWQThemeIDGlacierGlass;     // @"glacier_glass"
extern NSString *const kWQThemeIDCrimsonGlass;     // @"crimson_glass"
extern NSString *const kWQThemeIDAnodizedObsidian; // @"anodized_obsidian"
extern NSString *const kWQThemeIDDesertSand;       // @"desert_sand"
extern NSString *const kWQThemeIDClassicNative;    // @"classic_native"

// UI Layout & Chrome Preset identifiers.
extern NSString *const kWQUIStyleIDDuoHUD;         // @"duo_hud" (default)
extern NSString *const kWQUIStyleIDLiquidGlass;    // @"liquid_glass"
extern NSString *const kWQUIStyleIDCompactPro;     // @"compact_pro"

@interface WQThemeDescriptor : NSObject
@property (nonatomic, copy, readonly) NSString *themeID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, strong, readonly) UIColor *canvasTop;
@property (nonatomic, strong, readonly) UIColor *canvasMid;
@property (nonatomic, strong, readonly) UIColor *accent;
@property (nonatomic, strong, readonly) UIColor *secondaryAccent;
@property (nonatomic, strong, readonly) UIColor *rim;
@end

@interface WQUIStyleDescriptor : NSObject
@property (nonatomic, copy, readonly) NSString *styleID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, copy, readonly) NSString *symbolName;
@end

NSArray<WQThemeDescriptor *> *wq_theme_all_themes(void);
NSArray<WQUIStyleDescriptor *> *wq_theme_all_ui_styles(void);

NSString *wq_theme_selected_id(void);
void wq_theme_set_selected_id(NSString *themeID);

NSString *wq_theme_selected_ui_style_id(void);
void wq_theme_set_selected_ui_style_id(NSString *styleID);

// Helper checks for current UI layout & chrome preset.
BOOL wq_theme_is_compact_pro(void);
BOOL wq_theme_is_full_liquid_glass(void);
BOOL wq_theme_is_classic_stock(void);
BOOL wq_theme_is_desert_sand(void);
CGFloat wq_theme_card_border_width(void);
CGFloat wq_theme_card_corner_radius(CGFloat baseRadius);

// Dynamic palette accessors for the active theme.
UIColor *wq_theme_canvas_top(void);
UIColor *wq_theme_canvas_mid(void);
UIColor *wq_theme_canvas_cyan(void);
UIColor *wq_theme_canvas_edge(void);
UIColor *wq_theme_glass_tint(void);
UIColor *wq_theme_rim(void);
UIColor *wq_theme_rim_teal(void);
UIColor *wq_theme_primary_text(void);
UIColor *wq_theme_secondary_text(void);
UIColor *wq_theme_detail_text(void);
UIColor *wq_theme_hairline(void);
UIColor *wq_theme_cta_text(void);
UIColor *wq_theme_active_pill(void);
UIColor *wq_theme_accent(void);
UIColor *wq_theme_aurora_teal(void);
UIColor *wq_theme_solid_surface(void);
UIColor *wq_theme_sheen_color(void);

// Tinted Liquid Glass (UIGlassEffect). nil when Reduce Transparency is on.
UIVisualEffect *_Nullable wq_theme_glass_effect(BOOL interactive);

// Primary and secondary button configurations for the active theme.
UIButtonConfiguration *wq_theme_primary_button_configuration(void);
UIButtonConfiguration *wq_theme_secondary_button_configuration(void);

void wq_theme_style_primary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);
void wq_theme_style_secondary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);

// Reusable Liquid Glass card container that automatically refreshes on theme change.
UIVisualEffectView *wq_theme_make_glass_card(CGFloat cornerRadius, BOOL interactive);
// Sleek pill filter button.
UIButton *wq_theme_pill_button(NSString *title, BOOL active);
void wq_theme_update_pill_button(UIButton *button, BOOL active);
// Attaches elastic spring press feedback (scale down/rebound) to any control.
void wq_theme_add_spring_tap(UIControl *control);
// Ensures scroll/table views keep generous bottom clearance above the floating tab bar.
void wq_theme_apply_scroll_insets(UIScrollView *scrollView, CGFloat bottomPadding);

// A Liquid Glass container that lets the glass buttons in `content` merge and
// morph into each other. `content` is pinned to the container's edges.
UIView *wq_theme_glass_container(UIView *content, CGFloat spacing);

// Canvas backdrop behind a controller's content (idempotent).
void wq_theme_install_backdrop(UIViewController *vc);

// Refreshes global UIAppearance and every open window/navigation bar/tab bar immediately.
void wq_theme_apply_live_appearance(void);

// Global appearance and hooks. Call once before the first window appears.
void wq_theme_install(void);
void wq_theme_prepare_window(UIWindow *window);

NS_ASSUME_NONNULL_END
