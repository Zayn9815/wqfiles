//
//  WQContentSearch.h
//  WQ Glass Deep Content & Regular Expression Grep Search
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQContentSearchViewController : UITableViewController
- (instancetype)initWithRootPath:(NSString *)rootPath title:(nullable NSString *)title readOnly:(BOOL)readOnly;
@end

NS_ASSUME_NONNULL_END
