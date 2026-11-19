#import "WQMotion.h"
#import "WQTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

const CGFloat kWQMotionPressScale = 0.96;
const CGFloat kWQMotionEntranceOffset = 16.0;
const NSTimeInterval kWQMotionStagger = 0.030;
const CGFloat kWQMotionSpringResponse = 0.32;
const CGFloat kWQMotionSpringDamping = 0.45;

static const void *kWQMotionPressKey = &kWQMotionPressKey;
static const void *kWQMotionAnimatorKey = &kWQMotionAnimatorKey;

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
            (id)[UIColor colorWithRed:0.88 green:1.0 blue:1.0 alpha:0.34].CGColor,
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
            (id)[UIColor colorWithRed:0.88 green:1.0 blue:1.0 alpha:0.20].CGColor,
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
        [dock.bottomAnchor constraintEqualToAnchor:host.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [dock.leadingAnchor constraintGreaterThanOrEqualToAnchor:horizGuide.leadingAnchor constant:14],
        [dock.trailingAnchor constraintLessThanOrEqualToAnchor:horizGuide.trailingAnchor constant:-14],
    ]];
    if (scroll) wq_theme_apply_scroll_insets(scroll, 96.0);
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
        ? wq_motion_spring_physics(0.34, 0.72, 0, apply)
        : wq_motion_bezier(0.24, apply);
    [a addCompletion:^(UIViewAnimatingPosition __unused p) { if (!visible) glass.hidden = YES; }];
    [a startAnimation];
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
    if (!self.window || wq_motion_reduced()) {
        [_aurora removeAnimationForKey:kAuroraSpinKey];
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
}

- (void)refreshColors
{
    UIColor *base = _progressColor ?: wq_theme_accent();
    _track.strokeColor = _trackColor.CGColor;
    _aurora.colors = @[
        (id)base.CGColor,
        (id)wq_theme_aurora_teal().CGColor,
        (id)[UIColor colorWithRed:0.88 green:1.0 blue:1.0 alpha:1.0].CGColor,
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
            (id)[UIColor colorWithRed:0.88 green:1.0 blue:1.0 alpha:0.65].CGColor,
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
