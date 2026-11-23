//
//  WQWorkspace.m
//  WQ Glass Multi-Tab Folder Workspace & Cross-Tab Transfer
//  GPL-3.0-or-later.
//

#import "WQWorkspace.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"

NSNotificationName const WQWorkspaceTabsDidChangeNotification = @"WQWorkspaceTabsDidChangeNotification";
NSNotificationName const WQDropShelfDidChangeNotification = @"WQDropShelfDidChangeNotification";

static NSString *const kWQWorkspaceTabsPref = @"WQWorkspaceTabs";
static NSString *const kWQDropShelfPref = @"WQDropShelfItems";
static const NSUInteger kWQWorkspaceMaxTabs = 6;

@implementation WQWorkspaceTab
@end

static NSMutableArray<NSDictionary<NSString *, id> *> *wq_workspace_raw(void)
{
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kWQWorkspaceTabsPref];
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray new];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id obj in saved) {
            if ([obj isKindOfClass:NSDictionary.class] && [obj[@"path"] isKindOfClass:NSString.class]) {
                [out addObject:obj];
            }
        }
    }
    return out;
}

static void wq_workspace_save(NSArray<NSDictionary<NSString *, id> *> *raw)
{
    [NSUserDefaults.standardUserDefaults setObject:raw forKey:kWQWorkspaceTabsPref];
    [NSNotificationCenter.defaultCenter postNotificationName:WQWorkspaceTabsDidChangeNotification object:nil];
}

NSArray<WQWorkspaceTab *> *wq_workspace_tabs(void)
{
    NSMutableArray<WQWorkspaceTab *> *out = [NSMutableArray new];
    for (NSDictionary *d in wq_workspace_raw()) {
        WQWorkspaceTab *t = [WQWorkspaceTab new];
        t.path = d[@"path"];
        t.title = [d[@"title"] isKindOfClass:NSString.class] && [d[@"title"] length]
            ? d[@"title"] : (t.path.lastPathComponent.length ? t.path.lastPathComponent : @"/");
        t.readOnly = [d[@"readOnly"] boolValue];
        [out addObject:t];
    }
    return out;
}

void wq_workspace_pin_tab(NSString *path, NSString *title, BOOL readOnly)
{
    if (!path.length) return;
    NSString *std = [path stringByStandardizingPath];
    NSMutableArray<NSDictionary<NSString *, id> *> *raw = wq_workspace_raw();
    NSIndexSet *dups = [raw indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger __unused idx, BOOL *__unused stop) {
        return [[obj[@"path"] stringByStandardizingPath] isEqualToString:std];
    }];
    if (dups.count) [raw removeObjectsAtIndexes:dups];
    [raw insertObject:@{
        @"path": std,
        @"title": title.length ? title : (std.lastPathComponent.length ? std.lastPathComponent : @"/"),
        @"readOnly": @(readOnly),
    } atIndex:0];
    while (raw.count > kWQWorkspaceMaxTabs) [raw removeLastObject];
    wq_workspace_save(raw);
}

void wq_workspace_remove_tab(NSString *path)
{
    if (!path.length) return;
    NSString *std = [path stringByStandardizingPath];
    NSMutableArray<NSDictionary<NSString *, id> *> *raw = wq_workspace_raw();
    NSIndexSet *hit = [raw indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger __unused idx, BOOL *__unused stop) {
        return [[obj[@"path"] stringByStandardizingPath] isEqualToString:std];
    }];
    if (hit.count) {
        [raw removeObjectsAtIndexes:hit];
        wq_workspace_save(raw);
    }
}

NSArray<WQWorkspaceTab *> *wq_workspace_other_tabs(NSString *currentPath)
{
    NSString *std = [currentPath stringByStandardizingPath];
    NSMutableArray<WQWorkspaceTab *> *out = [NSMutableArray new];
    for (WQWorkspaceTab *t in wq_workspace_tabs()) {
        if (![[t.path stringByStandardizingPath] isEqualToString:std]) [out addObject:t];
    }
    return out;
}

