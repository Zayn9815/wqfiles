//
//  WQFloatingHUD.h
//  WQ Glass Customizable Live Floating Telemetry Bubble (Network Speed + Battery Wattage + PiP)
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    BOOL valid;
    BOOL fromHardware;       // YES when IOKit AppleSmartBattery sensors are readable
    double watts;            // Positive = charging power, negative = discharging draw
    double amperageMA;       // Instantaneous current in mA (signed)
    double voltageMV;        // Pack voltage in mV
    double temperatureC;     // Battery temperature in Celsius (NAN if unavailable)
    NSInteger cycleCount;    // -1 if unavailable
    double adapterWatts;     // Charger rated watts (0 if unplugged/unknown)
    double adapterVoltageMV; // Charger voltage in mV (0 if unknown)
    double adapterCurrentMA; // Charger current in mA (0 if unknown)
    float batteryLevel;      // 0.0..1.0 or -1.0 if unknown
    UIDeviceBatteryState batteryState;
} WQBatteryPowerSnapshot;

typedef struct {
    double downBytesPerSec;
    double upBytesPerSec;
    uint64_t totalRxBytes;
    uint64_t totalTxBytes;
} WQNetSpeedSnapshot;

/// Reads live battery wattage/current/voltage safely via runtime-probed IOKit
/// with graceful UIDevice estimation fallback if sandboxed.
WQBatteryPowerSnapshot wq_read_battery_power(void);

/// Samples real-time download/upload throughput across active en* and pdp_ip* interfaces.
WQNetSpeedSnapshot wq_sample_network_speed(void);

/// Formats bytes/sec concisely (e.g. "1.4 MB/s" or "42 KB/s").
NSString *wq_format_net_speed(double bytesPerSec);

/// Shared controller managing both the In-App Draggable Frosted Pill and System-Wide PiP HUD.
@interface WQFloatingHUDManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) BOOL inAppHUDRunning;
@property (nonatomic, readonly) BOOL pipHUDRunning;
- (void)startInAppHUD;
- (void)stopInAppHUD;
- (void)startPiPHUDFromHost:(UIViewController *)host;
- (void)stopPiPHUD;
- (void)stopAll;
- (void)refreshAppearanceAndLayout;
@end

/// Pre-launch customizer where the user chooses which live metrics appear in the floating bubble.
@interface WQFloatingHUDConfigViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
