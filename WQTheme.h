//
//  WQTheme.h
//  WQ Glass crimson Liquid Glass theme (iOS 26)
//
//  One place for the palette, the Liquid Glass surfaces and the global
//  appearance. Appearance only: nothing here touches files, access or data.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Palette
UIColor *wq_theme_canvas_top(void);        // #5C1D1B
UIColor *wq_theme_canvas_mid(void);        // #782623
UIColor *wq_theme_canvas_edge(void);       // #4A1412
UIColor *wq_theme_glass_tint(void);        // rgba(155, 58, 54, 0.45)
UIColor *wq_theme_rim(void);               // rgba(255, 220, 218, 0.28)
UIColor *wq_theme_primary_text(void);      // #FFFFFF
UIColor *wq_theme_secondary_text(void);    // #E6B8B5
UIColor *wq_theme_hairline(void);          // rgba(255, 255, 255, 0.14)
UIColor *wq_theme_cta_text(void);          // #6B211E
UIColor *wq_theme_active_pill(void);       // #9B2627
UIColor *wq_theme_accent(void);            // warm coral for progress, checks, switches
UIColor *wq_theme_solid_surface(void);     // opaque glass stand-in (Reduce Transparency)

// Tinted crimson Liquid Glass (UIGlassEffect). nil when Reduce Transparency is
// on; callers then use wq_theme_solid_surface() as an opaque background.
UIVisualEffect *_Nullable wq_theme_glass_effect(BOOL interactive);

// Primary call to action: white Liquid Glass capsule with deep crimson (#6B211E) text & icon.
UIButtonConfiguration *wq_theme_primary_button_configuration(void);
// Secondary action: translucent crimson Liquid Glass pill with white text.
UIButtonConfiguration *wq_theme_secondary_button_configuration(void);

// Applies a white primary capsule CTA style with dark crimson (#6B211E) foreground
// explicitly locked across UIButtonConfiguration and all UIControlStates so text and
// SF Symbols are never blank.
void wq_theme_style_primary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);
void wq_theme_style_secondary_button(UIButton *button, NSString *_Nullable title, NSString *_Nullable symbolName);

// Reusable crimson Liquid Glass card container with continuous corners & coral rim.
UIVisualEffectView *wq_theme_make_glass_card(CGFloat cornerRadius, BOOL interactive);
// Sleek pill filter button (#9B2627 when active, frosted glass when inactive).
UIButton *wq_theme_pill_button(NSString *title, BOOL active);
void wq_theme_update_pill_button(UIButton *button, BOOL active);
// Attaches spring press feedback (scale down/bounce back) to any control.
void wq_theme_add_spring_tap(UIControl *control);
// Ensures scroll/table views keep generous bottom clearance above the floating tab bar.
void wq_theme_apply_scroll_insets(UIScrollView *scrollView, CGFloat bottomPadding);

// A Liquid Glass container that lets the glass buttons in `content` merge and
// morph into each other. `content` is pinned to the container's edges.
UIView *wq_theme_glass_container(UIView *content, CGFloat spacing);

// Crimson canvas behind a controller's content (idempotent).
void wq_theme_install_backdrop(UIViewController *vc);

// Global appearance and hooks. Call once before the first window appears.
void wq_theme_install(void);
// Dark crimson window: forced dark style, white tint, crimson base color.
void wq_theme_prepare_window(UIWindow *window);

NS_ASSUME_NONNULL_END
