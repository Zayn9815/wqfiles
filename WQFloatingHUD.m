//
//  WQFloatingHUD.m
//  WQ Glass Customizable Live Floating Telemetry Bubble (Network Speed + Battery Wattage + PiP)
//  GPL-3.0-or-later.
//

#import "WQFloatingHUD.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <mach/mach.h>
#import <math.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <stdint.h>
#import <string.h>

#pragma mark - UserDefaults Customization Keys

static NSString *const kWQHUDShowDown = @"WQHUDShowDown";
static NSString *const kWQHUDShowUp = @"WQHUDShowUp";
static NSString *const kWQHUDShowWatts = @"WQHUDShowWatts";
static NSString *const kWQHUDShowCurrentVolt = @"WQHUDShowCurrentVolt";
static NSString *const kWQHUDShowBatteryPct = @"WQHUDShowBatteryPct";
static NSString *const kWQHUDShowRAM = @"WQHUDShowRAM";
static NSString *const kWQHUDShowThermal = @"WQHUDShowThermal";
static NSString *const kWQHUDExpanded = @"WQHUDExpanded";
static NSString *const kWQHUDInterval = @"WQHUDInterval";

static BOOL wq_hud_pref_bool(NSString *key, BOOL defaultValue)
{
    id val = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return val ? [val boolValue] : defaultValue;
}

static NSTimeInterval wq_hud_interval(void)
{
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:kWQHUDInterval];
    return (v >= 1.5) ? 2.0 : 1.0;
}

#pragma mark - Safe Runtime IOKit Battery Power Probe + Graceful Fallback

typedef CFMutableDictionaryRef (*WQIOServiceMatchingFn)(const char *name);
typedef uint32_t (*WQIOServiceGetMatchingServiceFn)(uint32_t mainPort, CFDictionaryRef matching);
typedef int32_t (*WQIORegistryEntryCreateCFPropertiesFn)(uint32_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
typedef int32_t (*WQIOObjectReleaseFn)(uint32_t object);

static NSDictionary *wq_probe_smart_battery_dict(void)
{
    static void *iokit = NULL;
    static WQIOServiceMatchingFn fnMatching = NULL;
    static WQIOServiceGetMatchingServiceFn fnGetService = NULL;
    static WQIORegistryEntryCreateCFPropertiesFn fnCreateProps = NULL;
    static WQIOObjectReleaseFn fnRelease = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (iokit) {
            fnMatching = (WQIOServiceMatchingFn)dlsym(iokit, "IOServiceMatching");
            fnGetService = (WQIOServiceGetMatchingServiceFn)dlsym(iokit, "IOServiceGetMatchingService");
            fnCreateProps = (WQIORegistryEntryCreateCFPropertiesFn)dlsym(iokit, "IORegistryEntryCreateCFProperties");
            fnRelease = (WQIOObjectReleaseFn)dlsym(iokit, "IOObjectRelease");
        }
    });
    if (!fnMatching || !fnGetService || !fnCreateProps || !fnRelease) return nil;
    CFMutableDictionaryRef match = fnMatching("AppleSmartBattery");
    if (!match) return nil;
    uint32_t service = fnGetService(0, match);
    if (!service) return nil;
    CFMutableDictionaryRef props = NULL;
    int32_t kr = fnCreateProps(service, &props, kCFAllocatorDefault, 0);
    fnRelease(service);
    if (kr != 0 || !props) return nil;
    return (__bridge_transfer NSDictionary *)props;
}

static double gWQPrevBattLevel = -1.0;
static CFAbsoluteTime gWQPrevBattTime = 0;
static double gWQEstWatts = NAN;

