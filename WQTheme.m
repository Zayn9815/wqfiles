//
//  WQTheme.m
//  WQ Glass crimson Liquid Glass theme (iOS 26)
//

#import "WQTheme.h"
#import "WQUI.h"
#import <objc/runtime.h>

static const NSInteger kWQThemeBackdropTag = 0x57515042;   // same tag wq_prism_install_background uses
static const void *kWQThemeSpringKey = &kWQThemeSpringKey;

static UIColor *wq_rgb(uint32_t rgb, CGFloat alpha)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

#pragma mark - Palette

UIColor *wq_theme_canvas_top(void)     { return wq_rgb(0x5C1D1B, 1.0); }
UIColor *wq_theme_canvas_mid(void)     { return wq_rgb(0x782623, 1.0); }
UIColor *wq_theme_canvas_edge(void)    { return wq_rgb(0x4A1412, 1.0); }
UIColor *wq_theme_glass_tint(void)     { return wq_rgb(0x9B3A36, 0.45); }
UIColor *wq_theme_rim(void)            { return wq_rgb(0xFFDCDA, 0.28); }
UIColor *wq_theme_primary_text(void)   { return UIColor.whiteColor; }
UIColor *wq_theme_secondary_text(void) { return wq_rgb(0xE6B8B5, 1.0); }
UIColor *wq_theme_hairline(void)       { return [UIColor colorWithWhite:1.0 alpha:0.14]; }
UIColor *wq_theme_cta_text(void)       { return wq_rgb(0x6B211E, 1.0); }
UIColor *wq_theme_active_pill(void)    { return wq_rgb(0x9B2627, 1.0); }
UIColor *wq_theme_accent(void)         { return wq_rgb(0xE0645A, 1.0); }
UIColor *wq_theme_solid_surface(void)  { return wq_rgb(0x8A302C, 1.0); }

static UIColor *wq_theme_pressed(void) { return wq_rgb(0xFFDCDA, 0.20); }

#pragma mark - Spring interaction

@interface WQThemeSpringTarget : NSObject
@end

@implementation WQThemeSpringTarget
- (void)down:(UIControl *)sender
{
    [UIView animateWithDuration:0.14 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        sender.transform = CGAffineTransformMakeScale(0.965, 0.965);
        sender.alpha = 0.92;
    } completion:nil];
}
- (void)up:(UIControl *)sender
{
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        sender.transform = CGAffineTransformIdentity;
        sender.alpha = 1.0;
    } completion:nil];
}
@end

void wq_theme_add_spring_tap(UIControl *control)
{
    if (!control || objc_getAssociatedObject(control, kWQThemeSpringKey)) return;
    WQThemeSpringTarget *target = [WQThemeSpringTarget new];
    objc_setAssociatedObject(control, kWQThemeSpringKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [control addTarget:target action:@selector(up:)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

#pragma mark - Liquid Glass

UIVisualEffect *wq_theme_glass_effect(BOOL interactive)
{
    if (UIAccessibilityIsReduceTransparencyEnabled()) return nil;
    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    glass.tintColor = wq_theme_glass_tint();
    glass.interactive = interactive;
    return glass;
}

UIVisualEffectView *wq_theme_make_glass_card(CGFloat cornerRadius, BOOL interactive)
{
    UIVisualEffect *effect = wq_theme_glass_effect(interactive);
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:effect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = cornerRadius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.75;
    card.layer.borderColor = wq_theme_rim().CGColor;
    card.clipsToBounds = YES;
    if (!effect) card.backgroundColor = wq_theme_solid_surface();
    return card;
}

UIButtonConfiguration *wq_theme_primary_button_configuration(void)
{
    // filledButtonConfiguration renders an opaque pure-white pill with crisp
    // #6B211E text & SF Symbol across iOS 26/27 Liquid Glass UI (unlike
    // prominentGlassButtonConfiguration, whose vibrant monochrome layer turns
    // white text/icons invisible against a white platter).
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    UIColor *cta = wq_theme_cta_text();
    cfg.baseBackgroundColor = UIColor.whiteColor;
    cfg.baseForegroundColor = cta;
    cfg.background.backgroundColor = UIColor.whiteColor;
    cfg.background.strokeColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.85 alpha:0.55];
    cfg.background.strokeWidth = 0.75;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.imagePadding = 7;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy] ?: [NSMutableDictionary new];
        out[NSForegroundColorAttributeName] = cta;
        if (!out[NSFontAttributeName]) {
            out[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        }
        return out;
    };
    cfg.imageColorTransformer = ^UIColor *(UIColor *__unused color) {
        return cta;
    };
    return cfg;
}

UIButtonConfiguration *wq_theme_secondary_button_configuration(void)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.baseBackgroundColor = wq_theme_glass_tint();
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.imagePadding = 6;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    cfg.background.strokeColor = wq_theme_rim();
    cfg.background.strokeWidth = 0.75;
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy];
        out[NSForegroundColorAttributeName] = UIColor.whiteColor;
        return out;
    };
    cfg.imageColorTransformer = ^UIColor *(UIColor *__unused color) {
        return UIColor.whiteColor;
    };
    return cfg;
}

