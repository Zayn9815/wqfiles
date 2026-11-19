#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// WQMotion: 3D holographic touch/parallax, natural spring physics (Response 0.32s,
// Damping 0.45), staggered glacial cascades, Bezier glass morphing, aurora shimmer
// progress visualizers, and haptics. Everything degrades gracefully under Reduce
// Motion (no 3D tilt, no elastic overshoot, no stagger, no shimmer) and Reduce
// Transparency.

extern const CGFloat kWQMotionPressScale;           // 0.96
extern const CGFloat kWQMotionEntranceOffset;       // 16 pt
extern const NSTimeInterval kWQMotionStagger;       // 0.030 s (30 ms)
extern const CGFloat kWQMotionSpringResponse;       // 0.32 s
extern const CGFloat kWQMotionSpringDamping;        // 0.45

BOOL wq_motion_reduced(void);

#pragma mark - Haptics
void wq_haptic_impact(UIImpactFeedbackStyle style);
void wq_haptic_selection(void);
void wq_haptic_notify(UINotificationFeedbackType type);

#pragma mark - 3D Holographic Touch & Spring Press Physics
// Scales to 0.96x with interactive 3D finger-tracking tilt, specular ice reflection,
// glacial aqua rim pulse, and elastic rebound (Response 0.32s, Damping 0.45).
// Works for any UIView (controls, Bento cards, pills) without stealing touches.
void wq_motion_add_press(UIView *view);
// Same interactive 3D holographic touch with a custom max tilt angle in radians.
void wq_motion_add_holographic_tilt(UIView *view, CGFloat maxAngleRadians);

#pragma mark - Staggered Glacial Cascades
// Elastic slide-and-rise cascade with 30 ms staggered offset.
void wq_motion_cascade(NSArray<UIView *> *views);
void wq_motion_cascade_with_delay(NSArray<UIView *> *views, NSTimeInterval initialDelay);
// Same cascade for the currently visible cells of a table or collection view.
void wq_motion_cascade_visible(UIScrollView *scrollView);

#pragma mark - Fluid Morphing UI & Glacier Edge Docks
// Reflective "Glacier Edge" floating Liquid Glass dock holding the given views.
UIVisualEffectView *wq_motion_make_dock(NSArray<UIView *> *views, CGFloat spacing);
// Pins `dock` to the bottom safe area of `host`, centred, and adds the scroll inset.
void wq_motion_install_dock(UIView *dock, UIViewController *host, UIScrollView *_Nullable scroll);
// Pin a compact edge-docked Glass Pill Cluster at the bottom-trailing edge above content.
void wq_motion_install_corner_rail(UIView *rail, UIViewController *host, UIScrollView *_Nullable scroll, CGFloat bottomOffset);
// Expand/collapse: the glass shape morphs smoothly with Bezier/spring interpolation.
void wq_motion_set_visible(UIVisualEffectView *glass, BOOL visible, BOOL animated);
// Animates container layout changes (e.g. dock item expansion/collapse) using a
// fluid cubic-Bezier interpolation curve.
void wq_motion_morph_layout(UIView *container, void (^changes)(void));
// Spring morph specifically tuned for search bar & selection HUD transitions
// (Response: 0.32s, Damping: 0.72). Falls back to opacity/instant layout under Reduce Motion.
void wq_motion_spring_morph(UIView *container, void (^changes)(void), void (^_Nullable completion)(void));
// A glass icon/title button suitable for a dock.
UIButton *wq_motion_dock_button(NSString *_Nullable title, NSString *symbolName, NSString *a11yLabel);
// A capsule pill button (snow-white primary or frosted glacier glass) for grouped action docks.
UIButton *wq_motion_dock_pill(NSString *title, NSString *_Nullable symbolName, BOOL prominent);
// Animates filter pill state transitions cleanly.
void wq_motion_set_pill_active(UIButton *button, BOOL active);

#pragma mark - 120Hz Sci-Fi Scrolling Choreography
// 3D Perspective Viewport Wave: scales visible cells/cards (0.96 -> 1.0), applies
// subtle 3D X-axis perspective pitch (max 3.5°), and brightens icy cyan/silver rims
// near the focal center. Disabled cleanly under Reduce Motion.
void wq_motion_apply_scroll_wave(UIScrollView *scrollView);
void wq_motion_apply_scroll_wave_views(UIScrollView *scrollView, NSArray<UIView *> *views);
// Velocity-reactive top/bottom aurora edge glows tied to scroll velocity.
void wq_motion_update_scroll_aurora(UIScrollView *scrollView, UIView *hostView);
void wq_motion_settle_scroll_aurora(UIScrollView *scrollView, UIView *hostView);
// 0.35x vertical parallax depth for top headers as content scrolls beneath them.
void wq_motion_apply_header_parallax(UIScrollView *scrollView, UIView *_Nullable headerView);
// Rate-limited tactile UISelectionFeedbackGenerator micro-tick across scroll boundaries.
void wq_motion_scroll_detent(UIScrollView *scrollView, NSInteger detentIndex);
// Attaches horizontal scroll detents (e.g. horizontal filter pill rails).
void wq_motion_attach_horizontal_detents(UIScrollView *scrollView, CGFloat stepWidth);

#pragma mark - Holographic HUD & Kinetic Telemetry
// Subtle 1pt sci-fi corner-bracket hairlines (#00F5FF / #4FFFB0 at low opacity).
void wq_motion_add_hud_brackets(UIView *view, CGFloat inset, CGFloat armLength);
// Masked CAGradientLayer holographic light-beam sweep across a HUD card or ring.
// Disabled automatically under Reduce Motion.
void wq_motion_add_scan_sweep(UIView *view, BOOL repeating);
void wq_motion_trigger_scan_sweep(UIView *view);
// 120Hz ProMotion cubic ease-out numeric & byte counter roll-up.
void wq_motion_rollup_number(UILabel *label, double targetValue, NSTimeInterval duration,
                             NSString *(^formatter)(double value));
void wq_motion_rollup_bytes(UILabel *label, unsigned long long targetBytes, NSTimeInterval duration);

#pragma mark - Status Transitions
void wq_motion_pop(UIView *view);                 // elastic badge/state-change bounce
void wq_motion_cross_fade(UIView *view, void (^changes)(void));
void wq_motion_pulse_rim(UIView *view);

// Animated aurora ring (percentage 0…1) with northern-lights shimmer overlay,
// spring micro-burst confirmation, and optional checkmark on completion.
@interface WQProgressRingView : UIView
@property (nonatomic) CGFloat progress;            // 0…1
@property (nonatomic) CGFloat lineWidth;
@property (nonatomic, strong) UIColor *trackColor;
@property (nonatomic, strong) UIColor *progressColor;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)showCheckmarkAnimated:(BOOL)animated;
- (void)hideCheckmark;
- (void)emitCompletionBurst;
@end

// Slim animated aurora progress bar with continuous northern-lights shimmer.
@interface WQProgressBarView : UIView
@property (nonatomic, readonly) CGFloat progress;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