WQBatteryPowerSnapshot wq_read_battery_power(void)
{
    WQBatteryPowerSnapshot s;
    memset(&s, 0, sizeof(s));
    s.temperatureC = NAN;
    s.cycleCount = -1;
    s.batteryLevel = -1.0f;

    UIDevice *dev = UIDevice.currentDevice;
    BOOL prevMon = dev.batteryMonitoringEnabled;
    if (!prevMon && NSThread.isMainThread) dev.batteryMonitoringEnabled = YES;
    s.batteryLevel = dev.batteryLevel;
    s.batteryState = dev.batteryState;
    if (!prevMon && NSThread.isMainThread) dev.batteryMonitoringEnabled = NO;

    NSDictionary *hw = wq_probe_smart_battery_dict();
    if ([hw isKindOfClass:NSDictionary.class] && hw.count > 0) {
        NSNumber *voltNum = hw[@"Voltage"] ?: hw[@"AppleRawBatteryVoltage"];
        NSNumber *ampNum = hw[@"InstantAmperage"] ?: hw[@"Amperage"];
        if (voltNum && ampNum) {
            double mv = voltNum.doubleValue;
            // InstantAmperage is sometimes reported as 64-bit unsigned two's complement
            int64_t rawMa = ampNum.longLongValue;
            double ma = (double)rawMa;
            if (mv > 1000.0 && mv < 20000.0 && fabs(ma) < 20000.0) {
                s.valid = YES;
                s.fromHardware = YES;
                s.voltageMV = mv;
                s.amperageMA = ma;
                s.watts = (mv / 1000.0) * (ma / 1000.0);
            }
        }
        NSNumber *tempNum = hw[@"Temperature"];
        if (tempNum && tempNum.doubleValue > 100.0) {
            // AppleSmartBattery reports centi-Celsius (e.g. 3120 = 31.2 C)
            s.temperatureC = tempNum.doubleValue / 100.0;
        }
        NSNumber *cycles = hw[@"CycleCount"];
        if (cycles) s.cycleCount = cycles.integerValue;
        NSDictionary *adapter = hw[@"AdapterDetails"];
        if ([adapter isKindOfClass:NSDictionary.class]) {
            s.adapterWatts = [adapter[@"Watts"] doubleValue];
            s.adapterVoltageMV = [adapter[@"AdapterVoltage"] doubleValue];
            s.adapterCurrentMA = [adapter[@"Current"] doubleValue];
            if (s.adapterWatts <= 0 && s.adapterVoltageMV > 0 && s.adapterCurrentMA > 0) {
                s.adapterWatts = (s.adapterVoltageMV / 1000.0) * (s.adapterCurrentMA / 1000.0);
            }
        }
    }

    if (!s.valid && s.batteryLevel >= 0.0f) {
        // Honest UIDevice estimation fallback (typical iPhone ~16 Wh pack).
        s.valid = YES;
        s.fromHardware = NO;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        @synchronized (NSNull.null) {
            if (gWQPrevBattLevel >= 0.0 && now - gWQPrevBattTime >= 20.0 && fabs(s.batteryLevel - gWQPrevBattLevel) >= 0.005) {
                double dFrac = (double)s.batteryLevel - gWQPrevBattLevel;
                double hours = (now - gWQPrevBattTime) / 3600.0;
                gWQEstWatts = (dFrac * 16.0) / MAX(hours, 0.001);
                gWQPrevBattLevel = s.batteryLevel;
                gWQPrevBattTime = now;
            } else if (gWQPrevBattLevel < 0.0) {
                gWQPrevBattLevel = s.batteryLevel;
                gWQPrevBattTime = now;
            }
            if (isfinite(gWQEstWatts)) {
                s.watts = gWQEstWatts;
            } else {
                // Nominal baseline estimate by charging state & thermal load when no delta observed yet.
                if (s.batteryState == UIDeviceBatteryStateCharging) s.watts = 12.0;
                else if (s.batteryState == UIDeviceBatteryStateFull) s.watts = 0.0;
                else {
                    NSProcessInfoThermalState th = NSProcessInfo.processInfo.thermalState;
                    s.watts = (th >= NSProcessInfoThermalStateSerious) ? -4.5
                            : (th == NSProcessInfoThermalStateFair) ? -2.8
                            : -1.6;
                }
            }
        }
        s.voltageMV = 3850.0;
        s.amperageMA = (s.watts / 3.85) * 1000.0;
    }
    return s;
}

#pragma mark - Real-Time BSD Network Speed Sampler

static uint64_t gWQPrevRx = 0;
static uint64_t gWQPrevTx = 0;
static CFAbsoluteTime gWQPrevNetTime = 0;

