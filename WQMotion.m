#import "WQMotion.h"
#import "WQTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

const CGFloat kWQMotionPressScale = 0.97;
const CGFloat kWQMotionEntranceOffset = 16.0;
const NSTimeInterval kWQMotionStagger = 0.028;
const CGFloat kWQMotionSpringResponse = 0.28;
const CGFloat kWQMotionSpringDamping = 0.84;

static const void *kWQMotionPressKey = &kWQMotionPressKey;
static const void *kWQMotionAnimatorKey = &kWQMotionAnimatorKey;
static const void *kWQMotionScrollStateKey = &kWQMotionScrollStateKey;
static const void *kWQMotionAuroraOverlayKey = &kWQMotionAuroraOverlayKey;
static const void *kWQMotionEdgeBlurKey = &kWQMotionEdgeBlurKey;
static const void *kWQMotionInteractiveHoldKey = &kWQMotionInteractiveHoldKey;
static const void *kWQMotionHorizontalDetentKey = &kWQMotionHorizontalDetentKey;
static const void *kWQMotionScanSweepKey = &kWQMotionScanSweepKey;
static const void *kWQMotionBracketsKey = &kWQMotionBracketsKey;
static const void *kWQMotionRollupKey = &kWQMotionRollupKey;
static const void *kWQMotionRollupLastValKey = &kWQMotionRollupLastValKey;

BOOL wq_motion_reduced(void)
{
    return UIAccessibilityIsReduceMotionEnabled();
}

#pragma mark - Haptics

void wq_haptic_impact(UIImpactFeedbackStyle style)
{
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g impactOccurred];
}

void wq_haptic_selection(void)
{
    UISelectionFeedbackGenerator *g = [UISelectionFeedbackGenerator new];
    [g selectionChanged];
}

void wq_haptic_notify(UINotificationFeedbackType type)
{
    UINotificationFeedbackGenerator *g = [UINotificationFeedbackGenerator new];
    [g notificationOccurred:type];
}

#pragma mark - Physics & Bezier helpers

// Physics-driven spring matching Apple's (response, dampingFraction) model:
// stiffness = (2*pi/response)^2, damping = 2 * dampingFraction * (2*pi/response).
static UIViewPropertyAnimator *wq_motion_spring_physics(CGFloat response, CGFloat dampingFraction, CGFloat velocity, void (^animations)(void))
{
    CGFloat ratio = wq_motion_reduced() ? 1.0 : MAX(0.15, dampingFraction);
    CGFloat omega = (CGFloat)(2.0 * M_PI) / MAX((CGFloat)0.08, response);
    CGFloat stiffness = omega * omega;
    CGFloat damping = 2.0 * ratio * omega;
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithMass:1.0
                                                                            stiffness:stiffness
                                                                              damping:damping
                                                                      initialVelocity:CGVectorMake(velocity, velocity)];
    UIViewPropertyAnimator *a = [[UIViewPropertyAnimator alloc] initWithDuration:0 timingParameters:spring];
    [a addAnimations:animations];
    return a;
}

static UIViewPropertyAnimator *wq_motion_bezier(NSTimeInterval duration, void (^animations)(void))
{
    NSTimeInterval d = wq_motion_reduced() ? MIN(duration, 0.18) : duration;
    UICubicTimingParameters *curve = [[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(0.22, 1.0)
                                                                              controlPoint2:CGPointMake(0.36, 1.0)];
    UIViewPropertyAnimator *a = [[UIViewPropertyAnimator alloc] initWithDuration:d timingParameters:curve];
    [a addAnimations:animations];
    return a;
}

#pragma mark - 3D Holographic Touch & Spring Press Physics

@interface WQMotionPressTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGFloat maxTiltAngle;
@property (nonatomic) BOOL pressed;
@property (nonatomic, strong, nullable) CAGradientLayer *sheenLayer;
- (void)handle:(UILongPressGestureRecognizer *)gesture;
@end

@implementation WQMotionPressTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *__unused)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *__unused)b
{
    return YES;
}

- (CAGradientLayer *)ensureSheenForView:(UIView *)view
{
    if (!view.clipsToBounds && !view.layer.masksToBounds) return nil;
    if (!_sheenLayer) {
        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.type = kCAGradientLayerRadial;
        sheen.startPoint = CGPointMake(0.5, 0.5);
        sheen.endPoint = CGPointMake(1.0, 1.0);
        sheen.colors = @[
            (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.34].CGColor,
            (id)[wq_theme_accent() colorWithAlphaComponent:0.16].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        sheen.locations = @[@0.0, @0.45, @1.0];
        sheen.opacity = 0.0;
        sheen.zPosition = 200;
        _sheenLayer = sheen;
    }
    if (_sheenLayer.superlayer != view.layer) {
        [view.layer addSublayer:_sheenLayer];
    }
    return _sheenLayer;
}

- (CATransform3D)tiltTransformForPoint:(CGPoint)pt inBounds:(CGRect)bounds scale:(CGFloat)scale
{
    if (wq_motion_reduced() || bounds.size.width < 4 || bounds.size.height < 4) {
        return CATransform3DMakeScale(scale, scale, 1.0);
    }
    CGFloat nx = MAX(-1.0, MIN(1.0, (pt.x / bounds.size.width) * 2.0 - 1.0));
    CGFloat ny = MAX(-1.0, MIN(1.0, (pt.y / bounds.size.height) * 2.0 - 1.0));
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / 850.0;
    t = CATransform3DRotate(t, -ny * self.maxTiltAngle, 1.0, 0.0, 0.0);
    t = CATransform3DRotate(t, nx * self.maxTiltAngle, 0.0, 1.0, 0.0);
    t = CATransform3DScale(t, scale, scale, 1.0);
    return t;
}

- (void)updateSheenForView:(UIView *)view point:(CGPoint)pt visible:(BOOL)visible
{
    if (wq_motion_reduced()) {
        if (_sheenLayer) _sheenLayer.opacity = 0.0;
        return;
    }
    CAGradientLayer *sheen = visible ? [self ensureSheenForView:view] : _sheenLayer;
    if (!sheen) return;
    CGFloat diameter = MAX(view.bounds.size.width, view.bounds.size.height) * 1.15;
    if (diameter < 64) diameter = 64;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sheen.bounds = CGRectMake(0, 0, diameter, diameter);
    if (visible) sheen.position = pt;
    [CATransaction commit];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(sheen.presentationLayer ? ((CALayer *)sheen.presentationLayer).opacity : sheen.opacity);
    fade.toValue = @(visible ? 1.0 : 0.0);
    fade.duration = visible ? 0.14 : 0.28;
    [sheen addAnimation:fade forKey:@"wq.sheen.fade"];
    sheen.opacity = visible ? 1.0f : 0.0f;
}

- (void)handle:(UILongPressGestureRecognizer *)gesture
{
    UIView *view = self.view;
    if (!view) return;
    CGPoint pt = [gesture locationInView:view];
    CGFloat scale = wq_motion_reduced() ? 0.99 : kWQMotionPressScale;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.pressed = YES;
            UIViewPropertyAnimator *old = objc_getAssociatedObject(view, kWQMotionAnimatorKey);
            [old stopAnimation:YES];
            CATransform3D target = [self tiltTransformForPoint:pt inBounds:view.bounds scale:scale];
            UIViewPropertyAnimator *down = wq_motion_spring_physics(0.20, 0.82, 0, ^{
                view.transform3D = target;
            });
            objc_setAssociatedObject(view, kWQMotionAnimatorKey, down, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [down startAnimation];
            [self updateSheenForView:view point:pt visible:YES];
            wq_motion_pulse_rim(view);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!wq_motion_reduced()) {
                CATransform3D target = [self tiltTransformForPoint:pt inBounds:view.bounds scale:scale];
                UIViewPropertyAnimator *old = objc_getAssociatedObject(view, kWQMotionAnimatorKey);
                [old stopAnimation:YES];
                [UIView animateWithDuration:0.08 delay:0
                                    options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                                 animations:^{
                    view.transform3D = target;
                } completion:nil];
                [self updateSheenForView:view point:pt visible:YES];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.pressed = NO;
            UIViewPropertyAnimator *old = objc_getAssociatedObject(view, kWQMotionAnimatorKey);
            [old stopAnimation:YES];
            UIViewPropertyAnimator *up = wq_motion_spring_physics(kWQMotionSpringResponse, kWQMotionSpringDamping, 4.0, ^{
                view.transform3D = CATransform3DIdentity;
            });
            objc_setAssociatedObject(view, kWQMotionAnimatorKey, up, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [up startAnimation];
            [self updateSheenForView:view point:pt visible:NO];
            break;
        }
        default: break;
    }
}

@end

void wq_motion_add_holographic_tilt(UIView *view, CGFloat maxAngleRadians)
{
    if (!view) return;
    WQMotionPressTarget *existing = objc_getAssociatedObject(view, kWQMotionPressKey);
    if (existing) {
        existing.maxTiltAngle = maxAngleRadians;
        return;
    }
    WQMotionPressTarget *target = [WQMotionPressTarget new];
    target.view = view;
    target.maxTiltAngle = maxAngleRadians;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handle:)];
    press.minimumPressDuration = 0;
    press.allowableMovement = 32;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = target;
    [view addGestureRecognizer:press];
    objc_setAssociatedObject(view, kWQMotionPressKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void wq_motion_add_press(UIView *view)
{
    wq_motion_add_holographic_tilt(view, 0.036);
}

static UIView *wq_motion_rim_view(UIView *view, int depth)
{
    if (view.layer.borderWidth > 0) return view;
    if (depth <= 0) return nil;
    for (UIView *sub in view.subviews) {
        UIView *found = wq_motion_rim_view(sub, depth - 1);
        if (found) return found;
    }
    return nil;
}

void wq_motion_pulse_rim(UIView *view)
{
    if (wq_motion_reduced() || !view) return;
    UIView *rim = wq_motion_rim_view(view, 2);
    if (!rim) return;
    CALayer *layer = rim.layer;
    CGColorRef original = layer.borderColor;
    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    glow.fromValue = (__bridge id)original;
    glow.toValue = (__bridge id)[wq_theme_accent() colorWithAlphaComponent:0.95].CGColor;
    glow.duration = 0.20;
    glow.autoreverses = YES;
    glow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:glow forKey:@"wq.rim"];
}

