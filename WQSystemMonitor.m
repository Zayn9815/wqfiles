//
//  WQSystemMonitor.m
//  WQ Glass Device & Network Telemetry Monitor (On-Demand, Zero Idle Drain)
//  GPL-3.0-or-later.
//

#import "WQSystemMonitor.h"
#import "WQCore.h"
#import "WQFloatingHUD.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <mach/mach.h>
#import <math.h>
#import <net/if.h>
#import <netdb.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

typedef struct {
    unsigned long long totalBytes;
    unsigned long long activeBytes;
    unsigned long long wiredBytes;
    unsigned long long compressedBytes;
    unsigned long long freeBytes;
    BOOL valid;
} WQRAMSnapshot;

static WQRAMSnapshot wq_read_ram_snapshot(void)
{
    WQRAMSnapshot snap = {0};
    snap.totalBytes = NSProcessInfo.processInfo.physicalMemory;
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &count) == KERN_SUCCESS && pageSize > 0) {
        snap.activeBytes = (unsigned long long)vmStats.active_count * (unsigned long long)pageSize;
        snap.wiredBytes = (unsigned long long)vmStats.wire_count * (unsigned long long)pageSize;
        snap.compressedBytes = (unsigned long long)vmStats.compressor_page_count * (unsigned long long)pageSize;
        snap.freeBytes = ((unsigned long long)vmStats.free_count + (unsigned long long)vmStats.inactive_count) * (unsigned long long)pageSize;
        snap.valid = YES;
    }
    return snap;
}

static NSArray<NSArray<NSString *> *> *wq_network_interfaces(void)
{
    NSMutableArray<NSArray<NSString *> *> *out = [NSMutableArray new];
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0 || !ifaddr) return out;
    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        int fam = ifa->ifa_addr->sa_family;
        if (fam != AF_INET && fam != AF_INET6) continue;
        char host[NI_MAXHOST];
        memset(host, 0, sizeof(host));
        socklen_t salen = fam == AF_INET ? (socklen_t)sizeof(struct sockaddr_in) : (socklen_t)sizeof(struct sockaddr_in6);
        if (getnameinfo(ifa->ifa_addr, salen, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) continue;
        NSString *name = @(ifa->ifa_name ?: "?");
        NSString *addr = @(host);
        if ([addr hasPrefix:@"fe80::"]) continue;   // skip noisy link-local IPv6
        NSString *kind = [name hasPrefix:@"en"] ? @"Wi-Fi"
                       : [name hasPrefix:@"pdp_ip"] ? @"Cellular"
                       : [name hasPrefix:@"utun"] ? @"VPN / Tunnel"
                       : name;
        NSString *label = [NSString stringWithFormat:@"%@ (%@ · %@)", kind, name, fam == AF_INET ? @"IPv4" : @"IPv6"];
        [out addObject:@[label, addr]];
    }
    freeifaddrs(ifaddr);
    return out;
}

static NSString *wq_format_uptime(NSTimeInterval seconds)
{
    long total = (long)MAX(0, seconds);
    long days = total / 86400;
    long hours = (total % 86400) / 3600;
    long mins = (total % 3600) / 60;
    if (days > 0) return [NSString stringWithFormat:@"%ldd %ldh %ldm", days, hours, mins];
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %ldm", hours, mins];
    return [NSString stringWithFormat:@"%ldm", mins];
}

// Non-blocking TCP connect latency check (port 443, 2.5s timeout) + DNS lookup.
static NSString *wq_tcp_ping_host(NSString *host, NSString **resolvedOut)
{
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    int gai = getaddrinfo(host.UTF8String, "443", &hints, &res);
    if (gai != 0 || !res) {
        return WQLocalizedFormat(@"DNS failed (%s)", gai_strerror(gai));
    }
    char ipBuf[INET6_ADDRSTRLEN] = {0};
    if (res->ai_family == AF_INET) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, ipBuf, sizeof(ipBuf));
    } else if (res->ai_family == AF_INET6) {
        inet_ntop(AF_INET6, &((struct sockaddr_in6 *)res->ai_addr)->sin6_addr, ipBuf, sizeof(ipBuf));
    }
    if (resolvedOut && ipBuf[0]) *resolvedOut = @(ipBuf);

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return WQLocalized(@"Socket error");
    }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    CFAbsoluteTime tConn = CFAbsoluteTimeGetCurrent();
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    BOOL ok = (rc == 0);
    if (!ok && errno == EINPROGRESS) {
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int pr = poll(&pfd, 1, 2500);
        if (pr > 0) {
            int soErr = 0;
            socklen_t len = sizeof(soErr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0) ok = YES;
        }
    }
    double ms = (CFAbsoluteTimeGetCurrent() - tConn) * 1000.0;
    double dnsMs = (tConn - t0) * 1000.0;
    close(fd);
    freeaddrinfo(res);
    if (!ok) return WQLocalized(@"Timed out / unreachable");
    return [NSString stringWithFormat:@"%.1f ms (DNS %.0f ms)", ms, dnsMs];
}

