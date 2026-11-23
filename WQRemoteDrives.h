//
//  WQRemoteDrives.h
//  WQ Glass Remote Drives Client (WebDAV HTTP/HTTPS & FTP via BSD Sockets)
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQRemoteDriveBookmark : NSObject
@property (nonatomic, copy) NSString *driveID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *protocol; // @"webdav" or @"ftp"
@property (nonatomic, copy) NSString *host;
@property (nonatomic) NSInteger port;
@property (nonatomic) BOOL useTLS;
@property (nonatomic, copy) NSString *basePath;
@property (nonatomic, copy) NSString *username;
@end

@interface WQRemoteDrivesViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