#pragma mark - Staggered Glacial Cascades

void wq_motion_cascade_with_delay(NSArray<UIView *> *views, NSTimeInterval initialDelay)
{
    BOOL reduced = wq_motion_reduced();
    NSTimeInterval i = 0;
    for (UIView *v in views) {
        if (!v || v.hidden) continue;
        CGFloat targetAlpha = v.alpha > 0.01 ? v.alpha : 1.0;
        if (reduced) {
            v.alpha = 0;
            [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ v.alpha = targetAlpha; } completion:nil];
            continue;
        }
        CATransform3D rest = v.transform3D;
        v.alpha = 0;
        CATransform3D start = CATransform3DTranslate(rest, 0, kWQMotionEntranceOffset, 0);
        start = CATransform3DScale(start, 0.97, 0.97, 1.0);
        v.transform3D = start;
        // Non-linear glacial stagger (30ms base tapering smoothly for longer lists).
        NSTimeInterval stagger = i * kWQMotionStagger * (1.0 - MIN(i, 10.0) * 0.015);
        UIViewPropertyAnimator *a = wq_motion_spring_physics(0.36, 0.66, 0, ^{
            v.alpha = targetAlpha;
            v.transform3D = rest;
        });
        [a startAnimationAfterDelay:initialDelay + stagger];
        i += 1;
    }
}

void wq_motion_cascade(NSArray<UIView *> *views)
{
    wq_motion_cascade_with_delay(views, 0);
}

void wq_motion_cascade_visible(UIScrollView *scrollView)
{
    NSArray<UIView *> *cells = nil;
    if ([scrollView isKindOfClass:UITableView.class])
        cells = [(UITableView *)scrollView visibleCells];
    else if ([scrollView isKindOfClass:UICollectionView.class])
        cells = [(UICollectionView *)scrollView visibleCells];
    if (!cells.count) return;
    cells = [cells sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(a.frame.origin.y) compare:@(b.frame.origin.y)];
    }];
    // Cap the cascade so a screen full of rows stays crisp and swift.
    if (cells.count > 14) cells = [cells subarrayWithRange:NSMakeRange(0, 14)];
    wq_motion_cascade(cells);
}

#pragma mark - Fluid Morphing UI & Glacier Edge Docks

UIButton *wq_motion_dock_button(NSString *title, NSString *symbolName, NSString *a11yLabel)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    cfg.image = [UIImage systemImageNamed:symbolName withConfiguration:sym];
    cfg.title = title;
    cfg.imagePlacement = NSDirectionalRectEdgeTop;
    cfg.imagePadding = 2;
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary new];
        out[NSFontAttributeName] = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
        return out;
    };
    UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = a11yLabel ?: title;
    button.showsMenuAsPrimaryAction = NO;
    wq_motion_add_press(button);
    return button;
}

UIButton *wq_motion_dock_pill(NSString *title, NSString *symbolName, BOOL prominent)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    if (prominent) {
        wq_theme_style_primary_button(button, title, symbolName);
    } else {
        wq_theme_style_secondary_button(button, title, symbolName);
    }
    wq_motion_add_press(button);
    return button;
}

void wq_motion_set_pill_active(UIButton *button, BOOL active)
{
    if (!button) return;
    if (wq_motion_reduced()) {
        wq_theme_update_pill_button(button, active);
        return;
    }
    UIViewPropertyAnimator *a = wq_motion_spring_physics(kWQMotionSpringResponse, 0.72, 0, ^{
        wq_theme_update_pill_button(button, active);
    });
    [a startAnimation];
    if (active) wq_motion_pulse_rim(button);
}

void wq_motion_morph_layout(UIView *container, void (^changes)(void))
{
    if (!container) { if (changes) changes(); return; }
    UIView *target = container.superview ?: container;
    if (wq_motion_reduced() || !container.window) {
        if (changes) changes();
        [target layoutIfNeeded];
        return;
    }
    UIViewPropertyAnimator *a = wq_motion_bezier(0.32, ^{
        if (changes) changes();
        [target layoutIfNeeded];
    });
    [a startAnimation];
}

void wq_motion_spring_morph(UIView *container, void (^changes)(void), void (^completion)(void))
{
    if (!container) {
        if (changes) changes();
        if (completion) completion();
        return;
    }
    UIView *target = container.superview ?: container;
    if (wq_motion_reduced() || !container.window) {
        if (changes) changes();
        [target layoutIfNeeded];
        if (completion) completion();
        return;
    }
    UIViewPropertyAnimator *a = wq_motion_spring_physics(kWQMotionSpringResponse, kWQMotionSpringDamping, 0, ^{
        if (changes) changes();
        [target layoutIfNeeded];
    });
    if (completion) {
        [a addCompletion:^(UIViewAnimatingPosition __unused pos) { completion(); }];
    }
    [a startAnimation];
}

// Reflective icy top-edge glaze inside Glacier Edge floating docks.
@interface WQGlacierDockGlazeView : UIView
@end

@implementation WQGlacierDockGlazeView {
    CAGradientLayer *_glaze;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [wq_theme_glass_tint() colorWithAlphaComponent:0.30];
        _glaze = [CAGradientLayer layer];
        _glaze.startPoint = CGPointMake(0.0, 0.0);
        _glaze.endPoint = CGPointMake(1.0, 1.0);
        _glaze.colors = @[
            (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.20].CGColor,
            (id)[wq_theme_accent() colorWithAlphaComponent:0.06].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _glaze.locations = @[@0.0, @0.42, @1.0];
        [self.layer addSublayer:_glaze];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _glaze.frame = self.bounds;
}

@end

UIVisualEffectView *wq_motion_make_dock(NSArray<UIView *> *views, CGFloat spacing)
{
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.spacing = spacing;
    stack.layoutMargins = UIEdgeInsetsMake(6, 10, 6, 10);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffectView *dock;
    if (UIAccessibilityIsReduceTransparencyEnabled()) {
        dock = [[UIVisualEffectView alloc] initWithEffect:nil];
        dock.backgroundColor = wq_theme_solid_surface();
    } else {
        UIGlassContainerEffect *container = [UIGlassContainerEffect new];
        container.spacing = 14;
        dock = [[UIVisualEffectView alloc] initWithEffect:container];
    }
    dock.translatesAutoresizingMaskIntoConstraints = NO;
    dock.layer.cornerRadius = 30;
    dock.layer.cornerCurve = kCACornerCurveContinuous;
    dock.layer.borderWidth = 0.85;
    dock.layer.borderColor = wq_theme_rim().CGColor;
    dock.clipsToBounds = YES;
    dock.layer.zPosition = 500;

    if (!UIAccessibilityIsReduceTransparencyEnabled()) {
        WQGlacierDockGlazeView *glaze = [[WQGlacierDockGlazeView alloc] initWithFrame:CGRectZero];
        glaze.translatesAutoresizingMaskIntoConstraints = NO;
        [dock.contentView addSubview:glaze];
        [NSLayoutConstraint activateConstraints:@[
            [glaze.topAnchor constraintEqualToAnchor:dock.contentView.topAnchor],
            [glaze.bottomAnchor constraintEqualToAnchor:dock.contentView.bottomAnchor],
            [glaze.leadingAnchor constraintEqualToAnchor:dock.contentView.leadingAnchor],
            [glaze.trailingAnchor constraintEqualToAnchor:dock.contentView.trailingAnchor],
        ]];
    }

    [dock.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:dock.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:dock.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:dock.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:dock.contentView.trailingAnchor],
    ]];
    return dock;
}

void wq_motion_install_dock(UIView *dock, UIViewController *host, UIScrollView *scroll)
{
    [host.view addSubview:dock];
    dock.layer.zPosition = 500;
    UILayoutGuide *horizGuide = [host.view isKindOfClass:UIScrollView.class]
        ? ((UIScrollView *)host.view).frameLayoutGuide : host.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [dock.centerXAnchor constraintEqualToAnchor:horizGuide.centerXAnchor],
        [dock.bottomAnchor constraintEqualToAnchor:host.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [dock.leadingAnchor constraintGreaterThanOrEqualToAnchor:horizGuide.leadingAnchor constant:14],
        [dock.trailingAnchor constraintLessThanOrEqualToAnchor:horizGuide.trailingAnchor constant:-14],
    ]];
    if (scroll) wq_theme_apply_scroll_insets(scroll, 156.0);
}

void wq_motion_install_corner_rail(UIView *rail, UIViewController *host, UIScrollView *scroll, CGFloat bottomOffset)
{
    [host.view addSubview:rail];
    rail.layer.zPosition = 500;
    CGFloat clearance = MAX(12.0, bottomOffset);
    UILayoutGuide *horizGuide = [host.view isKindOfClass:UIScrollView.class]
        ? ((UIScrollView *)host.view).frameLayoutGuide : host.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [rail.trailingAnchor constraintEqualToAnchor:horizGuide.trailingAnchor constant:-14],
        [rail.bottomAnchor constraintEqualToAnchor:host.view.safeAreaLayoutGuide.bottomAnchor constant:-clearance],
        [rail.leadingAnchor constraintGreaterThanOrEqualToAnchor:horizGuide.leadingAnchor constant:14],
    ]];
    if (scroll) wq_theme_apply_scroll_insets(scroll, 156.0);
}