@implementation WQSystemMonitorViewController {
    NSTimer *_timer;
    WQRAMSnapshot _ram;
    NSArray<NSArray<NSString *> *> *_hardwareRows;
    NSArray<NSArray<NSString *> *> *_networkRows;
    NSString *_pingTarget;
    NSString *_pingResult;
    NSString *_pingResolved;
    BOOL _pingBusy;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"System Monitor");
        _pingTarget = @"1.1.1.1";
        _pingResult = WQLocalized(@"Tap a target below to test");
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshTelemetry)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeDidChange)
                                               name:WQThemeDidChangeNotification object:nil];
    [self refreshTelemetry];
}

- (void)dealloc
{
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    wq_sample_network_speed();
    [self refreshTelemetry];
    [_timer invalidate];
    // Refresh only while on-screen (2.0s interval, zero background drain).
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *__unused t) {
        [weakSelf refreshTelemetry];
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
    WQFloatingHUDManager *mgr = WQFloatingHUDManager.sharedManager;
    if (!mgr.inAppHUDRunning && !mgr.pipHUDRunning) {
        UIDevice.currentDevice.batteryMonitoringEnabled = NO;
    }
}

- (void)themeDidChange
{
    [self.tableView reloadData];
}

- (void)openFloatingHUDConfig
{
    wq_haptic_selection();
    [self.navigationController pushViewController:[WQFloatingHUDConfigViewController new] animated:YES];
}