@interface WQWorkspaceSheetViewController : UITableViewController
- (instancetype)initWithCurrentPath:(NSString *)path title:(nullable NSString *)title readOnly:(BOOL)ro onSelect:(void (^)(WQWorkspaceTab *tab))onSelect;
@end

@implementation WQWorkspaceSheetViewController {
    NSString *_currentPath;
    NSString *_currentTitle;
    BOOL _currentRO;
    void (^_onSelect)(WQWorkspaceTab *);
    NSArray<WQWorkspaceTab *> *_tabs;
}

- (instancetype)initWithCurrentPath:(NSString *)path title:(NSString *)title readOnly:(BOOL)ro onSelect:(void (^)(WQWorkspaceTab *))onSelect
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _currentPath = [path stringByStandardizingPath];
        _currentTitle = title.length ? [title copy] : (_currentPath.lastPathComponent.length ? _currentPath.lastPathComponent : @"/");
        _currentRO = ro;
        _onSelect = [onSelect copy];
        self.title = WQLocalized(@"Folder Tabs");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(closeSheet)];
    [self reloadTabs];
}

- (void)closeSheet
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadTabs
{
    _tabs = wq_workspace_tabs();
    [self.tableView reloadData];
}

- (BOOL)currentAlreadyPinned
{
    for (WQWorkspaceTab *t in _tabs) {
        if ([[t.path stringByStandardizingPath] isEqualToString:_currentPath]) return YES;
    }
    return NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    return MAX(1, (NSInteger)_tabs.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Current Folder");
    return WQLocalizedFormat(@"Open Tabs (%lu / 6)", (unsigned long)_tabs.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) {
        return WQLocalized(@"Pin up to 6 folders to jump between them in one tap, or long-press any file to Copy / Move directly into another open tab. Swipe left on a tab to close it.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ws-tab"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ws-tab"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (indexPath.section == 0) {
        BOOL pinned = [self currentAlreadyPinned];
        c.text = pinned ? WQLocalizedFormat(@"Pinned: %@", _currentTitle) : WQLocalizedFormat(@"Pin “%@” as New Tab", _currentTitle);
        c.secondaryText = _currentPath;
        c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
        c.image = [UIImage systemImageNamed:pinned ? @"pin.fill" : @"plus.rectangle.on.folder.fill"];
        c.imageProperties.tintColor = wq_theme_accent();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (!_tabs.count) {
        c.text = WQLocalized(@"No Open Tabs Yet");
        c.secondaryText = WQLocalized(@"Tap above to pin this folder as your first tab.");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQWorkspaceTab *t = _tabs[(NSUInteger)indexPath.row];
    BOOL active = [[t.path stringByStandardizingPath] isEqualToString:_currentPath];
    c.text = active ? [t.title stringByAppendingString:WQLocalized(@" (Current)")] : t.title;
    c.secondaryText = t.path;
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.image = [UIImage systemImageNamed:active ? @"folder.fill.badge.person.crop" : @"folder.fill"];
    c.imageProperties.tintColor = active ? wq_theme_aurora_teal() : wq_theme_accent();
    cell.contentConfiguration = c;
    cell.accessoryType = active ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        wq_workspace_pin_tab(_currentPath, _currentTitle, _currentRO);
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self reloadTabs];
        return;
    }
    if (!_tabs.count) return;
    WQWorkspaceTab *picked = _tabs[(NSUInteger)indexPath.row];
    wq_haptic_selection();
    void (^cb)(WQWorkspaceTab *) = _onSelect;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(picked);
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 1 || !_tabs.count) return nil;
    WQWorkspaceTab *t = _tabs[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *close = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                        title:WQLocalized(@"Close")
                                                                      handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        wq_workspace_remove_tab(t.path);
        [weakSelf reloadTabs];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[close]];
}

@end

void wq_present_workspace_tabs(UIViewController *host,
                               NSString *currentPath,
                               NSString *currentTitle,
                               BOOL currentReadOnly,
                               void (^onSelectTab)(WQWorkspaceTab *tab))
{
    WQWorkspaceSheetViewController *vc = [[WQWorkspaceSheetViewController alloc] initWithCurrentPath:currentPath
                                                                                               title:currentTitle
                                                                                            readOnly:currentReadOnly
                                                                                            onSelect:onSelectTab];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 28;
    }
    [host presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Inline Folder Tab Strip

@implementation WQFolderTabStripView {
    UIScrollView *_scroll;
    UIStackView *_stack;
    UIButton *_addBtn;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        _scroll = [UIScrollView new];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.alwaysBounceHorizontal = YES;
        [self addSubview:_scroll];

        _stack = [UIStackView new];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.alignment = UIStackViewAlignmentCenter;
        _stack.spacing = 6;
        [_scroll addSubview:_stack];

        _addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _addBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *addCfg = [UIButtonConfiguration glassButtonConfiguration];
        addCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        addCfg.image = [UIImage systemImageNamed:@"plus"
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]];
        addCfg.contentInsets = NSDirectionalEdgeInsetsMake(5, 9, 5, 9);
        addCfg.baseForegroundColor = wq_theme_accent();
        addCfg.baseBackgroundColor = wq_theme_glass_tint();
        _addBtn.configuration = addCfg;
        _addBtn.accessibilityLabel = WQLocalized(@"Folder Tabs…");
        __weak typeof(self) weakSelf = self;
        [_addBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            wq_haptic_selection();
            if (weakSelf.onManageTabs) weakSelf.onManageTabs();
        }] forControlEvents:UIControlEventTouchUpInside];
        wq_theme_add_spring_tap(_addBtn);
        [self addSubview:_addBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_addBtn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_addBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_addBtn.heightAnchor constraintEqualToConstant:30],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_scroll.trailingAnchor constraintEqualToAnchor:_addBtn.leadingAnchor constant:-6],
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
            [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
            [_stack.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],
        ]];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadTabs) name:WQWorkspaceTabsDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadTabs) name:WQThemeDidChangeNotification object:nil];
        [self reloadTabs];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setCurrentPath:(NSString *)currentPath
{
    _currentPath = [currentPath stringByStandardizingPath] ?: @"";
    [self reloadTabs];
}

