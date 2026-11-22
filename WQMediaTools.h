//
//  WQMediaTools.h
//  WQ Glass Privacy Photo EXIF Scrubber, Image Converter & Video-to-Audio Studio
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQMediaToolsViewController : UITableViewController
- (instancetype)initWithInitialPath:(nullable NSString *)path;
@end

void wq_present_media_tools(UIViewController *host, NSString *_Nullable filePath);

NS_ASSUME_NONNULL_END
