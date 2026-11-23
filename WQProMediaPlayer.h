//
//  WQProMediaPlayer.h
//  WQ Glass Pro Media Player (PiP, Background Audio, Subtitles, Gestures) & Swipeable Gallery
//  GPL-3.0-or-later.
//

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQProMediaPlayerViewController : UIViewController
@property (nonatomic, strong, readonly) AVPlayer *player;
@property (nonatomic, copy, nullable) void (^onConvert)(void);
- (instancetype)initWithTitle:(NSString *)title sourcePath:(NSString *)sourcePath;
- (void)loadPlayerItem:(AVPlayerItem *)item;
- (void)replaceWithLocalURL:(NSURL *)url;
@end

BOOL wq_is_gallery_image_path(NSString *path);

@interface WQGalleryViewController : UIViewController
- (instancetype)initWithImagePaths:(NSArray<NSString *> *)paths initialIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
