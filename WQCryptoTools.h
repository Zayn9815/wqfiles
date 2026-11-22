//
//  WQCryptoTools.h
//  WQ Glass Portable PBKDF2 + AES-256 (.wqenc) File Locker & Secure Shredder
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQCryptoToolsViewController : UITableViewController
- (instancetype)initWithInitialPath:(nullable NSString *)filePath;
@end

void wq_present_crypto_tools(UIViewController *host, NSString *_Nullable filePath);

/// Double-confirmed 1-pass overwrite + unlink secure shredder (respects Safe Mode & Allow Deleting).
void wq_confirm_secure_shred(UIViewController *host, NSString *filePath, void (^_Nullable onDone)(BOOL ok));

NS_ASSUME_NONNULL_END