- (void)reloadTabs
{
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    UIButtonConfiguration *addCfg = [_addBtn.configuration copy];
    addCfg.baseForegroundColor = wq_theme_accent();
    addCfg.baseBackgroundColor = wq_theme_glass_tint();
    _addBtn.configuration = addCfg;

    NSArray<WQWorkspaceTab *> *tabs = wq_workspace_tabs();
    NSString *cur = [_currentPath stringByStandardizingPath];
    __weak typeof(self) weakSelf = self;

    for (WQWorkspaceTab *tab in tabs) {
        BOOL active = cur.length > 0 && [[tab.path stringByStandardizingPath] isEqualToString:cur];
        UIVisualEffectView *pill = wq_theme_make_glass_card(14, YES);
        pill.layer.borderColor = (active ? wq_theme_accent() : wq_theme_rim()).CGColor;
        pill.layer.borderWidth = active ? 1.2 : 0.7;
        if (active) {
            pill.contentView.backgroundColor = [wq_theme_accent() colorWithAlphaComponent:0.16];
        }

        UIButton *titleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        titleBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *tcfg = [UIButtonConfiguration plainButtonConfiguration];
        tcfg.title = tab.title;
        tcfg.image = [UIImage systemImageNamed:active ? @"folder.fill" : @"folder"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]];
        tcfg.imagePadding = 4;
        tcfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 10, 4, 4);
        tcfg.baseForegroundColor = active ? wq_theme_primary_text() : wq_theme_secondary_text();
        tcfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *in) {
            NSMutableDictionary *out = [in mutableCopy] ?: [NSMutableDictionary new];
            out[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:active ? UIFontWeightBold : UIFontWeightSemibold];
            return out;
        };
        titleBtn.configuration = tcfg;
        [titleBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            wq_haptic_selection();
            if (weakSelf.onSelectTab) weakSelf.onSelectTab(tab);
        }] forControlEvents:UIControlEventTouchUpInside];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *ccfg = [UIButtonConfiguration plainButtonConfiguration];
        ccfg.image = [UIImage systemImageNamed:@"xmark"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9.5 weight:UIImageSymbolWeightBold]];
        ccfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 2, 4, 8);
        ccfg.baseForegroundColor = wq_theme_secondary_text();
        closeBtn.configuration = ccfg;
        NSString *tabPath = [tab.path copy];
        [closeBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            wq_haptic_selection();
            wq_workspace_remove_tab(tabPath);
        }] forControlEvents:UIControlEventTouchUpInside];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[titleBtn, closeBtn]];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 0;
        [pill.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [pill.heightAnchor constraintEqualToConstant:30],
            [titleBtn.widthAnchor constraintLessThanOrEqualToConstant:145],
            [row.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor],
            [row.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor],
        ]];
        [_stack addArrangedSubview:pill];
    }
}