void wq_motion_set_visible(UIVisualEffectView *glass, BOOL visible, BOOL animated)
{
    if (!glass) return;
    UIGlassContainerEffect *container = nil;
    if (visible && !UIAccessibilityIsReduceTransparencyEnabled()) {
        container = [UIGlassContainerEffect new];
        container.spacing = 14;
    }
    CATransform3D hiddenTransform = wq_motion_reduced()
        ? CATransform3DIdentity
        : CATransform3DScale(CATransform3DMakeTranslation(0, 12, 0), 0.86, 0.86, 1.0);
    void (^apply)(void) = ^{
        glass.effect = container;
        glass.contentView.alpha = visible ? 1 : 0;
        glass.alpha = visible ? 1 : 0;
        glass.transform3D = visible ? CATransform3DIdentity : hiddenTransform;
    };
    if (visible) glass.hidden = NO;
    if (!animated) { apply(); glass.hidden = !visible; return; }
    UIViewPropertyAnimator *a = visible
        ? wq_motion_spring_physics(kWQMotionSpringResponse, kWQMotionSpringDamping, 0, apply)
        : wq_motion_bezier(0.24, apply);
    [a addCompletion:^(UIViewAnimatingPosition __unused p) { if (!visible) glass.hidden = YES; }];
    [a startAnimation];
}

#pragma mark - 120Hz Sci-Fi Scrolling Choreography

@interface WQMotionScrollState : NSObject
@property (nonatomic) CGFloat lastOffsetY;
@property (nonatomic) CFTimeInterval lastTimestamp;
@property (nonatomic) CGFloat smoothedVelocity;
@property (nonatomic) BOOL hasOffset;
@property (nonatomic) NSInteger lastDetent;
@property (nonatomic) BOOL hasDetent;
@property (nonatomic) CFTimeInterval lastDetentTime;
@property (nonatomic, strong) UISelectionFeedbackGenerator *detentGenerator;
@end

@implementation WQMotionScrollState
- (instancetype)init
{
    if ((self = [super init])) {
        _detentGenerator = [UISelectionFeedbackGenerator new];
        [_detentGenerator prepare];
    }
    return self;
}
@end