- (void)refreshTelemetry
{
    _ram = wq_read_ram_snapshot();
    WQBatteryPowerSnapshot pwr = wq_read_battery_power();
    WQNetSpeedSnapshot net = wq_sample_network_speed();
    UIDevice *dev = UIDevice.currentDevice;
    NSProcessInfo *pi = NSProcessInfo.processInfo;

    float batt = dev.batteryLevel;
    NSString *battState = dev.batteryState == UIDeviceBatteryStateCharging ? WQLocalized(@"Charging")
                        : dev.batteryState == UIDeviceBatteryStateFull ? WQLocalized(@"Full")
                        : dev.batteryState == UIDeviceBatteryStateUnplugged ? WQLocalized(@"Unplugged")
                        : WQLocalized(@"Unknown");
    NSString *battText = batt >= 0 ? [NSString stringWithFormat:@"%.0f%% · %@", batt * 100.0f, battState] : battState;

    NSString *powerText = WQLocalized(@"Unavailable");
    NSString *cvText = WQLocalized(@"Unavailable");
    if (pwr.valid) {
        NSString *sign = pwr.watts >= 0 ? @"+" : @"";
        NSString *srcTag = pwr.fromHardware ? WQLocalized(@"Live Sensor") : WQLocalized(@"Est.");
        powerText = [NSString stringWithFormat:@"%@%.2f W (%@)", sign, pwr.watts, srcTag];
        cvText = [NSString stringWithFormat:@"%.0f mA · %.2f V", pwr.amperageMA, pwr.voltageMV / 1000.0];
    }

    NSProcessInfoThermalState th = pi.thermalState;
    NSString *thermalText = th == NSProcessInfoThermalStateNominal ? WQLocalized(@"Nominal (Cool)")
                          : th == NSProcessInfoThermalStateFair ? WQLocalized(@"Fair (Warm)")
                          : th == NSProcessInfoThermalStateSerious ? WQLocalized(@"Serious (Hot)")
                          : WQLocalized(@"Critical (Throttling)");

    NSURL *homeURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSDictionary *vol = [homeURL resourceValuesForKeys:@[
        NSURLVolumeTotalCapacityKey,
        NSURLVolumeAvailableCapacityForImportantUsageKey,
        NSURLVolumeAvailableCapacityKey,
    ] error:nil];
    unsigned long long diskTotal = [vol[NSURLVolumeTotalCapacityKey] unsignedLongLongValue];
    NSNumber *imp = vol[NSURLVolumeAvailableCapacityForImportantUsageKey];
    unsigned long long diskAvail = imp ? imp.unsignedLongLongValue : [vol[NSURLVolumeAvailableCapacityKey] unsignedLongLongValue];
    NSString *diskText = diskTotal > 0
        ? WQLocalizedFormat(@"%@ free of %@", wq_size_text(diskAvail), wq_size_text(diskTotal))
        : WQLocalized(@"Unavailable");

    NSMutableArray<NSArray<NSString *> *> *hw = [NSMutableArray arrayWithArray:@[
        @[WQLocalized(@"Battery Level"), battText],
        @[WQLocalized(@"Live Power (Wattage)"), powerText],
        @[WQLocalized(@"Current & Voltage"), cvText],
    ]];
    if (pwr.adapterWatts > 0) {
        [hw addObject:@[WQLocalized(@"Charger Rating"), [NSString stringWithFormat:@"%.1f W (%.1f V)", pwr.adapterWatts, pwr.adapterVoltageMV / 1000.0]]];
    }
    if (isfinite(pwr.temperatureC)) {
        [hw addObject:@[WQLocalized(@"Battery Temp"), [NSString stringWithFormat:@"%.1f °C", pwr.temperatureC]]];
    }
    if (pwr.cycleCount >= 0) {
        [hw addObject:@[WQLocalized(@"Cycle Count"), [NSString stringWithFormat:@"%ld cycles", (long)pwr.cycleCount]]];
    }
    [hw addObjectsFromArray:@[
        @[WQLocalized(@"Live Net Speed"), [NSString stringWithFormat:@"↓ %@ · ↑ %@", wq_format_net_speed(net.downBytesPerSec), wq_format_net_speed(net.upBytesPerSec)]],
        @[WQLocalized(@"Thermal State"), thermalText],
        @[WQLocalized(@"Low Power Mode"), pi.isLowPowerModeEnabled ? WQLocalized(@"On (Eco Active)") : WQLocalized(@"Off")],
        @[WQLocalized(@"CPU Cores"), [NSString stringWithFormat:@"%lu active (%lu total)", (unsigned long)pi.activeProcessorCount, (unsigned long)pi.processorCount]],
        @[WQLocalized(@"Device Uptime"), wq_format_uptime(pi.systemUptime)],
        @[WQLocalized(@"Storage"), diskText],
    ]];
    _hardwareRows = hw;
    _networkRows = wq_network_interfaces();
    [self.tableView reloadData];
}

