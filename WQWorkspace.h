//
//  WQWorkspace.h
//  WQ Glass Multi-Tab Folder Workspace & Cross-Tab Transfer
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END
