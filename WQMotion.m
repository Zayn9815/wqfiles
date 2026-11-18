#import "WQMotion.h"
#import "WQTheme.h"
#import <objc/runtime.h>

const CGFloat kWQMotionPressScale = 0.96;
const CGFloat kWQMotionEntranceOffset = 14.0;
const NSTimeInterval kWQMotionStagger = 0.035;

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

#pragma mark - Spring helper

static UIViewPropertyAnimator *wq_motion_spring(NSTimeInterval duration, CGFloat damping, CGFloat velocity, void (^animations)(void))
{
    // Reduce Motion: critically damped, so no bounce.
    CGFloat ratio = wq_motion_reduced() ? 1.0 : damping;
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithDampingRatio:ratio
                                                                              initialVelocity:CGVectorMake(velocity, velocity)];
    UIViewPropertyAnimator *a = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:spring];
    [a addAnimations:animations];
    return a;
}

#pragma mark - Press physics

@interface WQMotionPressTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *view;
- (void)handle:(UILongPressGestureRecognizer *)gesture;
@end

@implementation WQMotionPressTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *__unused)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *__unused)b
{
    return YES;
}

- (void)handle:(UILongPressGestureRecognizer *)gesture
{
    UIView *view = self.view;
    if (!view) return;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            UIViewPropertyAnimator *old = objc_getAssociatedObject(view, kWQMotionAnimatorKey);
            [old stopAnimation:YES];
            CGFloat scale = wq_motion_reduced() ? 0.99 : kWQMotionPressScale;
            UIViewPropertyAnimator *down = wq_motion_spring(0.22, 0.9, 0, ^{ view.transform = CGAffineTransformMakeScale(scale, scale); });
            objc_setAssociatedObject(view, kWQMotionAnimatorKey, down, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [down startAnimation];
            wq_motion_pulse_rim(view);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            UIViewPropertyAnimator *old = objc_getAssociatedObject(view, kWQMotionAnimatorKey);
            [old stopAnimation:YES];
            UIViewPropertyAnimator *up = wq_motion_spring(0.5, 0.55, 6, ^{ view.transform = CGAffineTransformIdentity; });
            objc_setAssociatedObject(view, kWQMotionAnimatorKey, up, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [up startAnimation];
            break;
        }
        default: break;
    }
}

@end

void wq_motion_add_press(UIView *view)
{
    if (!view || objc_getAssociatedObject(view, kWQMotionPressKey)) return;
    WQMotionPressTarget *target = [WQMotionPressTarget new];
    target.view = view;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handle:)];
    press.minimumPressDuration = 0;
    press.allowableMovement = 24;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = target;
    [view addGestureRecognizer:press];
    objc_setAssociatedObject(view, kWQMotionPressKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    glow.toValue = (__bridge id)[UIColor colorWithRed:1.0 green:0.72 blue:0.66 alpha:0.95].CGColor;
    glow.duration = 0.18;
    glow.autoreverses = YES;
    glow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:glow forKey:@"wq.rim"];
}

#pragma mark - Entrances

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
        CGAffineTransform rest = v.transform;
        v.alpha = 0;
        v.transform = CGAffineTransformTranslate(rest, 0, kWQMotionEntranceOffset);
        UIViewPropertyAnimator *a = wq_motion_spring(0.55, 0.82, 0, ^{
            v.alpha = targetAlpha;
            v.transform = rest;
        });
        [a startAnimationAfterDelay:initialDelay + i * kWQMotionStagger];
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
    // Cap the cascade so a screen full of rows never feels slow.
    if (cells.count > 14) cells = [cells subarrayWithRange:NSMakeRange(0, 14)];
    wq_motion_cascade(cells);
}

#pragma mark - Glass morphing

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
        NSMutableDictionary *out = [incoming mutableCopy];
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
    UIViewPropertyAnimator *a = wq_motion_spring(0.28, 0.82, 0, ^{
        wq_theme_update_pill_button(button, active);
    });
    [a startAnimation];
}

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
    dock.layer.borderWidth = 0.75;
    dock.layer.borderColor = wq_theme_rim().CGColor;
    dock.clipsToBounds = YES;
    dock.layer.zPosition = 500;
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
    void (^apply)(void) = ^{
        // Setting the effect inside an animation block makes the glass material
        // materialise / dematerialise instead of popping.
        glass.effect = container;
        glass.contentView.alpha = visible ? 1 : 0;
        glass.alpha = visible ? 1 : 0;
        glass.transform = visible ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.82, 0.82);
    };
    if (visible) glass.hidden = NO;
    if (!animated) { apply(); glass.hidden = !visible; return; }
    UIViewPropertyAnimator *a = wq_motion_spring(0.45, 0.8, 0, apply);
    [a addCompletion:^(UIViewAnimatingPosition __unused p) { if (!visible) glass.hidden = YES; }];
    [a startAnimation];
}