WQNetSpeedSnapshot wq_sample_network_speed(void)
{
    WQNetSpeedSnapshot snap = {0, 0, 0, 0};
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0 && list) {
        for (struct ifaddrs *cur = list; cur; cur = cur->ifa_next) {
            if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_LINK || !cur->ifa_data) continue;
            if ((cur->ifa_flags & IFF_LOOPBACK) || !(cur->ifa_flags & IFF_UP)) continue;
            if (!cur->ifa_name) continue;
            if (strncmp(cur->ifa_name, "en", 2) != 0 && strncmp(cur->ifa_name, "pdp_ip", 6) != 0) continue;
            const struct if_data *d = (const struct if_data *)cur->ifa_data;
            snap.totalRxBytes += (uint64_t)d->ifi_ibytes;
            snap.totalTxBytes += (uint64_t)d->ifi_obytes;
        }
        freeifaddrs(list);
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (NSNull.null) {
        if (gWQPrevNetTime > 0 && now > gWQPrevNetTime) {
            double dt = now - gWQPrevNetTime;
            if (snap.totalRxBytes >= gWQPrevRx) snap.downBytesPerSec = (double)(snap.totalRxBytes - gWQPrevRx) / dt;
            if (snap.totalTxBytes >= gWQPrevTx) snap.upBytesPerSec = (double)(snap.totalTxBytes - gWQPrevTx) / dt;
        }
        gWQPrevRx = snap.totalRxBytes;
        gWQPrevTx = snap.totalTxBytes;
        gWQPrevNetTime = now;
    }
    return snap;
}

NSString *wq_format_net_speed(double bytesPerSec)
{
    if (!isfinite(bytesPerSec) || bytesPerSec < 0) bytesPerSec = 0;
    if (bytesPerSec >= 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1f MB/s", bytesPerSec / (1024.0 * 1024.0)];
    }
    if (bytesPerSec >= 1024.0) {
        return [NSString stringWithFormat:@"%.0f KB/s", bytesPerSec / 1024.0];
    }
    return [NSString stringWithFormat:@"%.0f B/s", bytesPerSec];
}

static NSString *wq_hud_ram_short(void)
{
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS && pageSize > 0) {
        unsigned long long used = ((unsigned long long)vm.active_count + (unsigned long long)vm.wire_count + (unsigned long long)vm.compressor_page_count) * (unsigned long long)pageSize;
        unsigned long long phys = NSProcessInfo.processInfo.physicalMemory;
        return [NSString stringWithFormat:@"%.1f/%.1fG", (double)used / 1073741824.0, (double)phys / 1073741824.0];
    }
    return @"--";
}

static NSString *wq_hud_thermal_short(void)
{
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return @"Cool";
        case NSProcessInfoThermalStateFair: return @"Warm";
        case NSProcessInfoThermalStateSerious: return @"Hot";
        case NSProcessInfoThermalStateCritical: return @"Crit";
    }
    return @"--";
}

static NSArray<NSString *> *wq_hud_build_lines(WQNetSpeedSnapshot net, WQBatteryPowerSnapshot pwr, BOOL compact)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    BOOL showDown = wq_hud_pref_bool(kWQHUDShowDown, YES);
    BOOL showUp = wq_hud_pref_bool(kWQHUDShowUp, YES);
    BOOL showWatts = wq_hud_pref_bool(kWQHUDShowWatts, YES);
    BOOL showCV = wq_hud_pref_bool(kWQHUDShowCurrentVolt, NO);
    BOOL showPct = wq_hud_pref_bool(kWQHUDShowBatteryPct, YES);
    BOOL showRAM = wq_hud_pref_bool(kWQHUDShowRAM, NO);
    BOOL showThermal = wq_hud_pref_bool(kWQHUDShowThermal, NO);

    if (showDown || showUp) {
        NSMutableArray<NSString *> *netSegs = [NSMutableArray new];
        if (showDown) [netSegs addObject:[NSString stringWithFormat:@"↓%@", wq_format_net_speed(net.downBytesPerSec)]];
        if (showUp) [netSegs addObject:[NSString stringWithFormat:@"↑%@", wq_format_net_speed(net.upBytesPerSec)]];
        [parts addObject:[netSegs componentsJoinedByString:@"  "]];
    }
    if (showWatts || showPct) {
        NSMutableArray<NSString *> *battSegs = [NSMutableArray new];
        if (showWatts) {
            NSString *prefix = pwr.watts >= 0 ? @"⚡+" : @"⚡";
            NSString *est = pwr.fromHardware ? @"" : @"~";
            [battSegs addObject:[NSString stringWithFormat:@"%@%@%.1fW", prefix, est, pwr.watts]];
        }
        if (showPct) {
            NSString *pct = pwr.batteryLevel >= 0 ? [NSString stringWithFormat:@"%.0f%%", pwr.batteryLevel * 100.0f] : @"--%";
            [battSegs addObject:pct];
        }
        [parts addObject:[battSegs componentsJoinedByString:@" · "]];
    }
    if (showCV) {
        NSString *est = pwr.fromHardware ? @"" : @"~";
        [parts addObject:[NSString stringWithFormat:@"%@%.0fmA · %.2fV", est, pwr.amperageMA, pwr.voltageMV / 1000.0]];
    }
    if (showRAM || showThermal) {
        NSMutableArray<NSString *> *sysSegs = [NSMutableArray new];
        if (showRAM) [sysSegs addObject:[NSString stringWithFormat:@"RAM %@", wq_hud_ram_short()]];
        if (showThermal) [sysSegs addObject:wq_hud_thermal_short()];
        [parts addObject:[sysSegs componentsJoinedByString:@" · "]];
    }
    if (!parts.count) {
        [parts addObject:@"WQ HUD"];
    }
    if (compact && parts.count > 2) {
        return @[parts[0], [parts[1] stringByAppendingFormat:@" · %@", parts[2]]];
    }
    return parts;
}

