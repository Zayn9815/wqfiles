//
//  WQWorkbench.h
//  WQ Glass Everyday Utility Workbench (QR Studio, Password/UUID, Scratchpad, Dev Converters)
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQWorkbenchViewController : UITableViewController
@end

// Presents a crisp frosted-glass QR code modal with Save / Share buttons for any text or URL.
void wq_present_qr_modal(UIViewController *host, NSString *payload, NSString *_Nullable title);

NS_ASSUME_NONNULL_END
