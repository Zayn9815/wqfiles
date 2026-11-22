//
//  WQSecurity.h
//  WQ Glass Face ID / Touch ID App Lock & Privacy Shield
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kWQAppLockEnabledPref;

// Whether Face ID / Touch ID / Passcode App Lock is enabled in Settings.
BOOL wq_app_lock_enabled(void);
void wq_app_lock_set_enabled(BOOL enabled);

// Human-readable name for the device's authentication method ("Face ID", "Touch ID", or "Passcode").
NSString *wq_app_lock_biometry_name(void);

// Evaluates LocalAuthentication (biometrics with automatic device passcode fallback).
// Completion always runs on the main queue.
void wq_app_lock_authenticate(NSString *reason, void (^completion)(BOOL ok, NSString *_Nullable errorText));

// Attaches the App Lock controller & App Switcher privacy blur shield to the app window.
void wq_app_lock_attach_window(UIWindow *window);

NS_ASSUME_NONNULL_END