#pragma mark - CVPixelBuffer / CMSampleBuffer Frame Renderer for System-Wide PiP

static CMSampleBufferRef wq_hud_render_sample_buffer(NSArray<NSString *> *lines, BOOL expanded)
{
    CGSize size = expanded ? CGSizeMake(480, 220) : CGSizeMake(440, 140);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef px = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)size.width, (size_t)size.height,
                            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess || !px) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(px, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(px),
                                             (size_t)size.width,
                                             (size_t)size.height,
                                             8,
                                             CVPixelBufferGetBytesPerRow(px),
                                             cs,
                                             (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst));
    CGColorSpaceRelease(cs);
    if (ctx) {
        UIGraphicsPushContext(ctx);
        // Flip coordinate system to UIKit top-left origin.
        CGContextTranslateCTM(ctx, 0, size.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);

        // Dark frosted telemetry pill backdrop
        [[UIColor colorWithRed:0.055 green:0.085 blue:0.135 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));

        UIBezierPath *border = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 4, 4) cornerRadius:24];
        [[UIColor colorWithRed:0.10 green:0.17 blue:0.26 alpha:0.92] setFill];
        [border fill];
        [[wq_theme_accent() colorWithAlphaComponent:0.55] setStroke];
        border.lineWidth = 2.0;
        [border stroke];

        // Title eyebrow
        NSDictionary *eyeAttr = @{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: wq_theme_aurora_teal(),
        };
        [@"WQ GLASS LIVE" drawAtPoint:CGPointMake(20, 14) withAttributes:eyeAttr];

        CGFloat y = 42.0;
        CGFloat step = expanded ? 38.0 : 40.0;
        for (NSUInteger i = 0; i < lines.count && y + 24.0 < size.height; i++) {
            NSDictionary *lineAttr = @{
                NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:(i == 0 ? 28.0 : 23.0) weight:UIFontWeightBold],
                NSForegroundColorAttributeName: (i == 0) ? UIColor.whiteColor : [UIColor colorWithRed:0.78 green:0.92 blue:1.0 alpha:1.0],
            };
            [lines[i] drawInRect:CGRectMake(20, y, size.width - 40, 36) withAttributes:lineAttr];
            y += step;
        }
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(px, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(px);
        return NULL;
    }
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 1);
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, px, fmt, &timing, &sample);
    CFRelease(fmt);
    CVPixelBufferRelease(px);
    return sample;
}

#pragma mark - WQFloatingHUDManager

@interface WQFloatingHUDManager () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@end

@implementation WQFloatingHUDManager {
    NSTimer *_timer;
    UIVisualEffectView *_pill;
    UILabel *_pillLabel;
    UIButton *_closeBtn;
    BOOL _inAppRunning;
    BOOL _pipRunning;
    UIView *_pipHostView;
    AVSampleBufferDisplayLayer *_pipDisplayLayer;
    AVPictureInPictureController *_pipController;
}

+ (instancetype)sharedManager
{
    static WQFloatingHUDManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [WQFloatingHUDManager new]; });
    return inst;
}

- (BOOL)inAppHUDRunning { return _inAppRunning; }
- (BOOL)pipHUDRunning { return _pipRunning; }

- (UIWindow *)activeKeyWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.firstObject) return ws.windows.firstObject;
    }
    return nil;
}

- (void)ensureTimerRunning
{
    if (_timer) return;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    wq_sample_network_speed(); // prime baseline
    NSTimeInterval interval = wq_hud_interval();
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *__unused t) {
        [weakSelf tickTelemetry];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self tickTelemetry];
}

- (void)stopTimerIfIdle
{
    if (_inAppRunning || _pipRunning) return;
    [_timer invalidate];
    _timer = nil;
    UIDevice.currentDevice.batteryMonitoringEnabled = NO;
}

