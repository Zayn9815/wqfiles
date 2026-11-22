//
//  WQOCRStudio.h
//  WQ Glass Offline Apple Vision OCR & PDF Watermark Studio
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQOCRStudioViewController : UITableViewController
- (instancetype)initWithInitialPath:(nullable NSString *)filePath;
@end

void wq_present_ocr_studio(UIViewController *host, NSString *_Nullable filePath);

NS_ASSUME_NONNULL_END