static WQMotionScrollState *wq_motion_scroll_state(UIScrollView *scrollView)
{
    WQMotionScrollState *state = objc_getAssociatedObject(scrollView, kWQMotionScrollStateKey);
    if (!state) {
        state = [WQMotionScrollState new];
        objc_setAssociatedObject(scrollView, kWQMotionScrollStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

@interface WQAuroraEdgeOverlayView : UIView
@property (nonatomic, strong) CAGradientLayer *topGlow;
@property (nonatomic, strong) CAGradientLayer *bottomGlow;
- (void)setTopIntensity:(CGFloat)top bottomIntensity:(CGFloat)bottom animated:(BOOL)animated;
@end

@implementation WQAuroraEdgeOverlayView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.zPosition = 420;

        _topGlow = [CAGradientLayer layer];
        _topGlow.startPoint = CGPointMake(0.5, 0.0);
        _topGlow.endPoint = CGPointMake(0.5, 1.0);
        _topGlow.colors = @[
            (id)[wq_theme_accent() colorWithAlphaComponent:0.42].CGColor,
            (id)[wq_theme_aurora_teal() colorWithAlphaComponent:0.16].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _topGlow.locations = @[@0.0, @0.42, @1.0];
        _topGlow.opacity = 0.0f;
        [self.layer addSublayer:_topGlow];

        _bottomGlow = [CAGradientLayer layer];
        _bottomGlow.startPoint = CGPointMake(0.5, 1.0);
        _bottomGlow.endPoint = CGPointMake(0.5, 0.0);
        _bottomGlow.colors = @[
            (id)[wq_theme_accent() colorWithAlphaComponent:0.42].CGColor,
            (id)[wq_theme_aurora_teal() colorWithAlphaComponent:0.16].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _bottomGlow.locations = @[@0.0, @0.42, @1.0];
        _bottomGlow.opacity = 0.0f;
        [self.layer addSublayer:_bottomGlow];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat topInset = self.safeAreaInsets.top;
    CGFloat bottomInset = self.safeAreaInsets.bottom;
    CGFloat band = 34.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _topGlow.frame = CGRectMake(0, MAX(0, topInset - 4.0), w, band);
    _bottomGlow.frame = CGRectMake(0, MAX(0, h - bottomInset - band + 4.0), w, band);
    [CATransaction commit];
}

- (void)setTopIntensity:(CGFloat)top bottomIntensity:(CGFloat)bottom animated:(BOOL)animated
{
    float topVal = (float)MAX(0.0, MIN(0.65, top));
    float botVal = (float)MAX(0.0, MIN(0.65, bottom));
    [CATransaction begin];
    if (!animated) {
        [CATransaction setDisableActions:YES];
    } else {
        [CATransaction setAnimationDuration:0.30];
    }
    _topGlow.opacity = topVal;
    _bottomGlow.opacity = botVal;
    [CATransaction commit];
}

@end

static WQAuroraEdgeOverlayView *wq_motion_aurora_overlay(UIScrollView *scrollView, UIView *hostView)
{
    if (!hostView) return nil;
    WQAuroraEdgeOverlayView *overlay = objc_getAssociatedObject(hostView, kWQMotionAuroraOverlayKey);
    if (!overlay) {
        overlay = [[WQAuroraEdgeOverlayView alloc] initWithFrame:hostView.bounds];
        overlay.translatesAutoresizingMaskIntoConstraints = NO;
        [hostView addSubview:overlay];
        if ([hostView isKindOfClass:UIScrollView.class]) {
            UILayoutGuide *frameGuide = ((UIScrollView *)hostView).frameLayoutGuide;
            [NSLayoutConstraint activateConstraints:@[
                [overlay.topAnchor constraintEqualToAnchor:frameGuide.topAnchor],
                [overlay.bottomAnchor constraintEqualToAnchor:frameGuide.bottomAnchor],
                [overlay.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor],
                [overlay.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [overlay.topAnchor constraintEqualToAnchor:hostView.topAnchor],
                [overlay.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
                [overlay.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
                [overlay.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
            ]];
        }
        objc_setAssociatedObject(hostView, kWQMotionAuroraOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (overlay.superview == hostView) {
        [hostView bringSubviewToFront:overlay];
    }
    (void)scrollView;
    return overlay;
}

static inline CGFloat wq_motion_smoothstep(CGFloat edge0, CGFloat edge1, CGFloat x)
{
    CGFloat denom = MAX(0.0001, edge1 - edge0);
    CGFloat t = MAX(0.0, MIN(1.0, (x - edge0) / denom));
    return t * t * (3.0 - 2.0 * t);
}

static void wq_motion_tint_focal_rim(UIView *view, CGFloat focus)
{
    UIView *rim = wq_motion_rim_view(view, 1);
    if (!rim) return;
    CGFloat t = MAX(0.0, MIN(1.0, focus));
    CGFloat a = 0.18 + 0.30 * t * t;
    UIColor *base = t > 0.65 ? wq_theme_rim() : wq_theme_rim_teal();
    rim.layer.borderColor = [base colorWithAlphaComponent:a].CGColor;
}

void wq_motion_apply_scroll_wave_views(UIScrollView *scrollView, NSArray<UIView *> *views)
{
    if (!scrollView || !views.count) return;
    BOOL reduced = wq_motion_reduced();
    CGRect visibleRect = CGRectMake(scrollView.contentOffset.x,
                                    scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
                                    scrollView.bounds.size.width,
                                    MAX(1.0, scrollView.bounds.size.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom));
    CGFloat topEdge = visibleRect.origin.y;
    CGFloat botEdge = CGRectGetMaxY(visibleRect);
    CGFloat topZone = MIN(96.0, MAX(58.0, visibleRect.size.height * 0.16));
    CGFloat botZone = MIN(108.0, MAX(68.0, visibleRect.size.height * 0.18));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *v in views) {
        if (!v || v.hidden || !v.superview) continue;
        WQMotionPressTarget *press = objc_getAssociatedObject(v, kWQMotionPressKey);
        if (press && press.pressed) continue;
        BOOL isCell = [v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UICollectionViewCell.class];
        if (isCell) {
            if (!v.clipsToBounds) v.clipsToBounds = YES;
            if ([v isKindOfClass:UITableViewCell.class]) {
                UIView *cv = ((UITableViewCell *)v).contentView;
                if (!cv.clipsToBounds) cv.clipsToBounds = YES;
            }
        }
        if (v.layer.shouldRasterize) v.layer.shouldRasterize = NO;
        if (reduced) {
            if (!CATransform3DIsIdentity(v.layer.transform)) {
                v.layer.transform = CATransform3DIdentity;
            }
            if (v.layer.opacity < 0.99f) v.layer.opacity = 1.0f;
            continue;
        }

        // Compute un-transformed layout position in scrollView coordinates (no view/layer allocations).
        CGPoint centerInScroll = [v.superview convertPoint:v.center toView:scrollView];
        CGFloat distFromTop = centerInScroll.y - topEdge;
        CGFloat distFromBot = botEdge - centerInScroll.y;

        CGFloat alpha = 1.0;
        CGFloat scale = 1.0;
        CGFloat shiftY = 0.0;
        CGFloat focus = 1.0;

        if (distFromTop < topZone) {
            // Smooth top-edge optical blur dissolve synchronized with upper curtain:
            // opacity 1.0 -> 0.15, scale 1.0 -> 0.975, zero 3D m34 rotation.
            CGFloat t = wq_motion_smoothstep(-16.0, topZone, distFromTop);
            alpha = 0.15 + 0.85 * t;
            scale = 0.975 + 0.025 * t;
            focus = t;
        } else if (distFromBot < botZone) {
            // Smooth bottom emergence out of optical veil:
            // opacity 0.22 -> 1.0, scale 0.972 -> 1.0, vertical settle 6pt -> 0pt.
            CGFloat t = wq_motion_smoothstep(-14.0, botZone, distFromBot);
            alpha = 0.22 + 0.78 * t;
            scale = 0.972 + 0.028 * t;
            shiftY = (1.0 - t) * 6.0;
            focus = t;
        }

        CATransform3D xform = (scale < 0.9995 || shiftY > 0.05)
            ? CATransform3DScale(CATransform3DMakeTranslation(0.0, shiftY, 0.0), scale, scale, 1.0)
            : CATransform3DIdentity;
        v.layer.transform = xform;
        v.layer.opacity = (float)alpha;

        if (!isCell) {
            wq_motion_tint_focal_rim(v, focus);
        }
    }
    [CATransaction commit];
}

void wq_motion_apply_scroll_wave(UIScrollView *scrollView)
{
    if (!scrollView) return;
    NSArray<UIView *> *cells = nil;
    if ([scrollView isKindOfClass:UITableView.class]) {
        cells = [(UITableView *)scrollView visibleCells];
    } else if ([scrollView isKindOfClass:UICollectionView.class]) {
        cells = [(UICollectionView *)scrollView visibleCells];
    }
    if (cells.count) wq_motion_apply_scroll_wave_views(scrollView, cells);
}

void wq_motion_update_scroll_aurora(UIScrollView *scrollView, UIView *hostView)
{
    if (!scrollView || !hostView) return;
    wq_motion_update_edge_blur(scrollView, hostView);
    WQAuroraEdgeOverlayView *overlay = wq_motion_aurora_overlay(scrollView, hostView);
    if (!overlay) return;
    if (wq_motion_reduced()) {
        [overlay setTopIntensity:0 bottomIntensity:0 animated:NO];
        return;
    }
    WQMotionScrollState *state = wq_motion_scroll_state(scrollView);
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat y = scrollView.contentOffset.y;
    if (!state.hasOffset) {
        state.lastOffsetY = y;
        state.lastTimestamp = now;
        state.hasOffset = YES;
        return;
    }
    CFTimeInterval dt = now - state.lastTimestamp;
    if (dt < 0.002) return;
    CGFloat rawVel = (y - state.lastOffsetY) / (CGFloat)dt;   // pts/sec (>0 scrolling down)
    state.lastOffsetY = y;
    state.lastTimestamp = now;
    if (dt > 0.15) state.smoothedVelocity = 0;
    state.smoothedVelocity = state.smoothedVelocity * 0.68 + rawVel * 0.32;

    CGFloat mag = fabs(state.smoothedVelocity);
    CGFloat intensity = MIN(0.58, MAX(0.0, (mag - 120.0) / 1700.0));
    CGFloat topGlow = state.smoothedVelocity < 0 ? intensity : intensity * 0.18;
    CGFloat botGlow = state.smoothedVelocity > 0 ? intensity : intensity * 0.18;
    [overlay setTopIntensity:topGlow bottomIntensity:botGlow animated:NO];
}

void wq_motion_settle_scroll_aurora(UIScrollView *scrollView, UIView *hostView)
{
    if (!scrollView || !hostView) return;
    wq_motion_settle_edge_blur(scrollView, hostView);
    WQMotionScrollState *state = wq_motion_scroll_state(scrollView);
    state.smoothedVelocity = 0;
    WQAuroraEdgeOverlayView *overlay = objc_getAssociatedObject(hostView, kWQMotionAuroraOverlayKey);
    if (overlay) [overlay setTopIntensity:0 bottomIntensity:0 animated:YES];
}

void wq_motion_apply_header_parallax(UIScrollView *scrollView, UIView *headerView)
{
    if (!scrollView || !headerView) return;
    if (wq_motion_reduced()) {
        if (!CGAffineTransformIsIdentity(headerView.transform)) {
            headerView.transform = CGAffineTransformIdentity;
        }
        headerView.alpha = 1.0;
        return;
    }
    // Elastic collapsing Duo header: scrolling up glides and cross-fades the
    // large header away (the frosted nav pill takes over); pulling down at the
    // top stretches it with rubber-band elasticity.
    CGFloat scrollY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    CGFloat h = MAX(1.0, headerView.bounds.size.height);
    if (scrollY > 0) {
        CGFloat shift = MIN(48.0, scrollY * 0.45);
        headerView.transform = CGAffineTransformMakeTranslation(0, shift);
        headerView.alpha = MAX(0.0, 1.0 - scrollY / (h * 0.9));
    } else {
        CGFloat pull = -scrollY;
        // Rubber-band: diminishing returns toward a 10% stretch.
        CGFloat stretch = 0.10 * (1.0 - 1.0 / (1.0 + pull / 90.0));
        CGFloat sc = 1.0 + stretch;
        headerView.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(sc, sc),
                                                       CGAffineTransformMakeTranslation(0, (sc - 1.0) * h * 0.5));
        headerView.alpha = 1.0;
    }
}

void wq_motion_scroll_detent(UIScrollView *scrollView, NSInteger detentIndex)
{
    if (!scrollView) return;
    WQMotionScrollState *state = wq_motion_scroll_state(scrollView);
    if (!state.hasDetent) {
        state.lastDetent = detentIndex;
        state.hasDetent = YES;
        return;
    }
    if (detentIndex == state.lastDetent) return;
    state.lastDetent = detentIndex;
    if (!scrollView.dragging && !scrollView.decelerating) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - state.lastDetentTime < 0.075) return;
    state.lastDetentTime = now;
    [state.detentGenerator selectionChanged];
    [state.detentGenerator prepare];
}

@interface WQMotionHorizontalDetentDelegate : NSObject <UIScrollViewDelegate>
@property (nonatomic) CGFloat stepWidth;
@end

@implementation WQMotionHorizontalDetentDelegate
- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGFloat step = MAX(24.0, self.stepWidth);
    NSInteger bucket = (NSInteger)llround((scrollView.contentOffset.x + scrollView.adjustedContentInset.left) / step);
    wq_motion_scroll_detent(scrollView, bucket);
}
@end

void wq_motion_attach_horizontal_detents(UIScrollView *scrollView, CGFloat stepWidth)
{
    if (!scrollView) return;
    WQMotionHorizontalDetentDelegate *delegate = [WQMotionHorizontalDetentDelegate new];
    delegate.stepWidth = stepWidth > 0 ? stepWidth : 78.0;
    scrollView.delegate = delegate;
    objc_setAssociatedObject(scrollView, kWQMotionHorizontalDetentKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Holographic HUD Brackets, Scanline Sweep & Kinetic Telemetry

@interface WQHUDEdgeBracketsView : UIView
@property (nonatomic) CGFloat inset;
@property (nonatomic) CGFloat armLength;
@end

@implementation WQHUDEdgeBracketsView {
    CAShapeLayer *_cyanCorners;
    CAShapeLayer *_auroraCorners;
}

- (instancetype)initWithFrame:(CGRect)frame inset:(CGFloat)inset armLength:(CGFloat)armLength
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.zPosition = 260;
        _inset = inset;
        _armLength = armLength;

        _cyanCorners = [CAShapeLayer layer];
        _cyanCorners.fillColor = UIColor.clearColor.CGColor;
        _cyanCorners.strokeColor = [wq_theme_accent() colorWithAlphaComponent:0.42].CGColor;
        _cyanCorners.lineWidth = 1.0;
        _cyanCorners.lineCap = kCALineCapSquare;
        [self.layer addSublayer:_cyanCorners];

        _auroraCorners = [CAShapeLayer layer];
        _auroraCorners.fillColor = UIColor.clearColor.CGColor;
        _auroraCorners.strokeColor = [wq_theme_aurora_teal() colorWithAlphaComponent:0.36].CGColor;
        _auroraCorners.lineWidth = 1.0;
        _auroraCorners.lineCap = kCALineCapSquare;
        [self.layer addSublayer:_auroraCorners];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect r = CGRectInset(self.bounds, _inset, _inset);
    if (r.size.width < _armLength * 2.0 || r.size.height < _armLength * 2.0) return;
    CGFloat arm = _armLength;
    CGFloat minX = CGRectGetMinX(r), maxX = CGRectGetMaxX(r);
    CGFloat minY = CGRectGetMinY(r), maxY = CGRectGetMaxY(r);

    // Top-left & bottom-right brackets in glacial aqua (#00F5FF).
    UIBezierPath *cyan = [UIBezierPath bezierPath];
    [cyan moveToPoint:CGPointMake(minX, minY + arm)];
    [cyan addLineToPoint:CGPointMake(minX, minY)];
    [cyan addLineToPoint:CGPointMake(minX + arm, minY)];
    [cyan moveToPoint:CGPointMake(maxX - arm, maxY)];
    [cyan addLineToPoint:CGPointMake(maxX, maxY)];
    [cyan addLineToPoint:CGPointMake(maxX, maxY - arm)];

    // Top-right & bottom-left brackets in aurora teal (#4FFFB0).
    UIBezierPath *aurora = [UIBezierPath bezierPath];
    [aurora moveToPoint:CGPointMake(maxX - arm, minY)];
    [aurora addLineToPoint:CGPointMake(maxX, minY)];
    [aurora addLineToPoint:CGPointMake(maxX, minY + arm)];
    [aurora moveToPoint:CGPointMake(minX, maxY - arm)];
    [aurora addLineToPoint:CGPointMake(minX, maxY)];
    [aurora addLineToPoint:CGPointMake(minX + arm, maxY)];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cyanCorners.frame = self.bounds;
    _cyanCorners.path = cyan.CGPath;
    _auroraCorners.frame = self.bounds;
    _auroraCorners.path = aurora.CGPath;
    [CATransaction commit];
}

@end

void wq_motion_add_hud_brackets(UIView *view, CGFloat inset, CGFloat armLength)
{
    // iPhone Duo is a minimal optical-glass design: the old HUD corner
    // brackets are intentionally not drawn. The API is kept for call sites.
    (void)inset; (void)armLength;
    static const BOOL kDrawBrackets = NO;
    if (!kDrawBrackets) return;
    if (!view) return;
    UIView *host = [view isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)view).contentView : view;
    if (objc_getAssociatedObject(host, kWQMotionBracketsKey)) return;
    WQHUDEdgeBracketsView *brackets = [[WQHUDEdgeBracketsView alloc] initWithFrame:host.bounds inset:inset armLength:armLength];
    brackets.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:brackets];
    [NSLayoutConstraint activateConstraints:@[
        [brackets.topAnchor constraintEqualToAnchor:host.topAnchor],
        [brackets.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [brackets.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [brackets.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    ]];
    objc_setAssociatedObject(host, kWQMotionBracketsKey, brackets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface WQScanSweepOverlayView : UIView
@property (nonatomic) BOOL repeating;
- (void)triggerOnce;
- (void)updateAnimationState;
@end

@implementation WQScanSweepOverlayView {
    CAGradientLayer *_beam;
}

- (instancetype)initWithFrame:(CGRect)frame repeating:(BOOL)repeating
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.zPosition = 240;
        _repeating = repeating;

        _beam = [CAGradientLayer layer];
        _beam.startPoint = CGPointMake(0.0, 0.25);
        _beam.endPoint = CGPointMake(1.0, 0.75);
        _beam.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[wq_theme_accent() colorWithAlphaComponent:0.14].CGColor,
            (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.28].CGColor,
            (id)[wq_theme_aurora_teal() colorWithAlphaComponent:0.14].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _beam.locations = @[@0.0, @0.30, @0.50, @0.70, @1.0];
        _beam.opacity = 0.0f;
        [self.layer addSublayer:_beam];

        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(updateAnimationState)
                                                   name:UIAccessibilityReduceMotionStatusDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = MAX(1.0, self.bounds.size.width);
    CGFloat h = MAX(1.0, self.bounds.size.height);
    CGFloat beamW = MAX(88.0, w * 0.44);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _beam.bounds = CGRectMake(0, 0, beamW, h * 1.4);
    _beam.position = CGPointMake(-beamW, h * 0.5);
    [CATransaction commit];
    [self updateAnimationState];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self updateAnimationState];
}

- (void)updateAnimationState
{
    static NSString *const kSweepKey = @"wq.hud.scan.repeat";
    if (!self.window || wq_motion_reduced() || !_repeating || self.bounds.size.width < 8) {
        [_beam removeAnimationForKey:kSweepKey];
        if (wq_motion_reduced()) _beam.opacity = 0.0f;
        return;
    }
    if ([_beam animationForKey:kSweepKey]) return;
    CGFloat w = self.bounds.size.width;
    CGFloat beamW = _beam.bounds.size.width;
    CAKeyframeAnimation *pos = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    pos.values = @[@(-beamW), @(w + beamW), @(w + beamW)];
    pos.keyTimes = @[@0.0, @0.28, @1.0];
    pos.timingFunctions = @[
        [CAMediaTimingFunction functionWithControlPoints:0.25f :0.1f :0.25f :1.0f],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
    ];
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@0.0, @0.85, @0.95, @0.0, @0.0];
    fade.keyTimes = @[@0.0, @0.06, @0.22, @0.28, @1.0];
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[pos, fade];
    group.duration = 5.4;
    group.repeatCount = HUGE_VALF;
    [_beam addAnimation:group forKey:kSweepKey];
}

- (void)triggerOnce
{
    if (!self.window || wq_motion_reduced() || self.bounds.size.width < 8) return;
    CGFloat w = self.bounds.size.width;
    CGFloat beamW = MAX(88.0, w * 0.44);
    [_beam removeAnimationForKey:@"wq.hud.scan.once"];
    CABasicAnimation *pos = [CABasicAnimation animationWithKeyPath:@"position.x"];
    pos.fromValue = @(-beamW);
    pos.toValue = @(w + beamW);
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@0.0, @1.0, @1.0, @0.0];
    fade.keyTimes = @[@0.0, @0.18, @0.80, @1.0];
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[pos, fade];
    group.duration = 0.92;
    group.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :1.0f :0.36f :1.0f];
    [_beam addAnimation:group forKey:@"wq.hud.scan.once"];
}

@end

void wq_motion_add_scan_sweep(UIView *view, BOOL repeating)
{
    if (!view) return;
    UIView *host = [view isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)view).contentView : view;
    WQScanSweepOverlayView *existing = objc_getAssociatedObject(host, kWQMotionScanSweepKey);
    if (existing) {
        existing.repeating = repeating;
        [existing updateAnimationState];
        return;
    }
    WQScanSweepOverlayView *sweep = [[WQScanSweepOverlayView alloc] initWithFrame:host.bounds repeating:repeating];
    sweep.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:sweep];
    [NSLayoutConstraint activateConstraints:@[
        [sweep.topAnchor constraintEqualToAnchor:host.topAnchor],
        [sweep.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [sweep.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [sweep.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    ]];
    objc_setAssociatedObject(host, kWQMotionScanSweepKey, sweep, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void wq_motion_trigger_scan_sweep(UIView *view)
{
    if (!view || wq_motion_reduced()) return;
    UIView *host = [view isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)view).contentView : view;
    WQScanSweepOverlayView *sweep = objc_getAssociatedObject(host, kWQMotionScanSweepKey);
    if (!sweep) {
        wq_motion_add_scan_sweep(view, NO);
        sweep = objc_getAssociatedObject(host, kWQMotionScanSweepKey);
    }
    [sweep triggerOnce];
}

@interface WQMotionRollupDriver : NSObject
@property (nonatomic, weak) UILabel *label;
@property (nonatomic) double fromValue;
@property (nonatomic) double toValue;
@property (nonatomic) CFTimeInterval startTime;
@property (nonatomic) CFTimeInterval duration;
@property (nonatomic, copy) NSString *(^formatter)(double value);
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
- (void)start;
- (void)stop;
@end

@implementation WQMotionRollupDriver

- (void)start
{
    [self stop];
    _startTime = CACurrentMediaTime();
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop
{
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
}

- (void)tick:(CADisplayLink *__unused)link
{
    UILabel *label = self.label;
    if (!label) {
        [self stop];
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - _startTime;
    double progress = _duration > 0 ? MIN(1.0, MAX(0.0, elapsed / _duration)) : 1.0;
    // Cubic ease-out interpolation for crisp kinetic telemetry roll-up.
    double eased = 1.0 - pow(1.0 - progress, 3.0);
    double current = _fromValue + (_toValue - _fromValue) * eased;
    objc_setAssociatedObject(label, kWQMotionRollupLastValKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (_formatter) label.text = _formatter(current);
    if (progress >= 1.0) {
        objc_setAssociatedObject(label, kWQMotionRollupLastValKey, @(_toValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (_formatter) label.text = _formatter(_toValue);
        [self stop];
    }
}

@end

void wq_motion_rollup_number(UILabel *label, double targetValue, NSTimeInterval duration,
                             NSString *(^formatter)(double value))
{
    if (!label || !formatter) return;
    WQMotionRollupDriver *existing = objc_getAssociatedObject(label, kWQMotionRollupKey);
    [existing stop];
    NSNumber *prevNum = objc_getAssociatedObject(label, kWQMotionRollupLastValKey);
    double fromValue = prevNum ? prevNum.doubleValue : 0.0;
    if (wq_motion_reduced() || duration <= 0.02 || !label.window || fabs(targetValue - fromValue) < 0.001) {
        objc_setAssociatedObject(label, kWQMotionRollupLastValKey, @(targetValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        label.text = formatter(targetValue);
        return;
    }
    WQMotionRollupDriver *driver = [WQMotionRollupDriver new];
    driver.label = label;
    driver.fromValue = fromValue;
    driver.toValue = targetValue;
    driver.duration = duration;
    driver.formatter = formatter;
    objc_setAssociatedObject(label, kWQMotionRollupKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [driver start];
}

void wq_motion_rollup_bytes(UILabel *label, unsigned long long targetBytes, NSTimeInterval duration)
{
    wq_motion_rollup_number(label, (double)targetBytes, duration, ^NSString *(double value) {
        long long bytes = (long long)llround(MAX(0.0, value));
        return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
    });
}

#pragma mark - Status transitions

void wq_motion_pop(UIView *view)
{
    if (!view || wq_motion_reduced()) return;
    view.transform3D = CATransform3DMakeScale(0.74, 0.74, 1.0);
    UIViewPropertyAnimator *a = wq_motion_spring_physics(kWQMotionSpringResponse, kWQMotionSpringDamping, 6.0, ^{
        view.transform3D = CATransform3DIdentity;
    });
    [a startAnimation];
}

void wq_motion_cross_fade(UIView *view, void (^changes)(void))
{
    if (!view || wq_motion_reduced()) { if (changes) changes(); return; }
    [UIView transitionWithView:view duration:0.26
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:changes completion:nil];
}

#pragma mark - Aurora Progress Ring

@implementation WQProgressRingView {
    CAShapeLayer *_track;
    CALayer *_arcHost;
    CAGradientLayer *_aurora;
    CAGradientLayer *_scanBeam;
    CAShapeLayer *_arc;
    CAShapeLayer *_check;
    BOOL _checkVisible;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitUpdatesFrequently;
        _lineWidth = 7;
        _trackColor = wq_theme_hairline();
        _progressColor = wq_theme_accent();

        _track = [CAShapeLayer layer];
        _track.fillColor = UIColor.clearColor.CGColor;
        _track.lineCap = kCALineCapRound;
        _track.lineJoin = kCALineJoinRound;
        [self.layer addSublayer:_track];

        // Aurora northern-lights gradient masked by the stationary progress arc.
        _arcHost = [CALayer layer];
        [self.layer addSublayer:_arcHost];

        _aurora = [CAGradientLayer layer];
        _aurora.startPoint = CGPointMake(0.0, 0.0);
        _aurora.endPoint = CGPointMake(1.0, 1.0);
        [_arcHost addSublayer:_aurora];

        // Masked holographic scanline sweep gliding across the active ring arc.
        _scanBeam = [CAGradientLayer layer];
        _scanBeam.startPoint = CGPointMake(0.5, 0.0);
        _scanBeam.endPoint = CGPointMake(0.5, 1.0);
        _scanBeam.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.65].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _scanBeam.locations = @[@(-0.4), @(-0.2), @(0.0)];
        _scanBeam.opacity = 0.0f;
        [_arcHost addSublayer:_scanBeam];

        _arc = [CAShapeLayer layer];
        _arc.fillColor = UIColor.clearColor.CGColor;
        _arc.strokeColor = UIColor.whiteColor.CGColor;
        _arc.lineCap = kCALineCapRound;
        _arc.lineJoin = kCALineJoinRound;
        _arc.strokeEnd = 0;
        _arcHost.mask = _arc;

        _check = [CAShapeLayer layer];
        _check.fillColor = UIColor.clearColor.CGColor;
        _check.lineCap = kCALineCapRound;
        _check.lineJoin = kCALineJoinRound;
        _check.strokeEnd = 0;
        [self.layer addSublayer:_check];

        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowRadius = 7.0;
        self.layer.shadowOpacity = 0.50;

        [self refreshColors];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(updateAuroraShimmer)
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
    [self updateAuroraShimmer];
}

- (void)updateAuroraShimmer
{
    static NSString *const kAuroraSpinKey = @"wq.aurora.shimmer";
    static NSString *const kRingScanKey = @"wq.ring.scanline";
    if (!self.window || wq_motion_reduced()) {
        [_aurora removeAnimationForKey:kAuroraSpinKey];
        [_scanBeam removeAnimationForKey:kRingScanKey];
        _scanBeam.opacity = 0.0f;
        return;
    }
    if (![_aurora animationForKey:kAuroraSpinKey]) {
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @0;
        rot.toValue = @(M_PI * 2.0);
        rot.duration = 4.2;
        rot.repeatCount = HUGE_VALF;
        [_aurora addAnimation:rot forKey:kAuroraSpinKey];
    }
    if (![_scanBeam animationForKey:kRingScanKey]) {
        _scanBeam.opacity = 0.72f;
        CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"locations"];
        sweep.fromValue = @[@(-0.45), @(-0.20), @(0.05)];
        sweep.toValue = @[@(0.95), @(1.20), @(1.45)];
        sweep.duration = 2.6;
        sweep.repeatCount = HUGE_VALF;
        sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_scanBeam addAnimation:sweep forKey:kRingScanKey];
    }
}

- (void)refreshColors
{
    UIColor *base = _progressColor ?: wq_theme_accent();
    _track.strokeColor = _trackColor.CGColor;
    _aurora.colors = @[
        (id)base.CGColor,
        (id)wq_theme_aurora_teal().CGColor,
        (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:1.0].CGColor,
        (id)base.CGColor,
    ];
    _aurora.locations = @[@0.0, @0.38, @0.70, @1.0];
    _check.strokeColor = UIColor.whiteColor.CGColor;
    _track.lineWidth = _arc.lineWidth = _lineWidth;
    _check.lineWidth = MAX(3, _lineWidth * 0.55);
    self.layer.shadowColor = base.CGColor;
}

- (void)setTrackColor:(UIColor *)c { _trackColor = c; [self refreshColors]; }
- (void)setProgressColor:(UIColor *)c { _progressColor = c; [self refreshColors]; }
- (void)setLineWidth:(CGFloat)w { _lineWidth = w; [self refreshColors]; [self setNeedsLayout]; }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = CGRectInset(self.bounds, _lineWidth / 2, _lineWidth / 2);
    CGFloat d = MIN(b.size.width, b.size.height);
    if (d <= 0) return;
    CGRect square = CGRectMake(CGRectGetMidX(self.bounds) - d / 2, CGRectGetMidY(self.bounds) - d / 2, d, d);
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(square), CGRectGetMidY(square))
                                                          radius:d / 2 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    _track.path = _arc.path = circle.CGPath;
    _track.frame = _arcHost.frame = self.bounds;
    _arc.frame = _arcHost.bounds;
    _scanBeam.frame = _arcHost.bounds;
    CGFloat diag = hypot(self.bounds.size.width, self.bounds.size.height);
    _aurora.bounds = CGRectMake(0, 0, diag, diag);
    _aurora.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _check.frame = self.bounds;

    UIBezierPath *tick = [UIBezierPath bezierPath];
    CGFloat cx = CGRectGetMidX(square), cy = CGRectGetMidY(square), r = d * 0.2;
    [tick moveToPoint:CGPointMake(cx - r, cy)];
    [tick addLineToPoint:CGPointMake(cx - r * 0.25, cy + r * 0.75)];
    [tick addLineToPoint:CGPointMake(cx + r, cy - r * 0.7)];
    _check.path = tick.CGPath;
}

- (void)setProgress:(CGFloat)progress { [self setProgress:progress animated:NO]; }

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated
{
    progress = MAX(0, MIN(1, progress));
    CGFloat from = _arc.presentationLayer ? ((CAShapeLayer *)_arc.presentationLayer).strokeEnd : _arc.strokeEnd;
    _progress = progress;
    self.accessibilityValue = [NSString stringWithFormat:@"%d%%", (int)lround(progress * 100)];
    [_arc removeAnimationForKey:@"wq.progress"];
    if (animated && !wq_motion_reduced()) {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"strokeEnd"];
        spring.fromValue = @(from);
        spring.toValue = @(progress);
        spring.damping = 17.6;
        spring.stiffness = 385.0;
        spring.mass = 1.0;
        spring.duration = MIN(spring.settlingDuration, 0.85);
        [_arc addAnimation:spring forKey:@"wq.progress"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _arc.strokeEnd = progress;
    [CATransaction commit];
}

- (void)emitCompletionBurst
{
    if (wq_motion_reduced() || !self.window) return;
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    if (d < 12) return;
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    // Masked luminous scanline pulse along the circular progress arc.
    CABasicAnimation *burstSweep = [CABasicAnimation animationWithKeyPath:@"locations"];
    burstSweep.fromValue = @[@(-0.45), @(-0.20), @(0.05)];
    burstSweep.toValue = @[@(0.95), @(1.20), @(1.45)];
    burstSweep.duration = 0.62;
    burstSweep.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :1.0f :0.36f :1.0f];
    [_scanBeam addAnimation:burstSweep forKey:@"wq.ring.burstSweep"];

    // Expanding glacial aura ring shockwave.
    CAShapeLayer *wave = [CAShapeLayer layer];
    wave.frame = self.bounds;
    wave.path = [UIBezierPath bezierPathWithArcCenter:center radius:d * 0.48 startAngle:0 endAngle:M_PI * 2 clockwise:YES].CGPath;
    wave.fillColor = UIColor.clearColor.CGColor;
    wave.strokeColor = wq_theme_aurora_teal().CGColor;
    wave.lineWidth = 2.0;
    wave.opacity = 0.0;
    [self.layer addSublayer:wave];

    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.22f :1.0f :0.36f :1.0f];

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [wave removeFromSuperlayer];
    }];
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @0.92;
    scale.toValue = @1.45;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.85;
    fade.toValue = @0.0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade];
    group.duration = 0.55;
    group.timingFunction = ease;
    [wave addAnimation:group forKey:@"wq.burst.wave"];
    [CATransaction commit];

    // 8 radial crystalline ice sparks.
    for (NSInteger i = 0; i < 8; i++) {
        CGFloat angle = (CGFloat)i * (CGFloat)(M_PI / 4.0);
        CALayer *spark = [CALayer layer];
        spark.bounds = CGRectMake(0, 0, 4.0, 4.0);
        spark.cornerRadius = 2.0;
        spark.backgroundColor = (i % 2 == 0 ? wq_theme_accent() : wq_theme_aurora_teal()).CGColor;
        spark.position = center;
        spark.opacity = 0.0;
        [self.layer addSublayer:spark];

        CGPoint p0 = CGPointMake(center.x + cos(angle) * (d * 0.44), center.y + sin(angle) * (d * 0.44));
        CGPoint p1 = CGPointMake(center.x + cos(angle) * (d * 0.78), center.y + sin(angle) * (d * 0.78));

        [CATransaction begin];
        [CATransaction setCompletionBlock:^{
            [spark removeFromSuperlayer];
        }];
        CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
        move.fromValue = [NSValue valueWithCGPoint:p0];
        move.toValue = [NSValue valueWithCGPoint:p1];
        CABasicAnimation *spFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        spFade.fromValue = @0.95;
        spFade.toValue = @0.0;
        CABasicAnimation *spScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        spScale.fromValue = @1.15;
        spScale.toValue = @0.2;
        CAAnimationGroup *sg = [CAAnimationGroup animation];
        sg.animations = @[move, spFade, spScale];
        sg.duration = 0.52;
        sg.timingFunction = ease;
        [spark addAnimation:sg forKey:@"wq.burst.spark"];
        [CATransaction commit];
    }
}

- (void)showCheckmarkAnimated:(BOOL)animated
{
    if (_checkVisible) return;   // table reloads must not replay the animation
    _checkVisible = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _check.strokeEnd = 1;
    [CATransaction commit];
    if (animated && !wq_motion_reduced()) {
        CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        draw.fromValue = @0;
        draw.toValue = @1;
        draw.duration = 0.34;
        draw.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22f :1.0f :0.36f :1.0f];
        [_check addAnimation:draw forKey:@"wq.check"];
        wq_motion_pop(self);
        [self emitCompletionBurst];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    }
}

- (void)hideCheckmark
{
    _checkVisible = NO;
    [_check removeAllAnimations];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _check.strokeEnd = 0;
    [CATransaction commit];
}

@end

#pragma mark - Aurora Progress Bar

@implementation WQProgressBarView {
    UIView *_fill;
    CAGradientLayer *_fillGradient;
    CAGradientLayer *_shimmer;
    CGFloat _value;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = wq_theme_hairline();
        self.layer.cornerRadius = 3.5;
        self.clipsToBounds = YES;
        self.isAccessibilityElement = YES;

        _fill = [UIView new];
        _fill.layer.cornerRadius = 3.5;
        _fill.clipsToBounds = YES;
        [self addSubview:_fill];

        _fillGradient = [CAGradientLayer layer];
        _fillGradient.startPoint = CGPointMake(0.0, 0.5);
        _fillGradient.endPoint = CGPointMake(1.0, 0.5);
        _fillGradient.colors = @[
            (id)wq_theme_accent().CGColor,
            (id)wq_theme_aurora_teal().CGColor,
        ];
        [_fill.layer addSublayer:_fillGradient];

        _shimmer = [CAGradientLayer layer];
        _shimmer.startPoint = CGPointMake(0.0, 0.5);
        _shimmer.endPoint = CGPointMake(1.0, 0.5);
        _shimmer.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor colorWithRed:0.898 green:0.951 blue:1.000 alpha:0.65].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _shimmer.locations = @[@(-0.4), @(-0.2), @(0.0)];
        [_fill.layer addSublayer:_shimmer];

        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(updateShimmer)
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
    [self updateShimmer];
}

- (void)updateShimmer
{
    static NSString *const kShimmerKey = @"wq.bar.shimmer";
    if (!self.window || wq_motion_reduced()) {
        [_shimmer removeAnimationForKey:kShimmerKey];
        return;
    }
    if (![_shimmer animationForKey:kShimmerKey]) {
        CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"locations"];
        sweep.fromValue = @[@(-0.45), @(-0.20), @(0.05)];
        sweep.toValue = @[@(0.95), @(1.20), @(1.45)];
        sweep.duration = 1.9;
        sweep.repeatCount = HUGE_VALF;
        sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_shimmer addAnimation:sweep forKey:kShimmerKey];
    }
}

- (CGFloat)progress { return _value; }

- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 7); }