@end

#pragma mark - Persistent Multi-Container Drop Shelf

static NSMutableArray<NSString *> *wq_drop_shelf_raw(void)
{
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kWQDropShelfPref];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id obj in saved) {
            if ([obj isKindOfClass:NSString.class] && [obj length]) {
                [out addObject:obj];
            }
        }
    }
    return out;
}

NSArray<NSString *> *wq_drop_shelf_items(void)
{
    return [wq_drop_shelf_raw() copy];
}

void wq_drop_shelf_add(NSArray<NSString *> *paths)
{
    if (!paths.count) return;
    NSMutableArray<NSString *> *items = wq_drop_shelf_raw();
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:items];
    for (NSString *p in paths) {
        if (!p.length) continue;
        NSString *std = [p stringByStandardizingPath];
        if (![seen containsObject:std]) {
            [seen addObject:std];
            [items addObject:std];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:items forKey:kWQDropShelfPref];
    [NSNotificationCenter.defaultCenter postNotificationName:WQDropShelfDidChangeNotification object:nil];
}

void wq_drop_shelf_remove(NSString *path)
{
    if (!path.length) return;
    NSString *std = [path stringByStandardizingPath];
    NSMutableArray<NSString *> *items = wq_drop_shelf_raw();
    [items removeObject:std];
    [NSUserDefaults.standardUserDefaults setObject:items forKey:kWQDropShelfPref];
    [NSNotificationCenter.defaultCenter postNotificationName:WQDropShelfDidChangeNotification object:nil];
}

void wq_drop_shelf_clear(void)
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQDropShelfPref];
    [NSNotificationCenter.defaultCenter postNotificationName:WQDropShelfDidChangeNotification object:nil];
}

@implementation WQDropShelfPillView {
    UIVisualEffectView *_card;
    UIButton *_btn;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _card = wq_theme_make_glass_card(18, YES);
        _card.layer.borderColor = wq_theme_aurora_teal().CGColor;
        _card.layer.borderWidth = 1.0;
        [self addSubview:_card];

        _btn = [UIButton buttonWithType:UIButtonTypeSystem];
        _btn.translatesAutoresizingMaskIntoConstraints = NO;
        __weak typeof(self) weakSelf = self;
        [_btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            wq_haptic_selection();
            if (weakSelf.onTap) weakSelf.onTap();
        }] forControlEvents:UIControlEventTouchUpInside];
        wq_theme_add_spring_tap(_btn);
        [_card.contentView addSubview:_btn];

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_btn.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor],
            [_btn.bottomAnchor constraintEqualToAnchor:_card.contentView.bottomAnchor],
            [_btn.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor],
            [_btn.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor],
            [self.heightAnchor constraintEqualToConstant:36],
        ]];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:WQDropShelfDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:WQThemeDidChangeNotification object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)refresh
{
    NSUInteger count = wq_drop_shelf_items().count;
    self.hidden = (count == 0);
    if (count == 0) return;

    _card.layer.borderColor = wq_theme_aurora_teal().CGColor;
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:@"tray.full.fill"
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]];
    cfg.imagePadding = 6;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.title = count == 1
        ? WQLocalized(@"Shelf · 1 item")
        : WQLocalizedFormat(@"Shelf · %lu items", (unsigned long)count);
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *in) {
        NSMutableDictionary *out = [in mutableCopy] ?: [NSMutableDictionary new];
        out[NSFontAttributeName] = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        return out;
    };
    _btn.configuration = cfg;
}

@end
