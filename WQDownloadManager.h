//
//  WQDownloadManager.h
//  WQ Glass IDM / 1DM Style Multi-Part Accelerated Download Engine & HLS Quality Picker
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const WQDownloadManagerDidUpdateNotification;

typedef NS_ENUM(NSInteger, WQDownloadState) {
    WQDownloadStateQueued = 0,
    WQDownloadStateProbing,
    WQDownloadStateDownloading,
    WQDownloadStatePaused,
    WQDownloadStateCompleted,
    WQDownloadStateFailed,
};

@interface WQDownloadPart : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) int64_t startOffset;
@property (nonatomic) int64_t endOffset;
@property (nonatomic) int64_t downloadedBytes;
@property (nonatomic) BOOL finished;
- (double)progress;
@end

@interface WQDownloadItem : NSObject
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *destinationDir;
@property (nonatomic, copy, nullable) NSString *localPath;
@property (nonatomic, copy, nullable) NSString *partialPath;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic) WQDownloadState state;
@property (nonatomic) int64_t totalBytes;
@property (nonatomic) int64_t downloadedBytes;
@property (nonatomic) double bytesPerSec;
@property (nonatomic) NSInteger partCount;
@property (nonatomic) BOOL supportsRanges;
@property (nonatomic) BOOL isHLS;
@property (nonatomic) NSInteger hlsTotalSegments;
@property (nonatomic) NSInteger hlsDoneSegments;
@property (nonatomic, copy, nullable) NSString *qualityLabel;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic) NSTimeInterval createdAt;
@property (nonatomic, copy) NSArray<WQDownloadPart *> *parts;
- (double)progress;
@end

@interface WQHLSVariant : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) long long bandwidth;
@property (nonatomic) BOOL isAudioOnly;
@end

/// Root Documents/Downloads directory (auto-created).
NSString *wq_downloads_root_dir(void);
/// Auto-categorized subfolder name (Videos, Audio, Documents, Archives, Apps, Images, Other).
NSString *wq_download_category_for_filename(NSString *filename);

/// Fetches & parses an HLS (.m3u8) master/media playlist into selectable quality variants.
void wq_fetch_hls_variants(NSString *m3u8URL,
                           NSDictionary<NSString *, NSString *> *_Nullable headers,
                           void (^completion)(NSArray<WQHLSVariant *> *variants, BOOL isDRM, NSString *_Nullable errorText));

/// Presents an IDM/1DM Quality Picker sheet for any HLS (.m3u8) stream and starts downloading the picked quality.
void wq_present_hls_quality_picker(UIViewController *host,
                                   NSString *m3u8URL,
                                   NSString *_Nullable suggestedFilename,
                                   NSDictionary<NSString *, NSString *> *_Nullable headers);

/// Presents a native frosted-glass "Add Download" confirmation sheet (filename, folder/tab picker, part count).
void wq_present_add_download_sheet(UIViewController *host,
                                   NSString *urlString,
                                   NSString *_Nullable suggestedFilename,
                                   int64_t knownSize,
                                   NSDictionary<NSString *, NSString *> *_Nullable headers,
                                   BOOL isHLS,
                                   NSString *_Nullable qualityLabel);

@interface WQDownloadManager : NSObject
+ (instancetype)sharedManager;

@property (nonatomic, readonly) NSArray<WQDownloadItem *> *items;
@property (nonatomic, readonly) NSUInteger activeCount;

@property (nonatomic) NSInteger defaultPartCount;        // 2, 4, 8, or 16
@property (nonatomic) NSInteger maxConcurrentDownloads;  // 1, 2, or 3
@property (nonatomic) NSInteger speedLimitKBps;          // 0 = unlimited, 1024, 2048, 5120
@property (nonatomic) BOOL wifiOnly;

- (WQDownloadItem *)enqueueURLString:(NSString *)urlString
                   suggestedFilename:(NSString *_Nullable)filename
                      destinationDir:(NSString *_Nullable)destinationDir
                             headers:(NSDictionary<NSString *, NSString *> *_Nullable)headers
                           partCount:(NSInteger)partCount
                               isHLS:(BOOL)isHLS
                        qualityLabel:(NSString *_Nullable)qualityLabel
                          startNow:(BOOL)startNow;

- (void)startOrResumeItem:(WQDownloadItem *)item;
- (void)pauseItem:(WQDownloadItem *)item;
- (void)retryItem:(WQDownloadItem *)item;
- (void)refreshAddressForItem:(WQDownloadItem *)item
                 newURLString:(NSString *)newURLString
                   newHeaders:(NSDictionary<NSString *, NSString *> *_Nullable)newHeaders;
- (void)deleteItem:(WQDownloadItem *)item removeFile:(BOOL)removeFile;
- (void)pauseAll;
- (void)resumeAll;
- (void)clearCompleted;
@end

@interface WQDownloadManagerViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