- (void)layoutSubviews
{
    [super layoutSubviews];
    _fill.frame = CGRectMake(0, 0, self.bounds.size.width * _value, self.bounds.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillGradient.frame = _fill.bounds;
    _shimmer.frame = _fill.bounds;
    [CATransaction commit];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated
{
    _value = MAX(0, MIN(1, progress));
    self.accessibilityValue = [NSString stringWithFormat:@"%d%%", (int)lround(_value * 100)];
    void (^apply)(void) = ^{
        self->_fill.frame = CGRectMake(0, 0, self.bounds.size.width * self->_value, self.bounds.size.height);
        self->_fillGradient.frame = self->_fill.bounds;
        self->_shimmer.frame = self->_fill.bounds;
    };
    if (!animated) { apply(); return; }
    UIViewPropertyAnimator *a = wq_motion_spring_physics(0.36, 0.78, 0, apply);
    [a startAnimation];
}

@end

#pragma mark - iPhone Duo Scroll-Exit Optical Blur Curtains

@interface WQDuoEdgeBlurCurtainView : UIView
- (void)setTopStrength:(CGFloat)top bottomStrength:(CGFloat)bottom animated:(BOOL)animated;
@end

@implementation WQDuoEdgeBlurCurtainView {
    UIVisualEffectView *_topBlur;
    UIVisualEffectView *_bottomBlur;
    CAGradientLayer *_topMask;
    CAGradientLayer *_bottomMask;
    CGFloat _lastTop;
    CGFloat _lastBottom;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.zPosition = 550.0;
        self.layer.shouldRasterize = NO;
        _lastTop = -1.0;
        _lastBottom = -1.0;

        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];

        // Multi-stop 5-stop progressive optical blur dissolve at the top viewport edge.
        _topBlur = [[UIVisualEffectView alloc] initWithEffect:effect];
        _topBlur.userInteractionEnabled = NO;
        _topBlur.layer.opacity = 0.0f;
        _topBlur.layer.shouldRasterize = NO;

        _topMask = [CAGradientLayer layer];
        _topMask.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:1.00].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.78].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.44].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.14].CGColor,
            (id)[UIColor clearColor].CGColor,
        ];
        _topMask.locations = @[@0.0, @0.22, @0.48, @0.76, @1.0];
        _topBlur.layer.mask = _topMask;
        [self addSubview:_topBlur];

        // Multi-stop 5-stop progressive optical emergence veil at the bottom viewport edge.
        _bottomBlur = [[UIVisualEffectView alloc] initWithEffect:effect];
        _bottomBlur.userInteractionEnabled = NO;
        _bottomBlur.layer.opacity = 0.0f;
        _bottomBlur.layer.shouldRasterize = NO;

        _bottomMask = [CAGradientLayer layer];
        _bottomMask.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.14].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.44].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.78].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:1.00].CGColor,
        ];
        _bottomMask.locations = @[@0.0, @0.24, @0.52, @0.78, @1.0];
        _bottomBlur.layer.mask = _bottomMask;
        [self addSubview:_bottomBlur];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat topInset = self.safeAreaInsets.top;
    CGFloat botInset = self.safeAreaInsets.bottom;
    CGFloat topH = 58.0;
    CGFloat botH = 74.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _topBlur.frame = CGRectMake(0, topInset, w, topH);
    _bottomBlur.frame = CGRectMake(0, MAX(0, h - botInset - botH), w, botH);
    _topMask.frame = _topBlur.bounds;
    _bottomMask.frame = _bottomBlur.bounds;
    [CATransaction commit];
}

