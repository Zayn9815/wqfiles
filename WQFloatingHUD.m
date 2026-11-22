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
static NSString *const kWQHUDShowDataTotals = @"WQHUDShowDataTotals";
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

#pragma mark - Real-Time BSD Network Speed & Session Data Counter

static uint64_t gWQPrevRx = 0;
static uint64_t gWQPrevTx = 0;
static CFAbsoluteTime gWQPrevNetTime = 0;
static uint64_t gWQSessionRxBytes = 0;
static uint64_t gWQSessionTxBytes = 0;

static void wq_hud_reset_session_data(void)
{
    @synchronized (NSNull.null) {
        gWQSessionRxBytes = 0;
        gWQSessionTxBytes = 0;
    }
}

static void wq_hud_get_session_data(uint64_t *rxOut, uint64_t *txOut)
{
    @synchronized (NSNull.null) {
        if (rxOut) *rxOut = gWQSessionRxBytes;
        if (txOut) *txOut = gWQSessionTxBytes;
    }
}

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
            if (snap.totalRxBytes >= gWQPrevRx) {
                uint64_t dRx = snap.totalRxBytes - gWQPrevRx;
                snap.downBytesPerSec = (double)dRx / dt;
                gWQSessionRxBytes += dRx;
            }
            if (snap.totalTxBytes >= gWQPrevTx) {
                uint64_t dTx = snap.totalTxBytes - gWQPrevTx;
                snap.upBytesPerSec = (double)dTx / dt;
                gWQSessionTxBytes += dTx;
            }
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

static NSString *wq_format_data_bytes(uint64_t bytes)
{
    if (bytes >= 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.2f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL) {
        return [NSString stringWithFormat:@"%.0f KB", (double)bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%llu B", (unsigned long long)bytes];
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
    BOOL showTotals = wq_hud_pref_bool(kWQHUDShowDataTotals, YES);
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
    if (showTotals) {
        uint64_t rxTotal = 0, txTotal = 0;
        wq_hud_get_session_data(&rxTotal, &txTotal);
        NSMutableArray<NSString *> *totSegs = [NSMutableArray new];
        BOOL bothOff = (!showDown && !showUp);
        if (showDown || bothOff) [totSegs addObject:[NSString stringWithFormat:@"DL %@", wq_format_data_bytes(rxTotal)]];
        if (showUp || bothOff) [totSegs addObject:[NSString stringWithFormat:@"UL %@", wq_format_data_bytes(txTotal)]];
        [parts addObject:[totSegs componentsJoinedByString:@"  "]];
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
    if (compact && parts.count > 3) {
        return @[parts[0], parts[1], [parts[2] stringByAppendingFormat:@" · %@", parts[3]]];
    }
    return parts;
}

static UIColor *wq_hud_line_color(NSString *line, BOOL forPiPDark, BOOL charging)
{
    if ([line hasPrefix:@"DL "] || [line hasPrefix:@"UL "]) {
        return forPiPDark
            ? [UIColor colorWithRed:0.42 green:0.93 blue:1.0 alpha:1.0]
            : wq_theme_aurora_teal();
    }
    if ([line hasPrefix:@"⚡"]) {
        if (charging) {
            return forPiPDark
                ? [UIColor colorWithRed:0.36 green:0.98 blue:0.64 alpha:1.0]
                : UIColor.systemGreenColor;
        }
        return forPiPDark
            ? [UIColor colorWithRed:1.0 green:0.83 blue:0.38 alpha:1.0]
            : UIColor.systemOrangeColor;
    }
    if ([line hasPrefix:@"↓"] || [line hasPrefix:@"↑"]) {
        return forPiPDark ? UIColor.whiteColor : wq_theme_primary_text();
    }
    return forPiPDark
        ? [UIColor colorWithRed:0.84 green:0.92 blue:1.0 alpha:0.95]
        : wq_theme_secondary_text();
}

static NSAttributedString *wq_hud_attributed_lines(NSArray<NSString *> *lines, CGFloat baseFontSize, BOOL charging)
{
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = NSTextAlignmentCenter;
    para.lineSpacing = 3.0;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *text = (i + 1 < lines.count) ? [lines[i] stringByAppendingString:@"\n"] : lines[i];
        CGFloat pt = (i == 0) ? baseFontSize : MAX(11.0, baseFontSize - 1.0);
        UIFont *font = [UIFont monospacedDigitSystemFontOfSize:pt weight:(i == 0 ? UIFontWeightHeavy : UIFontWeightBold)];
        UIColor *color = wq_hud_line_color(lines[i], NO, charging);
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: para,
        }]];
    }
    return out;
}