- (void)startInAppHUD
{
    UIWindow *win = [self activeKeyWindow];
    if (!win) return;
    if (!_pill) {
        _pill = wq_theme_make_glass_card(20.0, YES);
        _pill.translatesAutoresizingMaskIntoConstraints = YES;
        _pill.layer.zPosition = 2000;
        _pill.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.55].CGColor;
        _pill.layer.borderWidth = 1.0;

        _pillLabel = [UILabel new];
        _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _pillLabel.numberOfLines = 0;
        _pillLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _pillLabel.textColor = wq_theme_primary_text();

        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
        [_closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:sym] forState:UIControlStateNormal];
        _closeBtn.tintColor = wq_theme_secondary_text();
        [_closeBtn addTarget:self action:@selector(stopInAppHUD) forControlEvents:UIControlEventTouchUpInside];

        [_pill.contentView addSubview:_pillLabel];
        [_pill.contentView addSubview:_closeBtn];
        [NSLayoutConstraint activateConstraints:@[
            [_pillLabel.topAnchor constraintEqualToAnchor:_pill.contentView.topAnchor constant:8],
            [_pillLabel.bottomAnchor constraintEqualToAnchor:_pill.contentView.bottomAnchor constant:-8],
            [_pillLabel.leadingAnchor constraintEqualToAnchor:_pill.contentView.leadingAnchor constant:12],
            [_closeBtn.leadingAnchor constraintEqualToAnchor:_pillLabel.trailingAnchor constant:6],
            [_closeBtn.trailingAnchor constraintEqualToAnchor:_pill.contentView.trailingAnchor constant:-8],
            [_closeBtn.centerYAnchor constraintEqualToAnchor:_pill.contentView.centerYAnchor],
            [_closeBtn.widthAnchor constraintEqualToConstant:22],
            [_closeBtn.heightAnchor constraintEqualToConstant:22],
        ]];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillPan:)];
        [_pill addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillTap)];
        [_pill addGestureRecognizer:tap];
    }
    if (_pill.superview != win) {
        [_pill removeFromSuperview];
        [win addSubview:_pill];
        CGFloat topY = MAX(64.0, win.safeAreaInsets.top + 12.0);
        _pill.frame = CGRectMake(win.bounds.size.width - 210.0, topY, 198.0, 48.0);
    }
    _pill.hidden = NO;
    _inAppRunning = YES;
    [self restartTimerWithCurrentInterval];
    [self tickTelemetry];
}

- (void)stopInAppHUD
{
    _inAppRunning = NO;
    [_pill removeFromSuperview];
    _pill = nil;
    _pillLabel = nil;
    _closeBtn = nil;
    [self stopTimerIfIdle];
}

- (void)handlePillTap
{
    BOOL expanded = !wq_hud_pref_bool(kWQHUDExpanded, NO);
    [NSUserDefaults.standardUserDefaults setBool:expanded forKey:kWQHUDExpanded];
    wq_haptic_selection();
    [self tickTelemetry];
}

- (void)handlePillPan:(UIPanGestureRecognizer *)pan
{
    UIView *v = pan.view;
    UIView *sup = v.superview;
    if (!v || !sup) return;
    CGPoint delta = [pan translationInView:sup];
    [pan setTranslation:CGPointZero inView:sup];
    CGPoint center = CGPointMake(v.center.x + delta.x, v.center.y + delta.y);
    UIEdgeInsets safe = sup.safeAreaInsets;
    CGFloat minX = 12.0 + v.bounds.size.width * 0.5;
    CGFloat maxX = sup.bounds.size.width - 12.0 - v.bounds.size.width * 0.5;
    CGFloat minY = safe.top + 8.0 + v.bounds.size.height * 0.5;
    CGFloat maxY = sup.bounds.size.height - safe.bottom - 12.0 - v.bounds.size.height * 0.5;
    center.x = MAX(minX, MIN(maxX, center.x));
    center.y = MAX(minY, MIN(maxY, center.y));
    v.center = center;
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat snapX = (v.center.x < sup.bounds.size.width * 0.5) ? minX : maxX;
        [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:0 animations:^{
            v.center = CGPointMake(snapX, center.y);
        } completion:nil];
    }
}

