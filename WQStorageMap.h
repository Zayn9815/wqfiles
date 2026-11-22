//
//  WQStorageMap.h
//  WQ Glass Visual Storage Analyzer & Category Breakdown (DaisyDisk-Style)
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQStorageMapViewController : UITableViewController
- (instancetype)initWithRootPath:(NSString *)rootPath title:(nullable NSString *)title;
@end

NS_ASSUME_NONNULL_END