- (void)runPingForHost:(NSString *)host
{
    if (_pingBusy || !host.length) return;
    _pingBusy = YES;
    _pingTarget = [host copy];
    _pingResult = WQLocalized(@"Testing latency…");
    _pingResolved = nil;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationNone];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *resolved = nil;
        NSString *res = wq_tcp_ping_host(host, &resolved);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQSystemMonitorViewController *me = weakSelf;
            if (!me) return;
            me->_pingBusy = NO;
            me->_pingResult = res;
            me->_pingResolved = resolved;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            [me.tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (void)promptCustomPing
{
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"Ping & DNS Lookup"),
        WQLocalized(@"Enter a hostname or IP address to test TCP port 443 latency and DNS resolution."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"apple.com";
        tf.text = self->_pingTarget;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:wq_alert_action(WQLocalized(@"Test"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *host = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (host.length) [self runPingForHost:host];
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

// 0: Floating Telemetry Bubble, 1: Memory (RAM), 2: Hardware & Battery Power, 3: Network Interfaces, 4: Latency & DNS Tester
- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 5; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return _ram.valid ? 5 : 1;
    if (section == 2) return (NSInteger)_hardwareRows.count;
    if (section == 3) return MAX(1, (NSInteger)_networkRows.count);
    return 5;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Live Floating HUD Bubble");
    if (section == 1) return WQLocalized(@"Memory (RAM)");
    if (section == 2) return WQLocalized(@"Battery Power, Wattage & Hardware");
    if (section == 3) return WQLocalized(@"Network Interfaces");
    return WQLocalized(@"TCP Latency & DNS");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sysmon"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"sysmon"];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    c.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0) {
        c = [UIListContentConfiguration subtitleCellConfiguration];
        WQFloatingHUDManager *mgr = WQFloatingHUDManager.sharedManager;
        BOOL running = mgr.inAppHUDRunning || mgr.pipHUDRunning;
        c.text = WQLocalized(@"Customize & Launch Floating Bubble…");
        c.secondaryText = running
            ? WQLocalized(@"Active · Tap to customize metrics or stop")
            : WQLocalized(@"Show live Internet Speed + Battery Wattage in-app or over other apps (PiP)");
        c.secondaryTextProperties.numberOfLines = 2;
        c.image = [UIImage systemImageNamed:@"pip.enter"];
        c.imageProperties.tintColor = running ? UIColor.systemGreenColor : wq_theme_accent();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        if (!_ram.valid) {
            c.text = WQLocalized(@"Total RAM");
            c.secondaryText = wq_size_text(_ram.totalBytes);
        } else {
            NSArray<NSArray<NSString *> *> *rows = @[
                @[WQLocalized(@"Physical RAM"), wq_size_text(_ram.totalBytes)],
                @[WQLocalized(@"Active"), wq_size_text(_ram.activeBytes)],
                @[WQLocalized(@"Wired"), wq_size_text(_ram.wiredBytes)],
                @[WQLocalized(@"Compressed"), wq_size_text(_ram.compressedBytes)],
                @[WQLocalized(@"Available / Free"), wq_size_text(_ram.freeBytes)],
            ];
            c.text = rows[(NSUInteger)indexPath.row][0];
            c.secondaryText = rows[(NSUInteger)indexPath.row][1];
            if (indexPath.row == 4) c.secondaryTextProperties.color = wq_theme_aurora_teal();
        }
    } else if (indexPath.section == 2) {
        c.text = _hardwareRows[(NSUInteger)indexPath.row][0];
        c.secondaryText = _hardwareRows[(NSUInteger)indexPath.row][1];
        if (indexPath.row == 1) c.secondaryTextProperties.color = wq_theme_aurora_teal();
    } else if (indexPath.section == 3) {
        if (!_networkRows.count) {
            c.text = WQLocalized(@"No active network interfaces");
            c.textProperties.color = wq_theme_secondary_text();
        } else {
            c.text = _networkRows[(NSUInteger)indexPath.row][0];
            c.secondaryText = _networkRows[(NSUInteger)indexPath.row][1];
            c.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
        }
    } else {
        if (indexPath.row == 0) {
            c = [UIListContentConfiguration subtitleCellConfiguration];
            c.text = _pingTarget ?: @"1.1.1.1";
            c.textProperties.color = wq_theme_primary_text();
            c.secondaryText = _pingResolved.length
                ? [NSString stringWithFormat:@"%@ · %@", _pingResult, _pingResolved]
                : _pingResult;
            c.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
            c.secondaryTextProperties.color = wq_theme_aurora_teal();
            c.image = [UIImage systemImageNamed:@"waveform.path.ecg"];
            c.imageProperties.tintColor = wq_theme_accent();
        } else {
            NSArray<NSString *> *targets = @[@"1.1.1.1", @"8.8.8.8", @"github.com", WQLocalized(@"Custom Host…")];
            c.text = indexPath.row == 4 ? targets[3] : WQLocalizedFormat(@"Ping %@", targets[(NSUInteger)indexPath.row - 1]);
            c.image = [UIImage systemImageNamed:indexPath.row == 4 ? @"magnifyingglass" : @"network"];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (indexPath.section == 0) {
        [self openFloatingHUDConfig];
        return;
    }
    if (indexPath.section == 3 && _networkRows.count) {
        UIPasteboard.generalPasteboard.string = _networkRows[(NSUInteger)indexPath.row][1];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        wq_alert(self, WQLocalized(@"Copied"), WQLocalized(@"IP address copied to clipboard."));
        return;
    }
    if (indexPath.section == 4) {
        if (indexPath.row == 1) [self runPingForHost:@"1.1.1.1"];
        else if (indexPath.row == 2) [self runPingForHost:@"8.8.8.8"];
        else if (indexPath.row == 3) [self runPingForHost:@"github.com"];
        else if (indexPath.row == 4) [self promptCustomPing];
    }
}

@end