- (void)setTopStrength:(CGFloat)top bottomStrength:(CGFloat)bottom animated:(BOOL)animated
{
    CGFloat t = MAX(0.0, MIN(0.96, top));
    CGFloat b = MAX(0.0, MIN(0.94, bottom));
    if (!animated && fabs(t - _lastTop) < 0.008 && fabs(b - _lastBottom) < 0.008) return;
    _lastTop = t;
    _lastBottom = b;
    if (!animated) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _topBlur.layer.opacity = (float)t;
        _bottomBlur.layer.opacity = (float)b;
        [CATransaction commit];
        return;
    }
    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.26 dampingRatio:0.86 animations:^{
        self->_topBlur.layer.opacity = (float)t;
        self->_bottomBlur.layer.opacity = (float)b;
    }];
    [anim startAnimation];
}

@end

void wq_motion_install_edge_blur(UIScrollView *scrollView, UIView *hostView)
{
    if (!scrollView || !hostView) return;
    if (objc_getAssociatedObject(hostView, kWQMotionEdgeBlurKey)) return;

    WQDuoEdgeBlurCurtainView *curtain = [[WQDuoEdgeBlurCurtainView alloc] initWithFrame:hostView.bounds];
    curtain.translatesAutoresizingMaskIntoConstraints = NO;
    [hostView addSubview:curtain];

    if ([hostView isKindOfClass:UIScrollView.class]) {
        UILayoutGuide *frameGuide = ((UIScrollView *)hostView).frameLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [curtain.topAnchor constraintEqualToAnchor:frameGuide.topAnchor],
            [curtain.bottomAnchor constraintEqualToAnchor:frameGuide.bottomAnchor],
            [curtain.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor],
            [curtain.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [curtain.topAnchor constraintEqualToAnchor:hostView.topAnchor],
            [curtain.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
            [curtain.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
            [curtain.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
        ]];
    }
    objc_setAssociatedObject(hostView, kWQMotionEdgeBlurKey, curtain, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void wq_motion_update_edge_blur(UIScrollView *scrollView, UIView *hostView)
{
    if (!scrollView || !hostView) return;
    WQDuoEdgeBlurCurtainView *curtain = objc_getAssociatedObject(hostView, kWQMotionEdgeBlurKey);
    if (!curtain) return;
    if (wq_motion_reduced() || UIAccessibilityIsReduceTransparencyEnabled()) {
        [curtain setTopStrength:0.0 bottomStrength:0.0 animated:NO];
        return;
    }
    WQMotionScrollState *state = wq_motion_scroll_state(scrollView);
    CGFloat mag = fabs(state.smoothedVelocity);
    CGFloat velBoost = MIN(0.56, MAX(0.0, (mag - 45.0) / 1300.0));
    CGFloat y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    CGFloat maxY = MAX(0.0, scrollView.contentSize.height - (scrollView.bounds.size.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom));
    CGFloat topBase = y > 4.0 ? MIN(0.42, 0.16 + y / 44.0 * 0.26) : 0.0;
    CGFloat botBase = (maxY > 24.0 && y < maxY - 4.0) ? 0.36 : 0.0;
    CGFloat topStrength = topBase + (state.smoothedVelocity > 0 ? velBoost : velBoost * 0.30);
    CGFloat botStrength = botBase + (state.smoothedVelocity < 0 ? velBoost : velBoost * 0.42);
    [curtain setTopStrength:topStrength bottomStrength:botStrength animated:NO];
}

void wq_motion_settle_edge_blur(UIScrollView *scrollView, UIView *hostView)
{
    if (!scrollView || !hostView) return;
    WQDuoEdgeBlurCurtainView *curtain = objc_getAssociatedObject(hostView, kWQMotionEdgeBlurKey);
    if (!curtain) return;
    if (wq_motion_reduced() || UIAccessibilityIsReduceTransparencyEnabled()) {
        [curtain setTopStrength:0.0 bottomStrength:0.0 animated:NO];
        return;
    }
    CGFloat y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    CGFloat maxY = MAX(0.0, scrollView.contentSize.height - (scrollView.bounds.size.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom));
    CGFloat topRest = y > 8.0 ? 0.30 : 0.0;
    CGFloat botRest = (maxY > 24.0 && y < maxY - 8.0) ? 0.26 : 0.0;
    [curtain setTopStrength:topRest bottomStrength:botRest animated:YES];
}

#pragma mark - Progressive Haptic Feedback on Press-and-Hold

@interface WQDuoInteractiveHoldTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *targetView;
@property (nonatomic) NSTimeInterval holdDuration;
@property (nonatomic) BOOL drawProgressRing;
@property (nonatomic, copy, nullable) void (^onComplete)(void);
@end

@implementation WQDuoInteractiveHoldTarget {
    CADisplayLink *_link;
    CFTimeInterval _startTime;
    NSInteger _stageFired;
    BOOL _completed;
    UIImpactFeedbackGenerator *_softGen;
    UIImpactFeedbackGenerator *_mediumGen;
    UIImpactFeedbackGenerator *_rigidGen;
    CAShapeLayer *_progressRing;
    CGColorRef _savedBorderColor;
    CGFloat _savedBorderWidth;
}

- (void)dealloc
{
    [_link invalidate];
    if (_savedBorderColor) {
        CGColorRelease(_savedBorderColor);
        _savedBorderColor = NULL;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *__unused)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *__unused)other
{
    return YES;
}

- (void)ensureRingOnView:(UIView *)view
{
    if (!_drawProgressRing || !view) return;
    if (!_progressRing) {
        _progressRing = [CAShapeLayer layer];
        _progressRing.fillColor = UIColor.clearColor.CGColor;
        _progressRing.strokeColor = wq_theme_accent().CGColor;
        _progressRing.lineWidth = 2.5;
        _progressRing.lineCap = kCALineCapRound;
        _progressRing.strokeStart = 0.0;
        _progressRing.strokeEnd = 0.0;
        _progressRing.shadowColor = wq_theme_accent().CGColor;
        _progressRing.shadowRadius = 6.0;
        _progressRing.shadowOpacity = 0.85f;
        _progressRing.shadowOffset = CGSizeZero;
        [view.layer addSublayer:_progressRing];
    }
    CGRect inset = CGRectInset(view.bounds, -2.0, -2.0);
    CGFloat radius = view.layer.cornerRadius > 0 ? view.layer.cornerRadius + 2.0 : MIN(inset.size.width, inset.size.height) * 0.5;
    _progressRing.frame = view.bounds;
    _progressRing.path = [UIBezierPath bezierPathWithRoundedRect:inset cornerRadius:radius].CGPath;
}

- (void)handlePress:(UILongPressGestureRecognizer *)gr
{
    UIView *view = _targetView;
    if (!view) return;
    if (gr.state == UIGestureRecognizerStateBegan) {
        _startTime = CACurrentMediaTime();
        _stageFired = 0;
        _completed = NO;
        _softGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _mediumGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _rigidGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
        [_softGen prepare];
        [_mediumGen prepare];
        [_rigidGen prepare];

        // 0ms touch-down: immediate Light impact + 0.965x compression + sapphire rim highlight boost.
        [_softGen impactOccurredWithIntensity:0.55];

        if (_savedBorderColor) {
            CGColorRelease(_savedBorderColor);
            _savedBorderColor = NULL;
        }
        if (view.layer.borderColor) _savedBorderColor = CGColorRetain(view.layer.borderColor);
        _savedBorderWidth = view.layer.borderWidth;

        BOOL reduced = wq_motion_reduced();
        UIViewPropertyAnimator *down = [[UIViewPropertyAnimator alloc] initWithDuration:0.16 dampingRatio:reduced ? 1.0 : 0.84 animations:^{
            CGFloat s = reduced ? 0.99 : 0.965;
            view.transform = CGAffineTransformMakeScale(s, s);
            view.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.75].CGColor;
            view.layer.borderWidth = MAX(1.0, self->_savedBorderWidth);
        }];
        [down startAnimation];

        [self ensureRingOnView:view];
        _progressRing.strokeEnd = 0.0;
        _progressRing.opacity = 1.0f;

        [_link invalidate];
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickHold)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (gr.state == UIGestureRecognizerStateEnded ||
               gr.state == UIGestureRecognizerStateCancelled ||
               gr.state == UIGestureRecognizerStateFailed) {
        [self finishHoldCancelled:(gr.state != UIGestureRecognizerStateEnded)];
    }
}

- (void)tickHold
{
    UIView *view = _targetView;
    if (!view) {
        [_link invalidate];
        _link = nil;
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - _startTime;
    NSTimeInterval duration = MAX(0.45, _holdDuration);
    CGFloat progress = (CGFloat)MIN(1.0, MAX(0.0, (elapsed - 0.12) / (duration - 0.12)));

    // Continuous hold ramp (150ms..650ms): 0.30 -> 0.65 -> 1.0 progressive micro-pulses.
    if (_stageFired < 1 && elapsed >= 0.15) {
        _stageFired = 1;
        [_softGen impactOccurredWithIntensity:0.30];
    } else if (_stageFired < 2 && elapsed >= duration * 0.55) {
        _stageFired = 2;
        [_mediumGen impactOccurredWithIntensity:0.65];
    } else if (_stageFired < 3 && elapsed >= duration * 0.82) {
        _stageFired = 3;
        [_mediumGen impactOccurredWithIntensity:1.0];
    }

    // Luminous sapphire edge-charge glow while held.
    view.layer.shadowColor = wq_theme_accent().CGColor;
    view.layer.shadowRadius = 4.0 + 10.0 * progress;
    view.layer.shadowOpacity = (float)(0.20 + 0.50 * progress);
    view.layer.shadowOffset = CGSizeZero;

    if (_progressRing) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _progressRing.strokeEnd = progress;
        [CATransaction commit];
    }

    if (!_completed && elapsed >= duration) {
        _completed = YES;
        [_link invalidate];
        _link = nil;
        [_rigidGen impactOccurredWithIntensity:1.0];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        if (_onComplete) {
            void (^cb)(void) = _onComplete;
            cb();
        }
    }
}

- (void)finishHoldCancelled:(BOOL)cancelled
{
    [_link invalidate];
    _link = nil;
    UIView *view = _targetView;
    if (!view) return;

    if (!cancelled && !_completed) {
        [_softGen impactOccurredWithIntensity:0.45];
    }
    BOOL reduced = wq_motion_reduced();
    UIViewPropertyAnimator *up = [[UIViewPropertyAnimator alloc] initWithDuration:0.28 dampingRatio:reduced ? 1.0 : 0.82 animations:^{
        view.transform = CGAffineTransformIdentity;
        view.layer.shadowOpacity = 0.0f;
        if (self->_savedBorderColor) {
            view.layer.borderColor = self->_savedBorderColor;
        }
        view.layer.borderWidth = self->_savedBorderWidth;
    }];
    [up startAnimation];

    if (_progressRing) {
        _progressRing.strokeEnd = 0.0;
        _progressRing.opacity = 0.0f;
    }
}

@end

static void wq_motion_install_hold(UIView *view, NSTimeInterval duration, BOOL drawRing, void (^_Nullable onComplete)(void))
{
    if (!view) return;
    if (objc_getAssociatedObject(view, kWQMotionInteractiveHoldKey)) return;
    WQDuoInteractiveHoldTarget *target = [WQDuoInteractiveHoldTarget new];
    target.targetView = view;
    target.holdDuration = duration > 0 ? duration : 0.65;
    target.drawProgressRing = drawRing;
    target.onComplete = onComplete;

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handlePress:)];
    press.minimumPressDuration = 0.0;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delegate = target;
    [view addGestureRecognizer:press];
    objc_setAssociatedObject(view, kWQMotionInteractiveHoldKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void wq_motion_add_interactive_hold(UIView *view, void (^onComplete)(void))
{
    wq_motion_install_hold(view, 0.65, NO, onComplete);
}

void wq_motion_add_hold_progress_ring(UIView *view, NSTimeInterval holdDuration, void (^onComplete)(void))
{
    wq_motion_install_hold(view, holdDuration > 0 ? holdDuration : 0.65, YES, onComplete);
}

#pragma mark - iPhone Duo Optical Blur Tab Transition

@interface WQDuoTabTransitionAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@end

@implementation WQDuoTabTransitionAnimator

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning> __unused)transitionContext
{
    return 0.32;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    UIView *container = transitionContext.containerView;
    UIView *fromView = [transitionContext viewForKey:UITransitionContextFromViewKey];
    UIView *toView = [transitionContext viewForKey:UITransitionContextToViewKey];
    UIViewController *toVC = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    if (!toView || !fromView) {
        [transitionContext completeTransition:!transitionContext.transitionWasCancelled];
        return;
    }

    CGRect finalFrame = [transitionContext finalFrameForViewController:toVC];
    if (CGRectIsEmpty(finalFrame)) finalFrame = container.bounds;
    toView.frame = finalFrame;
    [container addSubview:toView];

    BOOL reduced = wq_motion_reduced() || UIAccessibilityIsReduceTransparencyEnabled();
    if (reduced) {
        toView.alpha = 0.0;
        [UIView animateWithDuration:0.20 animations:^{
            toView.alpha = 1.0;
            fromView.alpha = 0.0;
        } completion:^(BOOL finished) {
            fromView.alpha = 1.0;
            [transitionContext completeTransition:finished && !transitionContext.transitionWasCancelled];
        }];
        return;
    }

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *fromBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    fromBlur.frame = fromView.bounds;
    fromBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fromBlur.userInteractionEnabled = NO;
    [fromView addSubview:fromBlur];

    UIVisualEffectView *toBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    toBlur.frame = toView.bounds;
    toBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    toBlur.userInteractionEnabled = NO;
    toBlur.alpha = 0.92;
    [toView addSubview:toBlur];

    toView.alpha = 0.0;
    toView.transform = CGAffineTransformMakeScale(1.02, 1.02);

    UIViewPropertyAnimator *anim = [[UIViewPropertyAnimator alloc] initWithDuration:0.32 dampingRatio:0.86 animations:^{
        fromBlur.effect = blur;
        fromView.alpha = 0.0;
        fromView.transform = CGAffineTransformMakeScale(0.965, 0.965);
        toBlur.effect = nil;
        toBlur.alpha = 0.0;
        toView.alpha = 1.0;
        toView.transform = CGAffineTransformIdentity;
    }];
    [anim addCompletion:^(UIViewAnimatingPosition __unused pos) {
        [fromBlur removeFromSuperview];
        [toBlur removeFromSuperview];
        fromView.alpha = 1.0;
        fromView.transform = CGAffineTransformIdentity;
        toView.transform = CGAffineTransformIdentity;
        [transitionContext completeTransition:!transitionContext.transitionWasCancelled];
    }];
    [anim startAnimation];
}

@end

id<UIViewControllerAnimatedTransitioning> wq_motion_duo_tab_animator(void)
{
    return [WQDuoTabTransitionAnimator new];
}