- (void)startPiPHUDFromHost:(UIViewController *)host
{
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        wq_alert(host, WQLocalized(@"Picture-in-Picture Unavailable"),
                 WQLocalized(@"Picture-in-Picture is not supported on this device. Use the In-App Floating Bubble instead."));
        return;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:nil];
    [session setActive:YES error:nil];

    UIWindow *win = [self activeKeyWindow];
    if (!win) return;
    if (!_pipHostView) {
        _pipHostView = [[UIView alloc] initWithFrame:CGRectMake(-20, -20, 2, 2)];
        _pipHostView.alpha = 0.01;
        _pipHostView.userInteractionEnabled = NO;
        _pipDisplayLayer = [AVSampleBufferDisplayLayer layer];
        _pipDisplayLayer.frame = _pipHostView.bounds;
        _pipDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        [_pipHostView.layer addSublayer:_pipDisplayLayer];
        [win addSubview:_pipHostView];
    }
    if (!_pipController) {
        AVPictureInPictureControllerContentSource *src =
            [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:_pipDisplayLayer
                                                                                playbackDelegate:self];
        _pipController = [[AVPictureInPictureController alloc] initWithContentSource:src];
        _pipController.delegate = self;
        _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
    }
    _pipRunning = YES;
    [self restartTimerWithCurrentInterval];
    [self tickTelemetry];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pipRunning && !self->_pipController.isPictureInPictureActive) {
            [self->_pipController startPictureInPicture];
        }
    });
}

- (void)stopPiPHUD
{
    _pipRunning = NO;
    if (_pipController.isPictureInPictureActive) {
        [_pipController stopPictureInPicture];
    }
    _pipController = nil;
    [_pipDisplayLayer removeFromSuperlayer];
    _pipDisplayLayer = nil;
    [_pipHostView removeFromSuperview];
    _pipHostView = nil;
    [self stopTimerIfIdle];
}

- (void)stopAll
{
    [self stopInAppHUD];
    [self stopPiPHUD];
}

- (void)restartTimerWithCurrentInterval
{
    [_timer invalidate];
    _timer = nil;
    if (_inAppRunning || _pipRunning) {
        [self ensureTimerRunning];
    }
}

- (void)refreshAppearanceAndLayout
{
    if (_inAppRunning || _pipRunning) {
        [self restartTimerWithCurrentInterval];
        [self tickTelemetry];
    }
}

- (void)tickTelemetry
{
    WQNetSpeedSnapshot net = wq_sample_network_speed();
    WQBatteryPowerSnapshot pwr = wq_read_battery_power();
    BOOL expanded = wq_hud_pref_bool(kWQHUDExpanded, NO);
    NSArray<NSString *> *lines = wq_hud_build_lines(net, pwr, !expanded);

    if (_inAppRunning && _pill && _pillLabel) {
        _pillLabel.text = [lines componentsJoinedByString:@"\n"];
        _pillLabel.textColor = wq_theme_primary_text();
        _pill.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.55].CGColor;
        CGSize fit = [_pillLabel sizeThatFits:CGSizeMake(240, 140)];
        CGFloat targetW = MIN(260.0, MAX(148.0, ceil(fit.width) + 52.0));
        CGFloat targetH = MAX(42.0, ceil(fit.height) + 18.0);
        CGRect f = _pill.frame;
        CGFloat maxX = (_pill.superview.bounds.size.width ?: 390.0) - 12.0;
        if (f.origin.x + targetW > maxX) f.origin.x = MAX(12.0, maxX - targetW);
        f.size = CGSizeMake(targetW, targetH);
        _pill.frame = f;
    }

    if (_pipRunning && _pipDisplayLayer) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (_pipDisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [_pipDisplayLayer flush];
        }
        CMSampleBufferRef sb = wq_hud_render_sample_buffer(lines, expanded);
        if (sb) {
            [_pipDisplayLayer enqueueSampleBuffer:sb];
            CFRelease(sb);
        }
#pragma clang diagnostic pop
    }
}

#pragma mark AVPictureInPictureSampleBufferPlaybackDelegate & Delegate

- (void)pictureInPictureController:(AVPictureInPictureController *__unused)pictureInPictureController
                        setPlaying:(BOOL __unused)playing
{
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *__unused)pictureInPictureController
{
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *__unused)pictureInPictureController
{
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *__unused)pictureInPictureController
         didTransitionToRenderSize:(CMVideoDimensions __unused)newRenderSize
{
    [self tickTelemetry];
}

- (void)pictureInPictureController:(AVPictureInPictureController *__unused)pictureInPictureController
                    skipByInterval:(CMTime __unused)skipInterval
                 completionHandler:(void (^)(void))completionHandler
{
    if (completionHandler) completionHandler();
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *__unused)pictureInPictureController
{
    [self stopPiPHUD];
}

