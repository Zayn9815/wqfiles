//
//  WQDuplicates.h
//  WQ Glass Smart 3-Stage Duplicate File Hunter (QOS_CLASS_UTILITY)
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQDuplicatesViewController : UITableViewController
- (instancetype)initWithRootPath:(NSString *)rootPath title:(nullable NSString *)title;
@end

NS_ASSUME_NONNULL_END