void wq_theme_style_primary_button(UIButton *button, NSString *title, NSString *symbolName)
{
    if (!button) return;
    UIColor *cta = wq_theme_cta_text();
    UIButtonConfiguration *cfg = wq_theme_primary_button_configuration();
    if (title) {
        cfg.title = title;
        cfg.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSForegroundColorAttributeName: cta,
            NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
        }];
    }
    if (symbolName.length) {
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
        cfg.image = [[UIImage systemImageNamed:symbolName withConfiguration:sym] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = cta;
    [button setTitleColor:cta forState:UIControlStateNormal];
    [button setTitleColor:cta forState:UIControlStateHighlighted];
    [button setTitleColor:cta forState:UIControlStateSelected];
    [button setTitleColor:[cta colorWithAlphaComponent:0.55] forState:UIControlStateDisabled];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.78;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.configurationUpdateHandler = ^(UIButton *b) {
        b.alpha = b.enabled ? 1.0 : 0.56;
    };
    wq_theme_add_spring_tap(button);
}

void wq_theme_style_secondary_button(UIButton *button, NSString *title, NSString *symbolName)
{
    if (!button) return;
    UIButtonConfiguration *cfg = wq_theme_secondary_button_configuration();
    if (title) cfg.title = title;
    if (symbolName.length) {
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        cfg.image = [[UIImage systemImageNamed:symbolName withConfiguration:sym] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:wq_theme_secondary_text() forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.6] forState:UIControlStateDisabled];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.78;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.configurationUpdateHandler = ^(UIButton *b) {
        b.alpha = b.enabled ? 1.0 : 0.48;
    };
    wq_theme_add_spring_tap(button);
}

void wq_theme_update_pill_button(UIButton *button, BOOL active)
{
    if (!button) return;
    UIButtonConfiguration *cfg = [button.configuration copy] ?: [UIButtonConfiguration glassButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
    cfg.baseBackgroundColor = active ? wq_theme_active_pill() : wq_rgb(0x9B3A36, 0.36);
    cfg.baseForegroundColor = active ? UIColor.whiteColor : wq_theme_secondary_text();
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(7, 14, 7, 14);
    cfg.background.strokeWidth = active ? 1.0 : 0.75;
    cfg.background.strokeColor = active ? wq_rgb(0xFFDCDA, 0.55) : wq_theme_rim();
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary *out = [incoming mutableCopy];
        out[NSForegroundColorAttributeName] = active ? UIColor.whiteColor : wq_theme_secondary_text();
        out[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:active ? UIFontWeightBold : UIFontWeightSemibold];
        return out;
    };
    button.configuration = cfg;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
    button.tintColor = active ? UIColor.whiteColor : wq_theme_secondary_text();
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.80;
}

UIButton *wq_theme_pill_button(NSString *title, BOOL active)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.title = title;
    button.configuration = cfg;
    wq_theme_update_pill_button(button, active);
    wq_theme_add_spring_tap(button);
    return button;
}

void wq_theme_apply_scroll_insets(UIScrollView *scrollView, CGFloat bottomPadding)
{
    if (!scrollView) return;
    UIEdgeInsets insets = scrollView.contentInset;
    if (insets.bottom < bottomPadding) {
        insets.bottom = bottomPadding;
        scrollView.contentInset = insets;
    }
    UIEdgeInsets indicators = scrollView.verticalScrollIndicatorInsets;
    if (indicators.bottom < bottomPadding) {
        indicators.bottom = bottomPadding;
        scrollView.verticalScrollIndicatorInsets = indicators;
    }
}

UIView *wq_theme_glass_container(UIView *content, CGFloat spacing)
{
    UIGlassContainerEffect *effect = [UIGlassContainerEffect new];
    effect.spacing = spacing;
    UIVisualEffectView *container = [[UIVisualEffectView alloc] initWithEffect:effect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [container.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:container.contentView.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:container.contentView.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor],
    ]];
    return container;
}

#pragma mark - Canvas

static BOOL wq_theme_is_backdrop(UIView *_Nullable view)
{
    static Class backdropClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ backdropClass = NSClassFromString(@"WQPrismBackgroundView"); });
    return view && backdropClass && [view isKindOfClass:backdropClass];
}

void wq_theme_install_backdrop(UIViewController *vc)
{
    if (!vc.isViewLoaded) return;
    UIView *view = vc.view;
    if ([view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)view;
        if (!wq_theme_is_backdrop(table.backgroundView)) table.backgroundView = wq_prism_background_view();
        table.backgroundColor = UIColor.clearColor;
        table.separatorColor = wq_theme_hairline();
        wq_theme_apply_scroll_insets(table, 28.0);
        return;
    }
    if ([view isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)view;
        if (!wq_theme_is_backdrop(collection.backgroundView)) collection.backgroundView = wq_prism_background_view();
        collection.backgroundColor = UIColor.clearColor;
        wq_theme_apply_scroll_insets(collection, 28.0);
        return;
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        view.backgroundColor = wq_theme_canvas_mid();
        wq_theme_apply_scroll_insets((UIScrollView *)view, 28.0);
        return;
    }
    if ([view viewWithTag:kWQThemeBackdropTag]) return;
    UIView *backdrop = wq_prism_background_view();
    backdrop.tag = kWQThemeBackdropTag;
    backdrop.frame = view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view insertSubview:backdrop atIndex:0];
}