#pragma mark - CVPixelBuffer / CMSampleBuffer Frame Renderer for System-Wide PiP

static CMSampleBufferRef wq_hud_render_sample_buffer(NSArray<NSString *> *lines, BOOL charging)
{
    NSUInteger count = MAX((NSUInteger)1, lines.count);
    CGFloat frameH = (count == 1) ? 180.0
                   : (count == 2) ? 236.0
                   : (count == 3) ? 296.0
                   : 360.0;
    CGSize size = CGSizeMake(640.0, frameH);
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

        // Dark frosted telemetry HUD backdrop filling the entire PiP frame
        [[UIColor colorWithRed:0.045 green:0.075 blue:0.125 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));

        UIBezierPath *border = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 6, 6) cornerRadius:28];
        [[UIColor colorWithRed:0.095 green:0.160 blue:0.255 alpha:0.96] setFill];
        [border fill];
        [[wq_theme_accent() colorWithAlphaComponent:0.65] setStroke];
        border.lineWidth = 3.0;
        [border stroke];

        // Auto-fit font size so text fills ~92% width & ~82% height, centered cleanly.
        CGFloat padX = 24.0;
        CGFloat padY = 20.0;
        CGFloat availW = size.width - padX * 2.0;
        CGFloat availH = size.height - padY * 2.0;
        CGFloat lineGap = (count <= 2) ? 14.0 : 10.0;

        CGFloat probeBase = 72.0;
        CGFloat maxW = 1.0;
        CGFloat totalH = 0.0;
        for (NSUInteger i = 0; i < lines.count; i++) {
            CGFloat sz = (i == 0) ? probeBase : (probeBase * 0.88);
            UIFont *f = [UIFont monospacedDigitSystemFontOfSize:sz weight:(i == 0 ? UIFontWeightHeavy : UIFontWeightBold)];
            CGSize m = [lines[i] sizeWithAttributes:@{ NSFontAttributeName: f }];
            if (m.width > maxW) maxW = m.width;
            totalH += m.height;
        }
        if (lines.count > 1) totalH += lineGap * (CGFloat)(lines.count - 1);

        CGFloat scaleW = availW / MAX(maxW, 1.0);
        CGFloat scaleH = availH / MAX(totalH, 1.0);
        CGFloat finalBase = floor(MAX(26.0, MIN(96.0, probeBase * MIN(scaleW, scaleH) * 0.96)));

        // Re-measure exact vertical stack height at finalBase for perfect centering.
        NSMutableArray<UIFont *> *fonts = [NSMutableArray arrayWithCapacity:lines.count];
        NSMutableArray<NSNumber *> *heights = [NSMutableArray arrayWithCapacity:lines.count];
        CGFloat finalTotalH = 0.0;
        for (NSUInteger i = 0; i < lines.count; i++) {
            CGFloat sz = (i == 0) ? finalBase : MAX(22.0, floor(finalBase * 0.88));
            UIFont *f = [UIFont monospacedDigitSystemFontOfSize:sz weight:(i == 0 ? UIFontWeightHeavy : UIFontWeightBold)];
            CGSize m = [lines[i] sizeWithAttributes:@{ NSFontAttributeName: f }];
            [fonts addObject:f];
            [heights addObject:@(ceil(m.height))];
            finalTotalH += ceil(m.height);
        }
        if (lines.count > 1) finalTotalH += lineGap * (CGFloat)(lines.count - 1);

        NSMutableParagraphStyle *centerPara = [NSMutableParagraphStyle new];
        centerPara.alignment = NSTextAlignmentCenter;
        centerPara.lineBreakMode = NSLineBreakByTruncatingTail;

        CGFloat y = floor((size.height - finalTotalH) * 0.5);
        for (NSUInteger i = 0; i < lines.count; i++) {
            CGFloat lh = (CGFloat)[heights[i] doubleValue];
            NSDictionary *lineAttr = @{
                NSFontAttributeName: fonts[i],
                NSForegroundColorAttributeName: wq_hud_line_color(lines[i], YES, charging),
                NSParagraphStyleAttributeName: centerPara,
            };
            [lines[i] drawInRect:CGRectMake(padX, y, availW, lh + 4.0) withAttributes:lineAttr];
            y += lh + lineGap;
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
        _pillLabel.textAlignment = NSTextAlignmentCenter;
        _pillLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.5 weight:UIFontWeightBold];
        _pillLabel.textColor = wq_theme_primary_text();

        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
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
        _pill.frame = CGRectMake(win.bounds.size.width - 220.0, topY, 208.0, 56.0);
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
    BOOL charging = (pwr.watts >= 0.0 || pwr.batteryState == UIDeviceBatteryStateCharging);
    NSArray<NSString *> *lines = wq_hud_build_lines(net, pwr, !expanded);

    if (_inAppRunning && _pill && _pillLabel) {
        _pillLabel.attributedText = wq_hud_attributed_lines(lines, expanded ? 14.0 : 13.5, charging);
        _pill.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.55].CGColor;
        CGSize fit = [_pillLabel sizeThatFits:CGSizeMake(270.0, 220.0)];
        CGFloat targetW = MIN(310.0, MAX(142.0, ceil(fit.width) + 48.0));
        CGFloat targetH = MAX(44.0, ceil(fit.height) + 16.0);
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
        CMSampleBufferRef sb = wq_hud_render_sample_buffer(lines, charging);
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
        @{ @"key": kWQHUDShowDataTotals, @"default": @YES, @"title": WQLocalized(@"Downloaded & Uploaded Data (DL / UL)"), @"sym": @"arrow.up.arrow.down.circle.fill" },
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
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 158)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *caption = [UILabel new];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = WQLocalized(@"LIVE BUBBLE PREVIEW");
    caption.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightBold];
    caption.textColor = wq_theme_secondary_text();
    caption.textAlignment = NSTextAlignmentCenter;

    UIVisualEffectView *pill = wq_theme_make_glass_card(22.0, YES);
    pill.layer.borderColor = [wq_theme_accent() colorWithAlphaComponent:0.55].CGColor;
    pill.layer.borderWidth = 1.0;

    _previewLabel = [UILabel new];
    _previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _previewLabel.numberOfLines = 0;
    _previewLabel.textAlignment = NSTextAlignmentCenter;
    _previewLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.5 weight:UIFontWeightBold];
    _previewLabel.textColor = wq_theme_primary_text();
    [pill.contentView addSubview:_previewLabel];

    [box addSubview:caption];
    [box addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [caption.topAnchor constraintEqualToAnchor:box.topAnchor constant:10],
        [caption.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:8],
        [pill.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [pill.widthAnchor constraintGreaterThanOrEqualToConstant:230],
        [pill.widthAnchor constraintLessThanOrEqualToConstant:340],
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
    BOOL charging = (pwr.watts >= 0.0 || pwr.batteryState == UIDeviceBatteryStateCharging);
    NSArray<NSString *> *lines = wq_hud_build_lines(net, pwr, !expanded);
    _previewLabel.attributedText = wq_hud_attributed_lines(lines, 14.5, charging);
    if (self.tableView.window && [self.tableView numberOfSections] > 1 && [self.tableView numberOfRowsInSection:1] > 2) {
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:2 inSection:1]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 3; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return (NSInteger)_metricSpecs.count;
    if (section == 1) return 3;
    return 2;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Choose Metrics to Show in Bubble");
    if (section == 1) return WQLocalized(@"Style, Update Rate & Data Counter");
    return WQLocalized(@"Launch Floating Bubble");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 2) {
        return WQLocalized(@"In-App Bubble floats inside WQ Glass and snaps to screen edges. System-Wide PiP Bubble uses Picture-in-Picture with auto-scaled full-HUD text so live internet speed, downloaded/uploaded data totals, and battery wattage stay crisp over other apps. Timers stop immediately when turned off.");
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
            c.secondaryText = expanded ? WQLocalized(@"Expanded HUD (All selected lines)") : WQLocalized(@"Compact Pill (3 lines max)");
            c.image = [UIImage systemImageNamed:@"rectangle.compress.vertical"];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            NSTimeInterval iv = wq_hud_interval();
            c.text = WQLocalized(@"Refresh Rate");
            c.secondaryText = (iv >= 1.5) ? WQLocalized(@"Every 2 seconds (Ultra-Low Battery)") : WQLocalized(@"Every 1 second (Live)");
            c.image = [UIImage systemImageNamed:@"timer"];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            uint64_t rxTotal = 0, txTotal = 0;
            wq_hud_get_session_data(&rxTotal, &txTotal);
            c.text = WQLocalized(@"Reset Data Counter");
            c.secondaryText = [NSString stringWithFormat:@"DL %@ · UL %@", wq_format_data_bytes(rxTotal), wq_format_data_bytes(txTotal)];
            c.image = [UIImage systemImageNamed:@"arrow.counterclockwise.circle.fill"];
            c.imageProperties.tintColor = wq_theme_aurora_teal();
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        cell.contentConfiguration = c;
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
        } else if (indexPath.row == 1) {
            double next = (wq_hud_interval() >= 1.5) ? 1.0 : 2.0;
            [NSUserDefaults.standardUserDefaults setDouble:next forKey:kWQHUDInterval];
        } else {
            wq_hud_reset_session_data();
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
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
