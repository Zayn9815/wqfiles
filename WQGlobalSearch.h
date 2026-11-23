//
//  WQGlobalSearch.h
//  WQ Glass Universal Spotlight Search Engine (iPhone Duo)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Presents the morphing frosted optical glass Spotlight overlay.
// When `showRecentsFirst` is YES (e.g. triggered via press-and-hold),
// Recent Searches and In-App Quick Commands are highlighted immediately.
void wq_global_search_present(UIViewController *host, BOOL showRecentsFirst);

// Frosted-glass Search Pill Button for the top Home header bar.
// Tap opens Spotlight; press-and-hold opens Recent Searches & Quick Commands.
UIButton *wq_global_search_pill_button(UIViewController *host);

// Dedicated Search button for floating bottom Dynamic Island command capsules.
// Tap opens Spotlight; press-and-hold opens Recent Searches & Quick Commands.
UIButton *wq_global_search_dock_button(UIViewController *host);

// Registers the app-level dispatcher for Spotlight quick commands:
// "full_scan", "quick_check", "clean_caches", "open_vault", "open_logs", "jump_path".
void wq_global_search_register_command_handler(void (^handler)(NSString *commandID, UIViewController *host));

void wq_recent_files_record(NSString *path);
NSArray<NSString *> *wq_recent_files_list(void);

NS_ASSUME_NONNULL_END
