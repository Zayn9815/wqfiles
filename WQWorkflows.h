//
//  WQWorkflows.h
//  WQ Glass One-Tap Dry-Run Folder Automation Workflows
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQWorkflowsViewController : UITableViewController
- (instancetype)initWithRootPath:(NSString *)rootPath title:(nullable NSString *)title;
@end

NS_ASSUME_NONNULL_END
