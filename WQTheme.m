//
//  WQTheme.m
//  WQ Files crimson Liquid Glass theme (iOS 26)
//

#import "WQTheme.h"
#import "WQUI.h"
#import <objc/runtime.h>

static const NSInteger kWQThemeBackdropTag = 0x57515042;   // same tag wq_prism_install_background uses

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
UIColor *wq_theme_accent(void)         { return wq_rgb(0xE0645A, 1.0); }
UIColor *wq_theme_solid_surface(void)  { return wq_rgb(0x8A302C, 1.0); }

static UIColor *wq_theme_pressed(void) { return wq_rgb(0xFFDCDA, 0.20); }

#pragma mark - Liquid Glass

UIVisualEffect *wq_theme_glass_effect(BOOL interactive)
{
    if (UIAccessibilityIsReduceTransparencyEnabled()) return nil;
    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    glass.tintColor = wq_theme_glass_tint();
    glass.interactive = interactive;
    return glass;
}

UIButtonConfiguration *wq_theme_primary_button_configuration(void)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration prominentGlassButtonConfiguration];
    cfg.baseBackgroundColor = UIColor.whiteColor;
    cfg.baseForegroundColor = wq_theme_cta_text();
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    return cfg;
}

UIButtonConfiguration *wq_theme_secondary_button_configuration(void)
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    return cfg;
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
        return;
    }
    if ([view isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)view;
        if (!wq_theme_is_backdrop(collection.backgroundView)) collection.backgroundView = wq_prism_background_view();
        collection.backgroundColor = UIColor.clearColor;
        return;
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        // A subview would scroll with the content; a solid canvas color doesn't.
        view.backgroundColor = wq_theme_canvas_mid();
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

// Every WQ Files screen gets the crimson canvas, whichever design it belongs to.
static void wq_theme_view_did_load(UIViewController *vc, SEL cmd)
{
    if (wq_orig_view_did_load) ((void (*)(id, SEL))wq_orig_view_did_load)(vc, cmd);
    if ([vc isKindOfClass:UINavigationController.class] || [vc isKindOfClass:UITabBarController.class]) return;
    if (![NSStringFromClass(vc.class) hasPrefix:@"WQ"]) return;
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
    background.strokeWidth = table.style == UITableViewStylePlain ? 0.0 : 0.5;
    background.visualEffect = nil;
    cell.backgroundConfiguration = background;

    if ([cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
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
    });
}

void wq_theme_prepare_window(UIWindow *window)
{
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.tintColor = wq_theme_primary_text();
    window.backgroundColor = wq_theme_canvas_edge();
}
