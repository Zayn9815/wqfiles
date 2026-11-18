#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// WQMotion: spring physics, staggered entrances, glass morphing, progress
// visuals and haptics. Everything degrades gracefully under Reduce Motion
// (no elastic overshoot, no stagger, no translation) and Reduce Transparency.

extern const CGFloat kWQMotionPressScale;        // 0.96
extern const CGFloat kWQMotionEntranceOffset;    // 14 pt
extern const NSTimeInterval kWQMotionStagger;    // 0.035 s

BOOL wq_motion_reduced(void);

#pragma mark - Haptics
void wq_haptic_impact(UIImpactFeedbackStyle style);
void wq_haptic_selection(void);
void wq_haptic_notify(UINotificationFeedbackType type);

#pragma mark - Press physics
// Scales to 0.96x on touch-down, rebounds with a spring on release and pulses
// the coral rim. Works for any UIView (controls, Bento cards, pills) without
// stealing touches from the view's own targets.
void wq_motion_add_press(UIView *view);

#pragma mark - Entrances
// Fade + 14pt rise, 35 ms apart.
void wq_motion_cascade(NSArray<UIView *> *views);
void wq_motion_cascade_with_delay(NSArray<UIView *> *views, NSTimeInterval initialDelay);
// Same cascade for the currently visible cells of a table or collection view.
void wq_motion_cascade_visible(UIScrollView *scrollView);

#pragma mark - Glass morphing
// Floating Liquid Glass dock (UIGlassContainerEffect) holding the given views.
UIVisualEffectView *wq_motion_make_dock(NSArray<UIView *> *views, CGFloat spacing);
// Pins `dock` to the bottom safe area of `host`, centred, and adds the scroll inset.
void wq_motion_install_dock(UIView *dock, UIViewController *host, UIScrollView *_Nullable scroll);
// Expand/collapse: the glass shape morphs while the content scales and fades.
void wq_motion_set_visible(UIVisualEffectView *glass, BOOL visible, BOOL animated);
// A glass icon/title button suitable for a dock.
UIButton *wq_motion_dock_button(NSString *_Nullable title, NSString *symbolName, NSString *a11yLabel);
// A capsule pill button (primary white or subtle glass) for grouped action docks.
UIButton *wq_motion_dock_pill(NSString *title, NSString *_Nullable symbolName, BOOL prominent);
// Animates filter pill state transitions cleanly.
void wq_motion_set_pill_active(UIButton *button, BOOL active);

#pragma mark - Status transitions
void wq_motion_pop(UIView *view);                 // badge/state-change bounce
void wq_motion_cross_fade(UIView *view, void (^changes)(void));
void wq_motion_pulse_rim(UIView *view);

// Animated ring (percentage 0…1) with an optional checkmark on completion.
@interface WQProgressRingView : UIView
@property (nonatomic) CGFloat progress;            // 0…1
@property (nonatomic) CGFloat lineWidth;
@property (nonatomic, strong) UIColor *trackColor;
@property (nonatomic, strong) UIColor *progressColor;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
- (void)showCheckmarkAnimated:(BOOL)animated;
- (void)hideCheckmark;
@end

// Slim animated progress bar.
@interface WQProgressBarView : UIView
@property (nonatomic, readonly) CGFloat progress;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
