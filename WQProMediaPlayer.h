//
//  WQProMediaPlayer.h
//  WQ Glass Infuse-Class Universal Media Player & Swipeable Gallery
//  GPL-3.0-or-later.
//

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Watch history persistence (0.0 – 1.0 progress fraction for cards & rows).
double wq_playback_progress_for_path(NSString *path);
void wq_playback_save_progress(NSString *path, double positionSeconds, double durationSeconds);

@interface WQProMediaPlayerViewController : UIViewController
@property (nonatomic, strong, readonly) AVPlayer *player;
@property (nonatomic, copy, nullable) void (^onConvert)(void);
- (instancetype)initWithTitle:(NSString *)title sourcePath:(NSString *)sourcePath;
- (void)loadPlayerItem:(AVPlayerItem *)item;
- (void)replaceWithLocalURL:(NSURL *)url;

/// Unified entry points for local files (including .ts/.m2ts/.mkv/.webm/.flv/.avi) and remote/HLS streams.
+ (void)presentPlayerFrom:(UIViewController *)host title:(NSString *)title localPath:(NSString *)localPath;
+ (void)presentStreamFrom:(UIViewController *)host
                    title:(NSString *)title
                streamURL:(NSURL *)url
                  headers:(NSDictionary<NSString *, NSString *> *_Nullable)headers;
@end

BOOL wq_is_gallery_image_path(NSString *path);

@interface WQGalleryViewController : UIViewController
- (instancetype)initWithImagePaths:(NSArray<NSString *> *)paths initialIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
