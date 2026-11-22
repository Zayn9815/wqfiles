//
//  WQSecurity.m
//  WQ Glass Face ID / Touch ID App Lock & Privacy Shield
//  GPL-3.0-or-later.
//

#import "WQSecurity.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import <LocalAuthentication/LocalAuthentication.h>

NSString *const kWQAppLockEnabledPref = @"WQAppLockEnabled";

BOOL wq_app_lock_enabled(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQAppLockEnabledPref];
}

void wq_app_lock_set_enabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kWQAppLockEnabledPref];
}

NSString *wq_app_lock_biometry_name(void)
{
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err]) {
        if (ctx.biometryType == LABiometryTypeFaceID) return @"Face ID";
        if (ctx.biometryType == LABiometryTypeTouchID) return @"Touch ID";
        if (ctx.biometryType == LABiometryTypeOpticID) return @"Optic ID";
    }
    return WQLocalized(@"Passcode");
}

void wq_app_lock_authenticate(NSString *reason, void (^completion)(BOOL ok, NSString *_Nullable errorText))
{
    LAContext *ctx = [LAContext new];
    NSError *policyError = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&policyError]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, policyError.localizedDescription ?: WQLocalized(@"Device authentication is unavailable."));
        });
        return;
    }
    NSString *prompt = reason.length ? reason : WQLocalized(@"Unlock WQ Glass");
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:prompt reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, success ? nil : error.localizedDescription);
        });
    }];
}

@interface WQAppLockShieldController : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, strong, nullable) UIVisualEffectView *shieldView;
@property (nonatomic, strong, nullable) UIView *lockCard;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UILabel *subtitleLabel;
@property (nonatomic, strong, nullable) UIButton *unlockButton;
@property (nonatomic) BOOL locked;
@property (nonatomic) BOOL authInFlight;
@end

@implementation WQAppLockShieldController

+ (instancetype)shared
{
    static WQAppLockShieldController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [WQAppLockShieldController new];
    });
    return instance;
}

- (instancetype)init
{
    if ((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willResignActive)
                                                   name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didEnterBackground)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive)
                                                   name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyTheme)
                                                   name:WQThemeDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)attachWindow:(UIWindow *)window
{
    self.window = window;
    if (wq_app_lock_enabled()) {
        _locked = YES;
        [self showShieldInteractive:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self triggerUnlockIfNeeded];
        });
    }
}

- (void)ensureShieldInWindow:(UIWindow *)window
{
    if (!window) return;
    if (!_shieldView) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        _shieldView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _shieldView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _shieldView.layer.zPosition = 9999;

        UIVisualEffectView *card = wq_theme_make_glass_card(28.0, NO);
        _lockCard = card;

        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.shield.fill" withConfiguration:sym]];
        icon.tintColor = wq_theme_accent();
        icon.contentMode = UIViewContentModeScaleAspectFit;

        _titleLabel = [UILabel new];
        _titleLabel.text = WQLocalized(@"WQ Glass Locked");
        _titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
        _titleLabel.textColor = wq_theme_primary_text();
        _titleLabel.textAlignment = NSTextAlignmentCenter;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.text = WQLocalizedFormat(@"Authenticate with %@ to continue.", wq_app_lock_biometry_name());
        _subtitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = wq_theme_secondary_text();
        _subtitleLabel.textAlignment = NSTextAlignmentCenter;
        _subtitleLabel.numberOfLines = 0;

        _unlockButton = [UIButton buttonWithType:UIButtonTypeSystem];
        wq_theme_style_primary_button(_unlockButton,
            WQLocalizedFormat(@"Unlock with %@", wq_app_lock_biometry_name()),
            @"faceid");
        [_unlockButton addTarget:self action:@selector(unlockTapped) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, _titleLabel, _subtitleLabel, _unlockButton]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 12;
        [stack setCustomSpacing:18 afterView:_subtitleLabel];
        [card.contentView addSubview:stack];

        [_shieldView.contentView addSubview:card];
        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:_shieldView.contentView.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:_shieldView.contentView.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToConstant:320],
            [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:_shieldView.contentView.leadingAnchor constant:24],
            [card.trailingAnchor constraintLessThanOrEqualToAnchor:_shieldView.contentView.trailingAnchor constant:-24],
            [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:26],
            [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-24],
            [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:22],
            [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-22],
            [_unlockButton.widthAnchor constraintGreaterThanOrEqualToConstant:210],
        ]];
    }
    _shieldView.frame = window.bounds;
    if (_shieldView.superview != window) {
        [window addSubview:_shieldView];
    }
    [window bringSubviewToFront:_shieldView];
    [self applyTheme];
}