@end

#pragma mark - Pre-Launch Floating Bubble Customizer Screen

@implementation WQFloatingHUDConfigViewController {
    UILabel *_previewLabel;
    NSTimer *_previewTimer;
    NSArray<NSDictionary<NSString *, id> *> *_metricSpecs;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Floating Telemetry Bubble");
        self.hidesBottomBarWhenPushed = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    wq_theme_apply_scroll_insets(self.tableView, 40.0);

    _metricSpecs = @[
        @{ @"key": kWQHUDShowDown, @"default": @YES, @"title": WQLocalized(@"Live Download Speed (↓)"), @"sym": @"arrow.down.circle.fill" },
        @{ @"key": kWQHUDShowUp, @"default": @YES, @"title": WQLocalized(@"Live Upload Speed (↑)"), @"sym": @"arrow.up.circle.fill" },
        @{ @"key": kWQHUDShowWatts, @"default": @YES, @"title": WQLocalized(@"Battery Live Wattage (W)"), @"sym": @"bolt.fill" },
        @{ @"key": kWQHUDShowCurrentVolt, @"default": @NO, @"title": WQLocalized(@"Battery Current & Voltage (mA · V)"), @"sym": @"waveform.path.ecg" },
        @{ @"key": kWQHUDShowBatteryPct, @"default": @YES, @"title": WQLocalized(@"Battery Percentage (%)"), @"sym": @"battery.75" },
        @{ @"key": kWQHUDShowRAM, @"default": @NO, @"title": WQLocalized(@"Live RAM Usage"), @"sym": @"memorychip" },
        @{ @"key": kWQHUDShowThermal, @"default": @NO, @"title": WQLocalized(@"Thermal State"), @"sym": @"thermometer.medium" },
    ];
    [self installPreviewHeader];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    wq_sample_network_speed();
    [self refreshPreview];
    __weak typeof(self) weakSelf = self;
    _previewTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *__unused t) {
        [weakSelf refreshPreview];
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_previewTimer invalidate];
    _previewTimer = nil;
    WQFloatingHUDManager *mgr = WQFloatingHUDManager.sharedManager;
    if (!mgr.inAppHUDRunning && !mgr.pipHUDRunning) {
        UIDevice.currentDevice.batteryMonitoringEnabled = NO;
    }
}

- (void)dealloc
{
    [_previewTimer invalidate];
}

- (void)installPreviewHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 134)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *caption = [UILabel new];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = WQLocalized(@"LIVE BUBBLE PREVIEW");
    caption.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightBold];
    caption.textColor = wq_theme_secondary_text();
    caption.textAlignment = NSTextAlignmentCenter;

    UIVisualEffectView *pill = wq_theme_make_glass_card(20.0, YES);
    pill.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.55].CGColor;
    pill.layer.borderWidth = 1.0;

    _previewLabel = [UILabel new];
    _previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _previewLabel.numberOfLines = 0;
    _previewLabel.textAlignment = NSTextAlignmentCenter;
    _previewLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    _previewLabel.textColor = wq_theme_primary_text();
    [pill.contentView addSubview:_previewLabel];

    [box addSubview:caption];
    [box addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [caption.topAnchor constraintEqualToAnchor:box.topAnchor constant:10],
        [caption.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:8],
        [pill.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [pill.widthAnchor constraintGreaterThanOrEqualToConstant:210],
        [pill.widthAnchor constraintLessThanOrEqualToConstant:320],
        [pill.bottomAnchor constraintLessThanOrEqualToAnchor:box.bottomAnchor constant:-8],
        [_previewLabel.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:12],
        [_previewLabel.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-12],
        [_previewLabel.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:16],
        [_previewLabel.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-16],
    ]];
    self.tableView.tableHeaderView = box;
}

