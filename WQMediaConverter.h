//
//  WQMediaConverter.h
//  WQ Glass
//
//  Native offline Video & Audio Format + Encoding Converter (AVFoundation + AudioToolbox).
//  Supports MP4/MOV/M4V (H.264 / HEVC / Resolution / Bitrate) and M4A (AAC / ALAC),
//  WAV, AIFF, CAF, and FLAC audio conversion & extraction with live progress.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQMediaConverterViewController : UITableViewController
- (instancetype)initWithFilePath:(NSString *)filePath NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

BOOL wq_is_convertible_media_path(NSString *path);
void wq_present_media_converter(UIViewController *host, NSString *filePath);

NS_ASSUME_NONNULL_END
