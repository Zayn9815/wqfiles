//
//  WQTheme.h
//  WQ Glass arctic Glacier Liquid Glass theme (iOS 26)
//
//  One place for the palette, the Liquid Glass surfaces and the global
//  appearance. Appearance only: nothing here touches files, access or data.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Glacier Liquid Glass Palette
UIColor *wq_theme_canvas_top(void);        // #091524 deep sub-zero night-blue
UIColor *wq_theme_canvas_mid(void);        // #122B43 polar navy
UIColor *wq_theme_canvas_cyan(void);       // #1F4D62 arctic cyan
UIColor *wq_theme_canvas_edge(void);       // #04090E dark glacial ice
UIColor *wq_theme_glass_tint(void);        // rgba(16, 42, 69, 0.48) frosty ice-blue
UIColor *wq_theme_rim(void);               // rgba(224, 255, 255, 0.32) snow-silver specular rim
UIColor *wq_theme_rim_teal(void);          // rgba(128, 240, 255, 0.22) translucent icy-teal rim
UIColor *wq_theme_primary_text(void);      // #FFFFFF snow-white
UIColor *wq_theme_secondary_text(void);    // #B0E2FF frosted polar-blue
UIColor *wq_theme_detail_text(void);       // #D1E8FA ice-silver
UIColor *wq_theme_hairline(void);          // rgba(209, 232, 250, 0.16)
UIColor *wq_theme_cta_text(void);          // #071A2B deep glacier navy for white CTA pills
UIColor *wq_theme_active_pill(void);       // #0E5A74 luminous arctic teal pill
UIColor *wq_theme_accent(void);            // #00F5FF glacial aqua for highlights, checks, switches
UIColor *wq_theme_aurora_teal(void);       // #4FFFB0 aurora teal for active/completion glows
UIColor *wq_theme_solid_surface(void);     // #11283F opaque glass stand-in (Reduce Transparency)

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