#pragma mark - Hooks

static IMP wq_orig_view_did_load;
static IMP wq_orig_cell_update;

static void wq_theme_hook(Class cls, SEL sel, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *original = method_getImplementation(method);
    // Inherited: add an override on cls so the superclass stays untouched.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
}

// Every WQ Glass screen gets the crimson canvas, whichever design it belongs to.
static void wq_theme_view_did_load(UIViewController *vc, SEL cmd)
{
    if (wq_orig_view_did_load) ((void (*)(id, SEL))wq_orig_view_did_load)(vc, cmd);
    if ([vc isKindOfClass:UINavigationController.class] || [vc isKindOfClass:UITabBarController.class]) return;
    if (![NSStringFromClass(vc.class) hasPrefix:@"WQ"]) return;
    vc.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    wq_theme_install_backdrop(vc);
}

// Rows of themed tables: grouped sections become crimson glass cards, plain
// lists stay clear over the canvas. System screens are left alone.
static void wq_theme_cell_update(UITableViewCell *cell, SEL cmd, UICellConfigurationState *state)
{
    if (wq_orig_cell_update) ((void (*)(id, SEL, id))wq_orig_cell_update)(cell, cmd, state);
    UITableView *table = nil;
    UIView *view = cell.superview;
    for (NSInteger depth = 0; view && depth < 4; depth++, view = view.superview) {
        if ([view isKindOfClass:UITableView.class]) { table = (UITableView *)view; break; }
    }
    if (!table || !wq_theme_is_backdrop(table.backgroundView)) return;
    UIBackgroundConfiguration *background = cell.backgroundConfiguration
        ? [cell.backgroundConfiguration copy]
        : [UIBackgroundConfiguration clearConfiguration];
    BOOL pressed = state.isHighlighted || (state.isSelected && !state.isEditing);
    if (pressed) background.backgroundColor = wq_theme_pressed();
    else if (table.style == UITableViewStylePlain) background.backgroundColor = UIColor.clearColor;
    else background.backgroundColor = UIAccessibilityIsReduceTransparencyEnabled()
        ? wq_theme_solid_surface()
        : wq_theme_glass_tint();
    background.strokeColor = table.style == UITableViewStylePlain ? UIColor.clearColor : wq_theme_rim();
    background.strokeWidth = table.style == UITableViewStylePlain ? 0.0 : 0.6;
    background.visualEffect = nil;
    cell.backgroundConfiguration = background;

    if ([cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
        if (!content.textProperties.color) content.textProperties.color = wq_theme_primary_text();
        if (content.secondaryText.length || content.secondaryAttributedText.length)
            content.secondaryTextProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = content;
    }
}

void wq_theme_install(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wq_theme_hook(UIViewController.class, @selector(viewDidLoad),
                      (IMP)wq_theme_view_did_load, &wq_orig_view_did_load);
        wq_theme_hook(UITableViewCell.class, @selector(updateConfigurationUsingState:),
                      (IMP)wq_theme_cell_update, &wq_orig_cell_update);

        [UISwitch appearance].onTintColor = wq_theme_accent();
        [UIProgressView appearance].progressTintColor = wq_theme_accent();
        [UIProgressView appearance].trackTintColor = wq_theme_hairline();
        [UIRefreshControl appearance].tintColor = wq_theme_secondary_text();
        [UIActivityIndicatorView appearance].color = wq_theme_secondary_text();
        [UITableView appearance].separatorColor = wq_theme_hairline();
        [UISearchBar appearance].tintColor = wq_theme_primary_text();
        [UITextField appearanceWhenContainedInInstancesOfClasses:@[UISearchBar.class]].textColor = wq_theme_primary_text();
        [UILabel appearanceWhenContainedInInstancesOfClasses:@[UITableViewHeaderFooterView.class]].textColor = wq_theme_secondary_text();

        UINavigationBarAppearance *navApp = [UINavigationBarAppearance new];
        [navApp configureWithTransparentBackground];
        navApp.titleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};
        navApp.largeTitleTextAttributes = @{NSForegroundColorAttributeName: wq_theme_primary_text()};
        [UINavigationBar appearance].standardAppearance = navApp;
        [UINavigationBar appearance].compactAppearance = navApp;
        [UINavigationBar appearance].scrollEdgeAppearance = navApp;
        [UINavigationBar appearance].tintColor = wq_theme_primary_text();
    });
}

void wq_theme_prepare_window(UIWindow *window)
{
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.tintColor = wq_theme_primary_text();
    window.backgroundColor = wq_theme_canvas_edge();
}