#pragma mark - Status transitions

void wq_motion_pop(UIView *view)
{
    if (!view) return;
    if (wq_motion_reduced()) return;
    view.transform = CGAffineTransformMakeScale(0.7, 0.7);
    UIViewPropertyAnimator *a = wq_motion_spring(0.6, 0.45, 8, ^{ view.transform = CGAffineTransformIdentity; });
    [a startAnimation];
}

void wq_motion_cross_fade(UIView *view, void (^changes)(void))
{
    if (!view || wq_motion_reduced()) { if (changes) changes(); return; }
    [UIView transitionWithView:view duration:0.28 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:changes completion:nil];
}

#pragma mark - Progress ring

@implementation WQProgressRingView {
    CAShapeLayer *_track;
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
        _trackColor = [UIColor colorWithWhite:1 alpha:0.16];
        _progressColor = wq_theme_accent();
        _track = [CAShapeLayer layer];
        _arc = [CAShapeLayer layer];
        _check = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[_track, _arc, _check]) {
            l.fillColor = UIColor.clearColor.CGColor;
            l.lineCap = kCALineCapRound;
            l.lineJoin = kCALineJoinRound;
            [self.layer addSublayer:l];
        }
        _arc.strokeEnd = 0;
        _check.strokeEnd = 0;
        [self refreshColors];
    }
    return self;
}

- (void)refreshColors
{
    _track.strokeColor = _trackColor.CGColor;
    _arc.strokeColor = _progressColor.CGColor;
    _check.strokeColor = UIColor.whiteColor.CGColor;
    _track.lineWidth = _arc.lineWidth = _lineWidth;
    _check.lineWidth = MAX(3, _lineWidth * 0.55);
}

- (void)setTrackColor:(UIColor *)c { _trackColor = c; [self refreshColors]; }
- (void)setProgressColor:(UIColor *)c { _progressColor = c; [self refreshColors]; }
- (void)setLineWidth:(CGFloat)w { _lineWidth = w; [self refreshColors]; [self setNeedsLayout]; }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = CGRectInset(self.bounds, _lineWidth / 2, _lineWidth / 2);
    CGFloat d = MIN(b.size.width, b.size.height);
    CGRect square = CGRectMake(CGRectGetMidX(self.bounds) - d / 2, CGRectGetMidY(self.bounds) - d / 2, d, d);
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(square), CGRectGetMidY(square))
                                                          radius:d / 2 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    _track.path = _arc.path = circle.CGPath;
    _track.frame = _arc.frame = self.bounds;
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
        spring.damping = 18;
        spring.stiffness = 140;
        spring.mass = 1;
        spring.duration = MIN(spring.settlingDuration, 0.9);
        [_arc addAnimation:spring forKey:@"wq.progress"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _arc.strokeEnd = progress;
    [CATransaction commit];
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
        draw.duration = 0.35;
        draw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_check addAnimation:draw forKey:@"wq.check"];
        wq_motion_pop(self);
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

#pragma mark - Progress bar

@implementation WQProgressBarView {
    UIView *_fill;
    CGFloat _value;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        self.layer.cornerRadius = 3;
        self.clipsToBounds = YES;
        self.isAccessibilityElement = YES;
        _fill = [UIView new];
        _fill.backgroundColor = wq_theme_accent();
        _fill.layer.cornerRadius = 3;
        [self addSubview:_fill];
    }
    return self;
}

- (CGFloat)progress { return _value; }

- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 6); }

- (void)layoutSubviews
{
    [super layoutSubviews];
    _fill.frame = CGRectMake(0, 0, self.bounds.size.width * _value, self.bounds.size.height);
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated
{
    _value = MAX(0, MIN(1, progress));
    self.accessibilityValue = [NSString stringWithFormat:@"%d%%", (int)lround(_value * 100)];
    void (^apply)(void) = ^{ self->_fill.frame = CGRectMake(0, 0, self.bounds.size.width * self->_value, self.bounds.size.height); };
    if (!animated) { apply(); return; }
    UIViewPropertyAnimator *a = wq_motion_spring(0.5, 0.9, 0, apply);
    [a startAnimation];
}

@end