- (void)refreshPreview
{
    WQNetSpeedSnapshot net = wq_sample_network_speed();
    WQBatteryPowerSnapshot pwr = wq_read_battery_power();
    BOOL expanded = wq_hud_pref_bool(kWQHUDExpanded, NO);
    NSArray<NSString *> *lines = wq_hud_build_lines(net, pwr, !expanded);
    _previewLabel.text = [lines componentsJoinedByString:@"\n"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 3; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return (NSInteger)_metricSpecs.count;
    if (section == 1) return 2;
    return 2;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Choose Metrics to Show in Bubble");
    if (section == 1) return WQLocalized(@"Style & Update Rate");
    return WQLocalized(@"Launch Floating Bubble");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 2) {
        return WQLocalized(@"In-App Bubble floats inside WQ Glass and snaps to screen edges. System-Wide PiP Bubble uses Picture-in-Picture so live internet speed & battery wattage stay visible even over other apps. Timers stop immediately when turned off.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"hud-cfg"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hud-cfg"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];

    if (indexPath.section == 0) {
        NSDictionary *spec = _metricSpecs[(NSUInteger)indexPath.row];
        NSString *key = spec[@"key"];
        BOOL def = [spec[@"default"] boolValue];
        c.text = spec[@"title"];
        c.image = [UIImage systemImageNamed:spec[@"sym"]];
        c.imageProperties.tintColor = wq_theme_accent();
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = wq_theme_accent();
        sw.on = wq_hud_pref_bool(key, def);
        __weak typeof(self) weakSelf = self;
        [sw addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).isOn;
            [NSUserDefaults.standardUserDefaults setBool:on forKey:key];
            wq_haptic_selection();
            [weakSelf refreshPreview];
            [WQFloatingHUDManager.sharedManager refreshAppearanceAndLayout];
        }] forControlEvents:UIControlEventValueChanged];
        cell.contentConfiguration = c;
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            BOOL expanded = wq_hud_pref_bool(kWQHUDExpanded, NO);
            c.text = WQLocalized(@"Bubble Layout");
            c.secondaryText = expanded ? WQLocalized(@"Expanded HUD (All selected lines)") : WQLocalized(@"Compact Pill (2 lines max)");
            c.image = [UIImage systemImageNamed:@"rectangle.compress.vertical"];
        } else {
            NSTimeInterval iv = wq_hud_interval();
            c.text = WQLocalized(@"Refresh Rate");
            c.secondaryText = (iv >= 1.5) ? WQLocalized(@"Every 2 seconds (Ultra-Low Battery)") : WQLocalized(@"Every 1 second (Live)");
            c.image = [UIImage systemImageNamed:@"timer"];
        }
        c.imageProperties.tintColor = wq_theme_accent();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    WQFloatingHUDManager *mgr = WQFloatingHUDManager.sharedManager;
    if (indexPath.row == 0) {
        BOOL on = mgr.inAppHUDRunning;
        c.text = on ? WQLocalized(@"Stop In-App Floating Bubble") : WQLocalized(@"Start In-App Floating Bubble");
        c.secondaryText = WQLocalized(@"Draggable Liquid Glass pill inside WQ Glass");
        c.image = [UIImage systemImageNamed:on ? @"stop.circle.fill" : @"play.circle.fill"];
        c.textProperties.color = on ? UIColor.systemRedColor : wq_theme_accent();
        c.imageProperties.tintColor = on ? UIColor.systemRedColor : wq_theme_accent();
    } else {
        BOOL on = mgr.pipHUDRunning;
        c.text = on ? WQLocalized(@"Stop System-Wide PiP Bubble") : WQLocalized(@"Start System-Wide PiP Bubble");
        c.secondaryText = WQLocalized(@"Floats over other apps & Home Screen (CPU-x style)");
        c.image = [UIImage systemImageNamed:on ? @"pip.exit" : @"pip.enter"];
        c.textProperties.color = on ? UIColor.systemRedColor : wq_theme_aurora_teal();
        c.imageProperties.tintColor = on ? UIColor.systemRedColor : wq_theme_aurora_teal();
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        wq_haptic_selection();
        if (indexPath.row == 0) {
            BOOL next = !wq_hud_pref_bool(kWQHUDExpanded, NO);
            [NSUserDefaults.standardUserDefaults setBool:next forKey:kWQHUDExpanded];
        } else {
            double next = (wq_hud_interval() >= 1.5) ? 1.0 : 2.0;
            [NSUserDefaults.standardUserDefaults setDouble:next forKey:kWQHUDInterval];
        }
        [self refreshPreview];
        [WQFloatingHUDManager.sharedManager refreshAppearanceAndLayout];
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    if (indexPath.section == 2) {
        WQFloatingHUDManager *mgr = WQFloatingHUDManager.sharedManager;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        if (indexPath.row == 0) {
            if (mgr.inAppHUDRunning) [mgr stopInAppHUD];
            else [mgr startInAppHUD];
        } else {
            if (mgr.pipHUDRunning) [mgr stopPiPHUD];
            else [mgr startPiPHUDFromHost:self];
        }
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end
