//
//  WQWinTransfer.h
//  WQ Glass
//
//  Symmetric iPhone <-> Windows <-> Android Wi-Fi LAN Transfer (Host + Client)
//  with UDP Auto-Discovery (port 45888) and browser fallback.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQWinTransferViewController : UITableViewController
- (instancetype)initWithInitialRootPath:(nullable NSString *)rootPath title:(nullable NSString *)rootTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

void wq_present_windows_transfer(UIViewController *host, NSString *_Nullable rootPath, NSString *_Nullable title);

NS_ASSUME_NONNULL_END
