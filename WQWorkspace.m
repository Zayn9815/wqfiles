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

static NSString *const kWQWorkspaceTabsPref = @"WQWorkspaceTabs";
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