- (void)applyTheme
{
    if (!_shieldView) return;
    _shieldView.backgroundColor = [wq_theme_canvas_top() colorWithAlphaComponent:0.78];
    _titleLabel.textColor = wq_theme_primary_text();
    _subtitleLabel.textColor = wq_theme_secondary_text();
    NSString *bio = wq_app_lock_biometry_name();
    NSString *symbol = [bio isEqualToString:@"Touch ID"] ? @"touchid" : ([bio isEqualToString:@"Face ID"] ? @"faceid" : @"lock.open.fill");
    wq_theme_style_primary_button(_unlockButton, WQLocalizedFormat(@"Unlock with %@", bio), symbol);
}

- (void)showShieldInteractive:(BOOL)interactive
{
    UIWindow *w = self.window;
    if (!w) return;
    [self ensureShieldInWindow:w];
    _lockCard.hidden = !interactive;
    _shieldView.alpha = 1.0;
    _shieldView.hidden = NO;
}

- (void)hideShieldAnimated:(BOOL)animated
{
    if (!_shieldView || _shieldView.hidden) return;
    if (!animated || wq_motion_reduced()) {
        _shieldView.hidden = YES;
        _shieldView.alpha = 0.0;
        return;
    }
    [UIView animateWithDuration:0.20 animations:^{
        self->_shieldView.alpha = 0.0;
    } completion:^(BOOL __unused finished) {
        if (!self->_locked) self->_shieldView.hidden = YES;
    }];
}

- (void)willResignActive
{
    if (!wq_app_lock_enabled()) return;
    // Blur immediately for the iOS App Switcher snapshot.
    [self showShieldInteractive:_locked];
}

- (void)didEnterBackground
{
    if (!wq_app_lock_enabled()) return;
    _locked = YES;
    [self showShieldInteractive:YES];
}

- (void)didBecomeActive
{
    if (!wq_app_lock_enabled()) {
        _locked = NO;
        [self hideShieldAnimated:NO];
        return;
    }
    if (_locked) {
        [self showShieldInteractive:YES];
        [self triggerUnlockIfNeeded];
    } else {
        [self hideShieldAnimated:YES];
    }
}

- (void)unlockTapped
{
    wq_haptic_impact(UIImpactFeedbackStyleMedium);
    [self triggerUnlockIfNeeded];
}

- (void)triggerUnlockIfNeeded
{
    if (!_locked || _authInFlight) return;
    _authInFlight = YES;
    NSString *reason = WQLocalized(@"Unlock WQ Glass to access device containers and files.");
    __weak typeof(self) weakSelf = self;
    wq_app_lock_authenticate(reason, ^(BOOL ok, NSString *_Nullable errorText) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_authInFlight = NO;
        if (ok) {
            me->_locked = NO;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            [me hideShieldAnimated:YES];
        } else {
            if (errorText.length) {
                me->_subtitleLabel.text = errorText;
            }
            [me showShieldInteractive:YES];
        }
    });
}

@end

void wq_app_lock_attach_window(UIWindow *window)
{
    if (!window) return;
    [[WQAppLockShieldController shared] attachWindow:window];
}
