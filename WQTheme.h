//
//  WQTheme.h
//  WQ Glass iPhone Duo dual-surface Liquid Glass theme (iOS 26)
//
//  One place for the palette, the Liquid Glass surfaces and the global
//  appearance. Appearance only: nothing here touches files, access or data.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// iPhone Duo palette: Anodized Space Black canvas (#090A0D -> #12151B), smoked
// graphite glass rgba(22,25,32,0.72), brushed-titanium sheen rgba(255,255,255,0.07),
// titanium text #9BA3B0 and Sapphire (#0A84FF) / Ice-Blue (#5AC8FA) accents.
// (Function names are kept from earlier themes so call sites stay stable.)
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

// Tinted arctic Glacier Liquid Glass (UIGlassEffect). nil when Reduce Transparency
// is on; callers then use wq_theme_solid_surface() as an opaque background.
UIVisualEffect *_Nullable wq_theme_glass_effect(BOOL interactive);

// Primary call to action: snow-white capsule with deep glacier navy (#071A2B) text & icon.
UIButtonConfiguration *wq_theme_primary_button_configuration(void);
// Secondary action: frosty ice-blue Liquid Glass pill with snow-white text.
UIButtonConfiguration *wq_theme_secondary_button_configuration(void);

// Applies a snow-white primary capsule CTA style with deep glacier navy (#071A2B)
// foreground explicitly locked across UIButtonConfiguration and all UIControlStates
// so text and SF Symbols are never blank.
void wq_theme_style_primary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);
void wq_theme_style_secondary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);

// Reusable Glacier Liquid Glass card container with continuous corners & snow-silver rim.
UIVisualEffectView *wq_theme_make_glass_card(CGFloat cornerRadius, BOOL interactive);
// Sleek pill filter button (glowing glacier teal when active, frosted glass when inactive).
UIButton *wq_theme_pill_button(NSString *title, BOOL active);
void wq_theme_update_pill_button(UIButton *button, BOOL active);
// Attaches elastic spring press feedback (scale down/rebound) to any control.
void wq_theme_add_spring_tap(UIControl *control);
// Ensures scroll/table views keep generous bottom clearance above the floating tab bar.
void wq_theme_apply_scroll_insets(UIScrollView *scrollView, CGFloat bottomPadding);

// A Liquid Glass container that lets the glass buttons in `content` merge and
// morph into each other. `content` is pinned to the container's edges.
UIView *wq_theme_glass_container(UIView *content, CGFloat spacing);

// Glacier canvas behind a controller's content (idempotent).
void wq_theme_install_backdrop(UIViewController *vc);

// Global appearance and hooks. Call once before the first window appears.
void wq_theme_install(void);
// Dark arctic window: forced dark style, glacial aqua/white tint, glacial base color.
void wq_theme_prepare_window(UIWindow *window);

NS_ASSUME_NONNULL_END
