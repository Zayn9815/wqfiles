//
//  WQWinTransfer.h
//  WQ Glass
//
//  Symmetric iPhone <-> Windows <-> Android Wi-Fi LAN Transfer (Host + Client)
//  with UDP Auto-Discovery (port 45888) and browser fallback.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const WQLanTransferStatusDidChangeNotification;

typedef NS_ENUM(NSInteger, WQLanConnectionMode) {
    WQLanConnectionModeNotConnected = 0,
    WQLanConnectionModeWaitingReady = 1,
    WQLanConnectionModeConnectedUSB = 2,
    WQLanConnectionModeConnectedWiFi = 3,
};

@interface WQLanTransferConnectionSnapshot : NSObject
@property (nonatomic, assign) WQLanConnectionMode mode;
@property (nonatomic, copy) NSString *transport; // @"none", @"usb", @"wifi"
@property (nonatomic, copy) NSString *peerName;
@property (nonatomic, copy) NSString *endpointText;
@property (nonatomic, copy) NSString *pinText;
@property (nonatomic, copy) NSString *rootLabel;
@property (nonatomic, assign) double activeBytesPerSec;
@property (nonatomic, assign) BOOL serverRunning;
- (NSString *)statusTitle;
- (NSString *)statusSubtitle;
@end

WQLanTransferConnectionSnapshot *wq_lan_transfer_current_status(void);
void wq_lan_transfer_ensure_background_server(void);
UIView *wq_lan_transfer_make_global_status_pill(void (^onTap)(void));

@interface WQWinTransferViewController : UITableViewController
- (instancetype)initWithInitialRootPath:(nullable NSString *)rootPath title:(nullable NSString *)rootTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

void wq_present_windows_transfer(UIViewController *host, NSString *_Nullable rootPath, NSString *_Nullable title);

NS_ASSUME_NONNULL_END
