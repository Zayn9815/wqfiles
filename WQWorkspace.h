//
//  WQWorkspace.h
//  WQ Glass Multi-Tab Folder Workspace & Cross-Tab Transfer
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const WQWorkspaceTabsDidChangeNotification;
extern NSNotificationName const WQDropShelfDidChangeNotification;

@interface WQWorkspaceTab : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL readOnly;
@end

NSArray<WQWorkspaceTab *> *wq_workspace_tabs(void);
void wq_workspace_pin_tab(NSString *path, NSString *_Nullable title, BOOL readOnly);
void wq_workspace_remove_tab(NSString *path);
NSArray<WQWorkspaceTab *> *wq_workspace_other_tabs(NSString *currentPath);

/// Presents a sleek frosted-glass Folder Tabs sheet to switch tabs, pin current folder, or close tabs.
void wq_present_workspace_tabs(UIViewController *host,
                               NSString *currentPath,
                               NSString *_Nullable currentTitle,
                               BOOL currentReadOnly,
                               void (^onSelectTab)(WQWorkspaceTab *tab));

/// Compact frosted-glass horizontal tab strip for up to 6 open folder tabs.
@interface WQFolderTabStripView : UIView
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy, nullable) void (^onSelectTab)(WQWorkspaceTab *tab);
@property (nonatomic, copy, nullable) void (^onManageTabs)(void);
- (void)reloadTabs;
@end

/// Persistent Multi-Container Drop Shelf APIs.
NSArray<NSString *> *wq_drop_shelf_items(void);
void wq_drop_shelf_add(NSArray<NSString *> *paths);
void wq_drop_shelf_remove(NSString *path);
void wq_drop_shelf_clear(void);

/// Floating collapsible Drop Shelf pill ("Shelf · N items").
@interface WQDropShelfPillView : UIView
@property (nonatomic, copy, nullable) void (^onTap)(void);
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
