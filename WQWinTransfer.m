//
//  WQWinTransfer.m
//  WQ Glass
//
//  Ultra-fast iPhone <-> Windows Wi-Fi Transfer Server + UDP LAN Auto-Discovery (port 45888)
//  compatible with the WQGlass Transfer Windows desktop software and any PC browser.
//

#import "WQWinTransfer.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQTheme.h"
#import "WQMotion.h"
#import "WQUI.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/statvfs.h>
#import <unistd.h>

NSNotificationName const WQLanTransferStatusDidChangeNotification = @"WQLanTransferStatusDidChangeNotification";

static NSString *const kWQWinFixedPinPref = @"WQWinTransferFixedPIN";
static NSString *const kWQWinLastEndpointPref = @"WQWinTransferLastEndpoint";
static NSString *const kWQWinLastPinPref = @"WQWinTransferLastPIN";
static const uint16_t kWQWinDiscoveryPort = 45888;
static const uint16_t kWQWinBasePort = 8765;
static const size_t kWQWinChunkBytes = 1024 * 1024;
static const int kWQWinSocketBufBytes = 4 * 1024 * 1024;
static const NSUInteger kWQWinMaxHeaderBytes = 16384;

@implementation WQLanTransferConnectionSnapshot

- (NSString *)statusTitle
{
    switch (self.mode) {
        case WQLanConnectionModeConnectedUSB:
            return [NSString stringWithFormat:@"⚡ Connected via USB · %@", self.peerName.length ? self.peerName : @"Windows PC"];
        case WQLanConnectionModeConnectedWiFi:
            return [NSString stringWithFormat:@"📶 Connected via Wi-Fi · %@", self.peerName.length ? self.peerName : @"Remote Device"];
        case WQLanConnectionModeWaitingReady:
            return [NSString stringWithFormat:@"● Ready · Wi-Fi & USB Cable (PIN %@)", self.pinText.length ? self.pinText : @"----"];
        default:
            return @"○ Not Connected · Tap for USB / Wi-Fi Transfer";
    }
}

- (NSString *)statusSubtitle
{
    if (self.activeBytesPerSec > 100.0) {
        double mbps = self.activeBytesPerSec / 1048576.0;
        NSString *spd = (mbps >= 1.0)
            ? [NSString stringWithFormat:@"%.1f MB/s", mbps]
            : [NSString stringWithFormat:@"%.0f KB/s", self.activeBytesPerSec / 1024.0];
        return [NSString stringWithFormat:@"Transferring at %@ · /%@", spd, self.rootLabel.length ? self.rootLabel : @"Downloads"];
    }
    switch (self.mode) {
        case WQLanConnectionModeConnectedUSB:
            return [NSString stringWithFormat:@"Direct Lightning/USB-C Tunnel · Sharing /%@", self.rootLabel.length ? self.rootLabel : @"App Data"];
        case WQLanConnectionModeConnectedWiFi:
            return [NSString stringWithFormat:@"%@ · /%@", self.endpointText.length ? self.endpointText : @"LAN", self.rootLabel.length ? self.rootLabel : @"Downloads"];
        case WQLanConnectionModeWaitingReady:
            return [NSString stringWithFormat:@"%@ · Sharing /%@", self.endpointText.length ? self.endpointText : @"USB Ready", self.rootLabel.length ? self.rootLabel : @"Downloads"];
        default:
            return @"Connect to Windows PC (USB / Wi-Fi) or Android";
    }
}

@end

static NSLock *gWQTransferStateLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSLock new];
    });
    return lock;
}

static NSString *gHostActiveTransport = @"none"; // @"none", @"usb", @"wifi"
static NSString *gHostActivePeerName = @"";
static CFAbsoluteTime gHostLastPeerSeen = 0;
static double gActiveTransferBps = 0;
static CFAbsoluteTime gActiveTransferBpsTime = 0;

static NSString *gClientActiveTransport = @"none"; // @"none", @"usb", @"wifi"
static NSString *gClientActivePeerName = @"";
static NSString *gClientActiveEndpoint = @"";
static NSString *gClientActiveRoot = @"";

static void wq_lan_notify_status_changed(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:WQLanTransferStatusDidChangeNotification object:nil];
    });
}

static void wq_lan_record_host_peer(NSString *transport, NSString *peerName)
{
    [gWQTransferStateLock() lock];
    BOOL changed = ![gHostActiveTransport isEqualToString:transport] || ![gHostActivePeerName isEqualToString:peerName];
    gHostActiveTransport = [transport copy];
    gHostActivePeerName = [peerName copy];
    gHostLastPeerSeen = CFAbsoluteTimeGetCurrent();
    [gWQTransferStateLock() unlock];
    if (changed) wq_lan_notify_status_changed();
}

static void wq_lan_record_transfer_speed(double bps)
{
    [gWQTransferStateLock() lock];
    gActiveTransferBps = bps;
    gActiveTransferBpsTime = CFAbsoluteTimeGetCurrent();
    [gWQTransferStateLock() unlock];
    wq_lan_notify_status_changed();
}

static void wq_lan_record_client_connected(NSString *transport, NSString *peerName, NSString *endpoint, NSString *root)
{
    [gWQTransferStateLock() lock];
    gClientActiveTransport = [transport ?: @"wifi" copy];
    gClientActivePeerName = [peerName ?: @"" copy];
    gClientActiveEndpoint = [endpoint ?: @"" copy];
    gClientActiveRoot = [root ?: @"Downloads" copy];
    [gWQTransferStateLock() unlock];
    wq_lan_notify_status_changed();
}

static NSString *wq_win_downloads_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dl = [docs stringByAppendingPathComponent:@"Downloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:nil error:nil];
    return dl;
}

static NSString *wq_win_documents_dir(void)
{
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
}

static NSString *wq_win_selected_outbox_dir(void)
{
    NSString *docs = wq_win_documents_dir();
    NSString *outbox = [docs stringByAppendingPathComponent:@"WQGlass_SharedOutbox"];
    [NSFileManager.defaultManager createDirectoryAtPath:outbox withIntermediateDirectories:YES attributes:nil error:nil];
    return outbox;
}

static BOOL wq_win_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static BOOL wq_win_is_outside_sandbox(NSString *path)
{
    if (!path.length) return NO;
    NSString *docs = wq_win_documents_dir().stringByStandardizingPath;
    NSString *std = path.stringByStandardizingPath;
    return ![std isEqualToString:docs] && ![std hasPrefix:[docs stringByAppendingString:@"/"]];
}

static BOOL wq_win_is_private_ipv4(NSString *ip)
{
    if (!ip.length) return NO;
    if ([ip hasPrefix:@"192.168."] || [ip hasPrefix:@"10."]) return YES;
    if ([ip hasPrefix:@"172."]) {
        NSArray<NSString *> *parts = [ip componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            NSInteger second = parts[1].integerValue;
            if (second >= 16 && second <= 31) return YES;
        }
    }
    return NO;
}

static NSString *wq_win_all_network_interfaces_summary(void)
{
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return @"none";
    NSMutableArray<NSString *> *items = [NSMutableArray new];
    for (struct ifaddrs *cur = addrs; cur; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        if (!(cur->ifa_flags & IFF_UP) || (cur->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        NSString *name = cur->ifa_name ? [NSString stringWithUTF8String:cur->ifa_name] : @"?";
        [items addObject:[NSString stringWithFormat:@"%@=%@", name, ip]];
    }
    freeifaddrs(addrs);
    return items.count ? [items componentsJoinedByString:@", "] : @"none";
}

static NSString *wq_win_wifi_ipv4(void)
{
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return nil;
    NSString *wifi = nil;
    NSString *hotspot = nil;
    NSString *enFallback = nil;
    NSString *anyPrivate = nil;
    for (struct ifaddrs *cur = addrs; cur; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        if (!(cur->ifa_flags & IFF_UP) || (cur->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip hasPrefix:@"169.254."]) continue;
        NSString *name = cur->ifa_name ? [NSString stringWithUTF8String:cur->ifa_name] : @"";
        if ([name isEqualToString:@"en0"] && wq_win_is_private_ipv4(ip)) {
            wifi = ip;
        } else if (([name hasPrefix:@"bridge"] || [name hasPrefix:@"ap"]) && wq_win_is_private_ipv4(ip)) {
            if (!hotspot) hotspot = ip;
        } else if ([name hasPrefix:@"en"] && wq_win_is_private_ipv4(ip)) {
            if (!enFallback) enFallback = ip;
        } else if (![name hasPrefix:@"pdp_ip"] && ![name hasPrefix:@"utun"] && wq_win_is_private_ipv4(ip)) {
            if (!anyPrivate) anyPrivate = ip;
        }
    }
    freeifaddrs(addrs);
    return wifi ?: hotspot ?: enFallback ?: anyPrivate;
}

static NSString *wq_win_random_pin(void)
{
    uint32_t v = arc4random_uniform(9000) + 1000;
    return [NSString stringWithFormat:@"%04u", v];
}

static BOOL wq_win_send_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t rem = len;
    while (rem > 0) {
        ssize_t n = send(fd, p, rem, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += (size_t)n;
        rem -= (size_t)n;
    }
    return YES;
}

static BOOL wq_win_write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t rem = len;
    while (rem > 0) {
        ssize_t n = write(fd, p, rem);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += (size_t)n;
        rem -= (size_t)n;
    }
    return YES;
}

static NSDictionary<NSString *, NSString *> *wq_win_parse_query(NSString *query)
{
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary new];
    if (!query.length) return out;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[pair substringToIndex:eq.location] stringByReplacingOccurrencesOfString:@"+" withString:@" "].stringByRemovingPercentEncoding;
        NSString *v = [[pair substringFromIndex:NSMaxRange(eq)] stringByReplacingOccurrencesOfString:@"+" withString:@" "].stringByRemovingPercentEncoding;
        if (k.length && v) out[k] = v;
    }
    return out;
}

static NSString *wq_win_safe_resolve(NSString *root, NSString *relPath)
{
    NSString *stdRoot = root.stringByStandardizingPath;
    if (!relPath.length || [relPath isEqualToString:@"/"]) return stdRoot;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *c in [relPath componentsSeparatedByString:@"/"]) {
        if (!c.length || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."] || [c containsString:@"\\"] || [c rangeOfString:@"\0"].location != NSNotFound) {
            return nil;
        }
        [parts addObject:c];
    }
    NSString *joined = stdRoot;
    for (NSString *c in parts) {
        joined = [joined stringByAppendingPathComponent:c];
    }
    NSString *stdJoined = joined.stringByStandardizingPath;
    if (![stdJoined isEqualToString:stdRoot] && ![stdJoined hasPrefix:[stdRoot stringByAppendingString:@"/"]]) {
        return nil;
    }
    return stdJoined;
}

static NSString *wq_win_unique_upload_path(NSString *dir, NSString *filename)
{
    NSString *clean = [[filename.lastPathComponent stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                       stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    if (!clean.length || [clean isEqualToString:@"."] || [clean isEqualToString:@".."]) clean = @"upload.bin";
    NSString *cand = [dir stringByAppendingPathComponent:clean];
    if (![NSFileManager.defaultManager fileExistsAtPath:cand]) return cand;
    NSString *ext = clean.pathExtension;
    NSString *stem = ext.length ? clean.stringByDeletingPathExtension : clean;
    for (NSUInteger i = 2; i < 10000; i++) {
        NSString *name = ext.length
            ? [NSString stringWithFormat:@"%@ (%lu).%@", stem, (unsigned long)i, ext]
            : [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)i];
        NSString *p = [dir stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", NSUUID.UUID.UUIDString, clean]];
}

static UIImage *wq_win_qr_image(NSString *text, CGFloat size)
{
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = f.outputImage;
    if (!ci) return nil;
    CGFloat scale = size / MAX(1.0, ci.extent.size.width);
    CIImage *scaled = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

static NSString *wq_win_web_ui_html(void)
{
    return @"<!doctype html><html><head><meta charset='utf-8'>"
           @"<meta name='viewport' content='width=device-width,initial-scale=1'>"
           @"<title>WQ Glass · LAN Transfer</title>"
           @"<style>"
           @"body{margin:0;font-family:-apple-system,Segoe UI,sans-serif;background:#0a0f1c;color:#f1f5f9;min-height:100vh;padding:24px;}"
           @".card{max-width:860px;margin:0 auto;background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.12);border-radius:18px;padding:20px;backdrop-filter:blur(16px);}"
           @"h1{margin:0 0 6px;font-size:22px;} .sub{color:#94a3b8;font-size:13px;margin-bottom:16px;}"
           @".bar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px;}"
           @"input,button{border-radius:10px;border:1px solid rgba(255,255,255,0.16);background:#111827;color:#fff;padding:10px 14px;font-size:14px;}"
           @"button{background:#2563eb;border:none;cursor:pointer;font-weight:600;} button.sec{background:#1e293b;}"
           @".drop{border:2px dashed rgba(96,165,250,0.45);border-radius:14px;padding:22px;text-align:center;color:#93c5fd;margin-bottom:14px;cursor:pointer;}"
           @".drop.over{background:rgba(37,99,235,0.18);border-color:#60a5fa;}"
           @"table{width:100%;border-collapse:collapse;} th,td{text-align:left;padding:10px 8px;border-bottom:1px solid rgba(255,255,255,0.08);font-size:14px;}"
           @"a{color:#60a5fa;text-decoration:none;font-weight:500;} .sz{color:#94a3b8;font-variant-numeric:tabular-nums;}"
           @"#prog{height:8px;background:#1e293b;border-radius:6px;overflow:hidden;margin:10px 0;display:none;} #pfill{height:100%;width:0%;background:#38bdf8;}"
           @"</style></head><body><div class='card'>"
           @"<h1>WQ Glass · LAN Transfer (iPhone · Windows · Android)</h1>"
           @"<div class='sub' id='info'>Enter the PIN shown on this iPhone to browse, download & upload files.</div>"
           @"<div class='bar'>"
           @"<input id='pin' placeholder='4-Digit PIN' style='width:130px'>"
           @"<button onclick='connect()'>Connect</button>"
           @"<button class='sec' onclick='goUp()'>↑ Up</button>"
           @"<button class='sec' onclick='refresh()'>↻ Refresh</button>"
           @"<button class='sec' onclick='makeFolder()'>+ New Folder</button>"
           @"</div>"
           @"<div class='drop' id='drop' onclick='document.getElementById(\"fpick\").click()'>Drag & Drop Files Here (or Click to Send Files to iPhone)</div>"
           @"<input type='file' id='fpick' multiple style='display:none' onchange='uploadFiles(this.files)'>"
           @"<div id='prog'><div id='pfill'></div></div><div class='sub' id='status'></div>"
           @"<table><thead><tr><th>Name</th><th>Size</th><th>Action</th></tr></thead><tbody id='rows'></tbody></table>"
           @"</div><script>"
           @"let curPath='',pin='';"
           @"function fmt(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(2)+' MB';return (b/1073741824).toFixed(2)+' GB';}"
           @"async function connect(){pin=document.getElementById('pin').value.trim();const r=await fetch('/api/info',{headers:{'X-WQ-PIN':pin}});if(!r.ok){document.getElementById('status').innerText='Invalid PIN';return;}const j=await r.json();document.getElementById('info').innerText=j.device+' · '+j.root+' · Free: '+fmt(j.freeBytes);refresh();}"
           @"async function refresh(){if(!pin)return;const r=await fetch('/api/list?path='+encodeURIComponent(curPath),{headers:{'X-WQ-PIN':pin}});if(!r.ok){document.getElementById('status').innerText='Auth failed';return;}const j=await r.json();const tb=document.getElementById('rows');tb.innerHTML='';for(const it of j.items){const tr=document.createElement('tr');const n=document.createElement('td');if(it.isDir){const a=document.createElement('a');a.href='#';a.textContent='📁 '+it.name;a.onclick=(e)=>{e.preventDefault();curPath=it.path;refresh();};n.appendChild(a);}else{n.textContent='📄 '+it.name;}const s=document.createElement('td');s.className='sz';s.textContent=it.isDir?'Folder':fmt(it.size);const ac=document.createElement('td');if(!it.isDir){const dl=document.createElement('a');dl.href='/api/download?path='+encodeURIComponent(it.path)+'&pin='+encodeURIComponent(pin);dl.textContent='Download';ac.appendChild(dl);}tr.appendChild(n);tr.appendChild(s);tr.appendChild(ac);tb.appendChild(tr);}document.getElementById('status').innerText='Path: /'+curPath+' ('+j.items.length+' items)';}"
           @"function goUp(){if(!curPath)return;const idx=curPath.lastIndexOf('/');curPath=idx>0?curPath.slice(0,idx):'';refresh();}"
           @"async function makeFolder(){const n=prompt('New folder name:');if(!n||!pin)return;const p=curPath?(curPath+'/'+n):n;await fetch('/api/mkdir?path='+encodeURIComponent(p),{method:'POST',headers:{'X-WQ-PIN':pin}});refresh();}"
           @"async function uploadFiles(files){if(!pin||!files.length)return;const pb=document.getElementById('prog'),pf=document.getElementById('pfill');pb.style.display='block';for(let i=0;i<files.length;i++){const f=files[i];document.getElementById('status').innerText='Sending '+f.name+' ('+(i+1)+'/'+files.length+')…';await new Promise((res,rej)=>{const xhr=new XMLHttpRequest();xhr.open('POST','/api/upload?path='+encodeURIComponent(curPath)+'&name='+encodeURIComponent(f.name));xhr.setRequestHeader('X-WQ-PIN',pin);xhr.upload.onprogress=(e)=>{if(e.lengthComputable)pf.style.width=(100*e.loaded/e.total).toFixed(1)+'%';};xhr.onload=()=>res();xhr.onerror=()=>rej();xhr.send(f);});}pb.style.display='none';document.getElementById('status').innerText='Upload complete!';refresh();}"
           @"const d=document.getElementById('drop');d.ondragover=(e)=>{e.preventDefault();d.classList.add('over');};d.ondragleave=()=>d.classList.remove('over');d.ondrop=(e)=>{e.preventDefault();d.classList.remove('over');uploadFiles(e.dataTransfer.files);};"
           @"const qp=new URLSearchParams(location.search).get('pin');if(qp){document.getElementById('pin').value=qp;connect();}"
           @"</script></body></html>";
}

#pragma mark - Server Engine

@interface WQWinTransferServer : NSObject
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, copy) NSString *rootLabel;
@property (nonatomic, copy) NSString *pin;
@property (nonatomic, readonly, nullable) NSString *ipAddress;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, copy, nullable) void (^onActivity)(NSString *entry);
@property (nonatomic, copy, nullable) void (^onRootChanged)(void);
- (BOOL)startWithError:(NSString *_Nullable *_Nullable)errorOut;
- (void)stop;
@end

@implementation WQWinTransferServer {
    int _listenFD;
    int _udpFD;
    dispatch_source_t _acceptSource;
    dispatch_source_t _udpReadSource;
    dispatch_source_t _beaconTimer;
    dispatch_queue_t _netQueue;
    dispatch_semaphore_t _connSlots;
    atomic_bool _stopped;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _listenFD = -1;
        _udpFD = -1;
        _rootPath = wq_win_downloads_dir();
        _rootLabel = @"Downloads";
        NSString *fixed = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinFixedPinPref];
        _pin = (fixed.length >= 4) ? fixed : wq_win_random_pin();
        _netQueue = dispatch_queue_create("com.wqglass.wintransfer.net", DISPATCH_QUEUE_CONCURRENT);
        _connSlots = dispatch_semaphore_create(16);
        atomic_init(&_stopped, true);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (BOOL)isRunning
{
    return !atomic_load(&_stopped);
}

- (void)emitActivity:(NSString *)line
{
    if (!line.length) return;
    wq_log(@"[Transfer] %@", line);
    if (!self.onActivity) return;
    void (^cb)(NSString *) = self.onActivity;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(line); });
}

- (NSData *)discoveryBeaconJSON
{
    NSDictionary *payload = @{
        @"app": @"WQGlass",
        @"version": @"1.1",
        @"device": UIDevice.currentDevice.name ?: @"iPhone",
        @"platform": @"ios",
        @"osVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"ip": _ipAddress ?: @"",
        @"port": @(_port),
        @"root": _rootLabel ?: @"Downloads",
        @"pinRequired": @YES,
    };
    return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] ?: [NSData data];
}

- (void)startUDPDiscovery
{
    int ufd = socket(AF_INET, SOCK_DGRAM, 0);
    if (ufd < 0) return;
    int yes = 1;
    setsockopt(ufd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(ufd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
    setsockopt(ufd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kWQWinDiscoveryPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ufd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        // Still use unbound socket for outbound broadcasts if port is busy.
    }
    _udpFD = ufd;

    __weak typeof(self) weakSelf = self;
    dispatch_source_t rs = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)ufd, 0, _netQueue);
    dispatch_source_set_event_handler(rs, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || atomic_load(&me->_stopped)) return;
        char buf[512];
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(ufd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&peer, &peerLen);
        if (n > 0) {
            buf[n] = '\0';
            if (strstr(buf, "WQGLASS_DISCOVER") != NULL) {
                NSData *resp = [me discoveryBeaconJSON];
                if (resp.length) {
                    sendto(ufd, resp.bytes, resp.length, 0, (struct sockaddr *)&peer, peerLen);
                }
            }
        }
    });
    dispatch_source_set_cancel_handler(rs, ^{
        close(ufd);
    });
    _udpReadSource = rs;
    dispatch_resume(rs);

    dispatch_source_t bt = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _netQueue);
    dispatch_source_set_timer(bt, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(bt, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || atomic_load(&me->_stopped)) return;
        NSData *pkt = [me discoveryBeaconJSON];
        if (!pkt.length) return;
        struct sockaddr_in bcast;
        memset(&bcast, 0, sizeof(bcast));
        bcast.sin_family = AF_INET;
        bcast.sin_port = htons(kWQWinDiscoveryPort);
        bcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
        sendto(ufd, pkt.bytes, pkt.length, 0, (struct sockaddr *)&bcast, sizeof(bcast));

        // Also send to the directed /24 subnet broadcast (e.g. 192.168.128.255) for hotspots/routers
        NSString *myIP = me->_ipAddress;
        NSArray<NSString *> *parts = [myIP componentsSeparatedByString:@"."];
        if (parts.count == 4) {
            NSString *subBcast = [NSString stringWithFormat:@"%@.%@.%@.255", parts[0], parts[1], parts[2]];
            struct sockaddr_in sb;
            memset(&sb, 0, sizeof(sb));
            sb.sin_family = AF_INET;
            sb.sin_port = htons(kWQWinDiscoveryPort);
            if (inet_pton(AF_INET, subBcast.UTF8String, &sb.sin_addr) == 1) {
                sendto(ufd, pkt.bytes, pkt.length, 0, (struct sockaddr *)&sb, sizeof(sb));
            }
        }
    });
    _beaconTimer = bt;
    dispatch_resume(bt);
}

- (BOOL)startWithError:(NSString **)errorOut
{
    [self stop];
    NSString *ip = wq_win_wifi_ipv4();
    BOOL wifiAvailable = (ip.length > 0);
    if (!wifiAvailable) {
        // Still start TCP server on 0.0.0.0:8765 so Windows PC can connect over Lightning/USB-C (usbmuxd) even with Wi-Fi OFF.
        ip = @"127.0.0.1";
    }

    int fd = -1;
    uint16_t chosenPort = 0;
    for (uint16_t p = kWQWinBasePort; p < kWQWinBasePort + 16; p++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) continue;
        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct sockaddr_in sin;
        memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_port = htons(p);
        sin.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, (struct sockaddr *)&sin, sizeof(sin)) == 0 && listen(s, 32) == 0) {
            fd = s;
            chosenPort = p;
            break;
        }
        close(s);
    }
    if (fd < 0) {
        NSString *msg = WQLocalized(@"Could not bind a local Wi-Fi / USB transfer port.");
        wq_log_error(@"HostServer", @"%@ (errno=%d · ifaces: %@)", msg, errno, wq_win_all_network_interfaces_summary());
        if (errorOut) *errorOut = msg;
        return NO;
    }

    _listenFD = fd;
    _ipAddress = [ip copy];
    _port = chosenPort;
    atomic_store(&_stopped, false);

    __weak typeof(self) weakSelf = self;
    dispatch_source_t acc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _netQueue);
    dispatch_source_set_event_handler(acc, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || atomic_load(&me->_stopped)) return;
        struct sockaddr_in cli;
        socklen_t cliLen = sizeof(cli);
        int cfd = accept(fd, (struct sockaddr *)&cli, &cliLen);
        if (cfd < 0) return;
        int yes = 1;
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct timeval tv;
        tv.tv_sec = 30;
        tv.tv_usec = 0;
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (dispatch_semaphore_wait(me->_connSlots, DISPATCH_TIME_NOW) != 0) {
            close(cfd);
            return;
        }
        dispatch_async(me->_netQueue, ^{
            @autoreleasepool {
                [me handleClientFD:cfd];
            }
            close(cfd);
            dispatch_semaphore_signal(me->_connSlots);
        });
    });
    dispatch_source_set_cancel_handler(acc, ^{
        close(fd);
    });
    _acceptSource = acc;
    dispatch_resume(acc);

    if (wifiAvailable) {
        [self startUDPDiscovery];
    }
    [self emitActivity:[NSString stringWithFormat:@"iOS Host ready at http://%@:%u · PIN %@ · Sharing /%@ (ifaces: %@)",
                        _ipAddress, (unsigned)_port, _pin, _rootLabel ?: @"Downloads", wq_win_all_network_interfaces_summary()]];
    wq_lan_notify_status_changed();
    return YES;
}

- (void)stop
{
    atomic_store(&_stopped, true);
    if (_beaconTimer) {
        dispatch_source_cancel(_beaconTimer);
        _beaconTimer = nil;
    }
    if (_udpReadSource) {
        _udpFD = -1;
        dispatch_source_cancel(_udpReadSource);
        _udpReadSource = nil;
    } else if (_udpFD >= 0) {
        close(_udpFD);
        _udpFD = -1;
    }
    if (_acceptSource) {
        _listenFD = -1;
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    } else if (_listenFD >= 0) {
        close(_listenFD);
        _listenFD = -1;
    }
    wq_lan_notify_status_changed();
}

#pragma mark HTTP Request Handling

- (void)sendStatus:(int)code text:(NSString *)statusText contentType:(NSString *)ctype body:(NSData *)body toFD:(int)fd
{
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: X-WQ-PIN, X-WQ-TRANSPORT, X-WQ-CLIENT, Content-Type\r\nConnection: close\r\n\r\n",
        code, statusText, ctype, (unsigned long)body.length];
    NSData *hData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    if (!wq_win_send_all(fd, hData.bytes, hData.length)) return;
    if (body.length) wq_win_send_all(fd, body.bytes, body.length);
}

- (void)sendJSON:(id)obj status:(int)code toFD:(int)fd
{
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    [self sendStatus:code text:(code == 200 ? @"OK" : @"Error") contentType:@"application/json; charset=utf-8" body:d toFD:fd];
}

- (void)handleClientFD:(int)fd
{
    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
    int sbuf = kWQWinSocketBufBytes;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sbuf, sizeof(sbuf));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sbuf, sizeof(sbuf));

    NSString *peerIP = @"";
    struct sockaddr_in peerAddr;
    socklen_t peerLen = sizeof(peerAddr);
    if (getpeername(fd, (struct sockaddr *)&peerAddr, &peerLen) == 0 && peerAddr.sin_family == AF_INET) {
        char ipBuf[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &peerAddr.sin_addr, ipBuf, sizeof(ipBuf))) {
            peerIP = [NSString stringWithUTF8String:ipBuf] ?: @"";
        }
    }

    NSMutableData *buf = [NSMutableData dataWithCapacity:4096];
    uint8_t tmp[4096];
    NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
    NSData *delim = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (buf.length < kWQWinMaxHeaderBytes) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        [buf appendBytes:tmp length:(NSUInteger)n];
        hdrEnd = [buf rangeOfData:delim options:0 range:NSMakeRange(0, buf.length)];
        if (hdrEnd.location != NSNotFound) break;
    }
    if (hdrEnd.location == NSNotFound) return;

    NSData *hdrBytes = [buf subdataWithRange:NSMakeRange(0, hdrEnd.location)];
    NSUInteger bodyOffset = NSMaxRange(hdrEnd);
    NSData *initialBody = (bodyOffset < buf.length)
        ? [buf subdataWithRange:NSMakeRange(bodyOffset, buf.length - bodyOffset)]
        : [NSData data];

    NSString *hdrStr = [[NSString alloc] initWithData:hdrBytes encoding:NSUTF8StringEncoding];
    if (!hdrStr.length) return;
    NSArray<NSString *> *lines = [hdrStr componentsSeparatedByString:@"\r\n"];
    if (!lines.count) return;
    NSArray<NSString *> *reqParts = [lines.firstObject componentsSeparatedByString:@" "];
    if (reqParts.count < 2) return;

    NSString *method = reqParts[0].uppercaseString;
    NSString *rawTarget = reqParts[1];
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary new];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *l = lines[i];
        NSRange col = [l rangeOfString:@":"];
        if (col.location == NSNotFound) continue;
        NSString *k = [[l substringToIndex:col.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        NSString *v = [[l substringFromIndex:NSMaxRange(col)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[k] = v;
    }

    if ([method isEqualToString:@"OPTIONS"]) {
        [self sendStatus:200 text:@"OK" contentType:@"text/plain" body:[NSData data] toFD:fd];
        return;
    }

    NSString *route = rawTarget;
    NSString *queryStr = @"";
    NSRange qm = [rawTarget rangeOfString:@"?"];
    if (qm.location != NSNotFound) {
        route = [rawTarget substringToIndex:qm.location];
        queryStr = [rawTarget substringFromIndex:NSMaxRange(qm)];
    }
    NSDictionary<NSString *, NSString *> *query = wq_win_parse_query(queryStr);

    if ([route isEqualToString:@"/"] && [method isEqualToString:@"GET"]) {
        NSData *html = [wq_win_web_ui_html() dataUsingEncoding:NSUTF8StringEncoding];
        [self sendStatus:200 text:@"OK" contentType:@"text/html; charset=utf-8" body:html toFD:fd];
        return;
    }

    // Detect USB Cable tunnel (127.0.0.1 over usbmuxd or X-WQ-TRANSPORT: usb)
    NSString *hdrTransport = (headers[@"x-wq-transport"] ?: query[@"transport"] ?: @"").lowercaseString;
    BOOL isUsbConnection = [peerIP isEqualToString:@"127.0.0.1"] || [hdrTransport isEqualToString:@"usb"];
    NSString *activeTransport = isUsbConnection ? @"usb" : @"wifi";
    NSString *clientName = headers[@"x-wq-client"] ?: (isUsbConnection ? @"Windows PC (USB)" : (peerIP.length ? peerIP : @"Remote Peer"));

    NSString *suppliedPin = headers[@"x-wq-pin"] ?: query[@"pin"] ?: @"";
    // Over direct physical USB cable tunnel (127.0.0.1 via usbmuxd), allow either matching PIN or auto-trusted USB keyword ("USB" / empty) so the user doesn't get stuck typing PINs when connecting via cable!
    BOOL pinValid = [suppliedPin isEqualToString:self.pin] ||
                    (isUsbConnection && ([suppliedPin.uppercaseString isEqualToString:@"USB"] || [suppliedPin isEqualToString:@"0000"]));
    if (!pinValid) {
        [self sendJSON:@{ @"error": @"Invalid PIN" } status:401 toFD:fd];
        return;
    }

    wq_lan_record_host_peer(activeTransport, clientName);

    if ([route isEqualToString:@"/api/ping"] && [method isEqualToString:@"GET"]) {
        [self sendJSON:@{
            @"ok": @YES,
            @"transport": activeTransport,
            @"root": self.rootLabel ?: @"Downloads",
        } status:200 toFD:fd];
        return;
    }

    NSString *root = self.rootPath ?: wq_win_downloads_dir();

    if ([route isEqualToString:@"/api/info"] && [method isEqualToString:@"GET"]) {
        struct statvfs stv;
        unsigned long long freeB = 0, totalB = 0;
        NSString *statTarget = wq_win_downloads_dir();
        if (statvfs(statTarget.fileSystemRepresentation, &stv) == 0) {
            freeB = (unsigned long long)stv.f_bavail * (unsigned long long)stv.f_frsize;
            totalB = (unsigned long long)stv.f_blocks * (unsigned long long)stv.f_frsize;
        }
        [self sendJSON:@{
            @"app": @"WQGlass",
            @"version": @"4.0",
            @"device": UIDevice.currentDevice.name ?: @"iPhone",
            @"platform": @"ios",
            @"osVersion": UIDevice.currentDevice.systemVersion ?: @"",
            @"ios": UIDevice.currentDevice.systemVersion ?: @"",
            @"root": self.rootLabel ?: @"Downloads",
            @"transport": activeTransport,
            @"freeBytes": @(freeB),
            @"totalBytes": @(totalB),
        } status:200 toFD:fd];
        [self emitActivity:[NSString stringWithFormat:@"%@ Connected: %@ · Sharing /%@",
                            isUsbConnection ? @"⚡ USB Cable" : @"📶 Wi-Fi",
                            clientName,
                            self.rootLabel ?: @"Downloads"]];
        return;
    }

    if ([route isEqualToString:@"/api/list"] && [method isEqualToString:@"GET"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target) {
            [self sendJSON:@{ @"error": @"Invalid path" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(target);
        BOOL isAppContainerParent = [target.stringByStandardizingPath isEqualToString:@"/private/var/mobile/Containers/Data/Application"] ||
                                    [target.stringByStandardizingPath isEqualToString:@"/var/mobile/Containers/Data/Application"];

        NSMutableArray<NSDictionary *> *items = [NSMutableArray new];

        if (isAppContainerParent && !rel.length) {
            // Enumerate all installed App Data Containers using WQAccess + LaunchServices (like 3uTools / iTunes File Sharing!)
            if (!wq_display_names_loaded()) {
                wq_load_display_names();
            }
            NSArray<NSString *> *containerPaths = wq_ls_container_paths(nil);
            if (!containerPaths.count) {
                containerPaths = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
            }
            NSMutableSet<NSString *> *seenUUIDs = [NSMutableSet new];
            for (NSString *full in containerPaths) {
                NSString *uuid = full.lastPathComponent;
                if (!uuid.length || [seenUUIDs containsObject:uuid]) continue;
                [seenUUIDs addObject:uuid];
                (void)wq_grant(full);
                struct stat st;
                long long mtime = 0;
                if (wq_stat(full, &st)) {
                    mtime = (long long)st.st_mtime;
                }
                NSString *bid = wq_bundle_id_for_container(full) ?: wq_container_label(full);
                NSString *appName = bid.length ? wq_display_name(bid) : nil;
                NSString *displayName = nil;
                if (appName.length && bid.length && ![appName isEqualToString:bid]) {
                    displayName = [NSString stringWithFormat:@"%@ (%@)", appName, bid];
                } else if (bid.length) {
                    displayName = [NSString stringWithFormat:@"%@ [%@]", bid, [uuid substringToIndex:MIN((NSUInteger)8, uuid.length)]];
                } else {
                    displayName = [NSString stringWithFormat:@"App Container (%@)", [uuid substringToIndex:MIN((NSUInteger)8, uuid.length)]];
                }
                [items addObject:@{
                    @"name": displayName,
                    @"path": uuid,
                    @"isDir": @YES,
                    @"size": @(0ULL),
                    @"mtime": @(mtime),
                }];
            }
            // Fallback: also check wq_list if containerPaths was empty
            if (!items.count) {
                NSString *listErr = nil;
                NSArray<NSString *> *names = wq_list(target, &listErr) ?: @[];
                for (NSString *uuid in names) {
                    if ([uuid hasPrefix:@"."]) continue;
                    NSString *full = [target stringByAppendingPathComponent:uuid];
                    (void)wq_grant(full);
                    NSString *bid = wq_bundle_id_for_container(full) ?: wq_container_label(full);
                    NSString *appName = bid.length ? wq_display_name(bid) : nil;
                    NSString *displayName = (appName.length && bid.length) ? [NSString stringWithFormat:@"%@ (%@)", appName, bid] : (bid ?: uuid);
                    [items addObject:@{
                        @"name": displayName,
                        @"path": uuid,
                        @"isDir": @YES,
                        @"size": @(0ULL),
                        @"mtime": @(0LL),
                    }];
                }
            }
        } else {
            if (outsideSandbox) {
                // Ensure container root and target directory hold sandbox extension tokens
                NSArray<NSString *> *relParts = [rel componentsSeparatedByString:@"/"];
                if (relParts.count > 0 && wq_win_looks_like_uuid(relParts.firstObject)) {
                    NSString *containerRoot = [root stringByAppendingPathComponent:relParts.firstObject];
                    (void)wq_grant(containerRoot);
                }
                (void)wq_grant(target);
            }
            NSString *listErr = nil;
            NSArray<NSString *> *names = outsideSandbox
                ? (wq_list(target, &listErr) ?: [NSFileManager.defaultManager contentsOfDirectoryAtPath:target error:nil] ?: @[])
                : ([NSFileManager.defaultManager contentsOfDirectoryAtPath:target error:nil] ?: wq_list(target, &listErr) ?: @[]);

            for (NSString *name in names) {
                if ([name hasPrefix:@".wq"] || [name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) continue;
                NSString *full = [target stringByAppendingPathComponent:name];
                struct stat st;
                BOOL statOk = outsideSandbox ? wq_stat(full, &st) : (lstat(full.fileSystemRepresentation, &st) == 0);
                if (!statOk) continue;
                BOOL isDir = S_ISDIR(st.st_mode);
                NSString *itemRel = rel.length ? [rel stringByAppendingPathComponent:name] : name;
                [items addObject:@{
                    @"name": name,
                    @"path": itemRel,
                    @"isDir": @(isDir),
                    @"size": @(isDir ? 0ULL : (unsigned long long)st.st_size),
                    @"mtime": @((long long)st.st_mtime),
                }];
            }
        }

        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL da = [a[@"isDir"] boolValue];
            BOOL db = [b[@"isDir"] boolValue];
            if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
            return [(NSString *)a[@"name"] localizedCaseInsensitiveCompare:(NSString *)b[@"name"]];
        }];
        [self sendJSON:@{ @"path": rel, @"items": items } status:200 toFD:fd];
        return;
    }

    if ([route isEqualToString:@"/api/download"] && ([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"])) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target) {
            [self sendJSON:@{ @"error": @"Invalid path" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(target);
        if (outsideSandbox) {
            (void)wq_grant(target.stringByDeletingLastPathComponent);
        }
        int ffd = outsideSandbox ? wq_open_for_reading(target) : open(target.fileSystemRepresentation, O_RDONLY);
        if (ffd < 0 && !outsideSandbox) {
            ffd = wq_open_for_reading(target);
        }
        struct stat st;
        if (ffd < 0 || fstat(ffd, &st) != 0 || !S_ISREG(st.st_mode)) {
            if (ffd >= 0) close(ffd);
            [self sendJSON:@{ @"error": @"File not found or unreadable" } status:404 toFD:fd];
            return;
        }
        int64_t fileSize = (int64_t)st.st_size;
        int64_t start = 0;
        int64_t end = MAX(0LL, fileSize - 1);
        BOOL partial = NO;
        NSString *rangeHdr = headers[@"range"];
        if ([rangeHdr.lowercaseString hasPrefix:@"bytes="]) {
            NSString *spec = [rangeHdr substringFromIndex:6];
            NSRange dash = [spec rangeOfString:@"-"];
            if (dash.location != NSNotFound) {
                NSString *s1 = [spec substringToIndex:dash.location];
                NSString *s2 = [spec substringFromIndex:NSMaxRange(dash)];
                if (s1.length) start = MAX(0LL, strtoll(s1.UTF8String, NULL, 10));
                if (s2.length) end = MIN(fileSize - 1, strtoll(s2.UTF8String, NULL, 10));
                if (start <= end && fileSize > 0) partial = YES;
            }
        }
        int64_t sendLen = (fileSize > 0) ? (end - start + 1) : 0;
        NSString *safeName = [target.lastPathComponent stringByReplacingOccurrencesOfString:@"\"" withString:@"_"];
        NSString *respHdr = nil;
        if (partial) {
            respHdr = [NSString stringWithFormat:
                @"HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"%@\"\r\nAccept-Ranges: bytes\r\nContent-Range: bytes %lld-%lld/%lld\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n",
                safeName, start, end, fileSize, sendLen];
        } else {
            respHdr = [NSString stringWithFormat:
                @"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"%@\"\r\nAccept-Ranges: bytes\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n",
                safeName, sendLen];
        }
        NSData *hData = [respHdr dataUsingEncoding:NSUTF8StringEncoding];
        if (!wq_win_send_all(fd, hData.bytes, hData.length) || [method isEqualToString:@"HEAD"]) {
            close(ffd);
            return;
        }

        if (start > 0) lseek(ffd, (off_t)start, SEEK_SET);
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        uint8_t *chunk = (uint8_t *)malloc(kWQWinChunkBytes);
        if (chunk) {
            int64_t rem = sendLen;
            int64_t sentSoFar = 0;
            while (rem > 0 && !atomic_load(&_stopped)) {
                size_t toRead = (size_t)MIN((int64_t)kWQWinChunkBytes, rem);
                ssize_t nr = read(ffd, chunk, toRead);
                if (nr <= 0) break;
                if (!wq_win_send_all(fd, chunk, (size_t)nr)) break;
                rem -= (int64_t)nr;
                sentSoFar += (int64_t)nr;
                double dt = MAX(0.02, CFAbsoluteTimeGetCurrent() - t0);
                wq_lan_record_transfer_speed((double)sentSoFar / dt);
            }
            free(chunk);
        }
        close(ffd);
        wq_lan_record_transfer_speed(0);
        [self emitActivity:[NSString stringWithFormat:@"→ Sent (%@): %@ (%@)",
                            isUsbConnection ? @"USB" : @"Wi-Fi",
                            target.lastPathComponent,
                            wq_size_text((unsigned long long)fileSize)]];
        return;
    }

    if ([route isEqualToString:@"/api/upload"] && [method isEqualToString:@"POST"]) {
        NSString *relDir = query[@"path"] ?: @"";
        NSString *fileName = query[@"name"] ?: @"upload.bin";
        NSString *dirPath = wq_win_safe_resolve(root, relDir);
        if (!dirPath) {
            [self sendJSON:@{ @"error": @"Invalid destination path" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(dirPath);
        if (outsideSandbox) {
            (void)wq_grant(dirPath);
            if (![NSFileManager.defaultManager fileExistsAtPath:dirPath]) {
                NSString *mkErr = nil;
                wq_create_dir(dirPath, &mkErr);
                (void)wq_grant(dirPath);
            }
        } else {
            [NSFileManager.defaultManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *clStr = headers[@"content-length"];
        if (!clStr.length) {
            [self sendJSON:@{ @"error": @"Missing Content-Length" } status:411 toFD:fd];
            return;
        }
        int64_t expected = strtoll(clStr.UTF8String, NULL, 10);
        if (expected < 0) {
            [self sendJSON:@{ @"error": @"Invalid Content-Length" } status:400 toFD:fd];
            return;
        }

        // Always stream incoming bytes to a sandbox temp file first, then move/install via WQAccess if outside sandbox
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@".wq-win-%@", NSUUID.UUID.UUIDString]];
        int outFD = open(tmpPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (outFD < 0) {
            [self sendJSON:@{ @"error": @"Cannot write temporary upload file" } status:500 toFD:fd];
            return;
        }
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        int64_t written = 0;
        BOOL ok = YES;
        if (initialBody.length) {
            size_t take = (size_t)MIN((int64_t)initialBody.length, expected);
            if (take > 0) {
                ok = wq_win_write_all(outFD, initialBody.bytes, take);
                written += (int64_t)take;
            }
        }
        uint8_t *chunk = (uint8_t *)malloc(kWQWinChunkBytes);
        if (!chunk) ok = NO;
        while (ok && written < expected && !atomic_load(&_stopped)) {
            size_t want = (size_t)MIN((int64_t)kWQWinChunkBytes, expected - written);
            ssize_t nr = recv(fd, chunk, want, 0);
            if (nr < 0 && errno == EINTR) continue;
            if (nr <= 0) { ok = NO; break; }
            if (!wq_win_write_all(outFD, chunk, (size_t)nr)) { ok = NO; break; }
            written += (int64_t)nr;
            double dt = MAX(0.02, CFAbsoluteTimeGetCurrent() - t0);
            wq_lan_record_transfer_speed((double)written / dt);
        }
        if (chunk) free(chunk);
        fsync(outFD);
        close(outFD);
        wq_lan_record_transfer_speed(0);

        if (!ok || written != expected) {
            unlink(tmpPath.fileSystemRepresentation);
            [self sendJSON:@{ @"error": @"Incomplete upload" } status:500 toFD:fd];
            return;
        }

        NSString *finalPath = wq_win_unique_upload_path(dirPath, fileName);
        BOOL installed = NO;
        if (outsideSandbox) {
            (void)wq_grant(dirPath);
            NSString *cErr = nil;
            installed = wq_create_file_from(finalPath, tmpPath, &cErr);
            if (!installed) {
                installed = wq_write_from_file(finalPath, tmpPath, &cErr);
            }
            unlink(tmpPath.fileSystemRepresentation);
        } else {
            if (rename(tmpPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) == 0) {
                installed = YES;
            } else {
                installed = [NSFileManager.defaultManager moveItemAtPath:tmpPath toPath:finalPath error:nil];
                unlink(tmpPath.fileSystemRepresentation);
            }
        }

        if (!installed) {
            [self sendJSON:@{ @"error": @"Could not finalize upload into destination folder" } status:500 toFD:fd];
            return;
        }
        [self sendJSON:@{ @"ok": @YES, @"name": finalPath.lastPathComponent, @"bytes": @(written) } status:200 toFD:fd];
        [self emitActivity:[NSString stringWithFormat:@"← Received (%@): %@ (%@)",
                            isUsbConnection ? @"USB" : @"Wi-Fi",
                            finalPath.lastPathComponent,
                            wq_size_text((unsigned long long)written)]];
        return;
    }

    if ([route isEqualToString:@"/api/mkdir"] && [method isEqualToString:@"POST"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target || [target isEqualToString:root.stringByStandardizingPath]) {
            [self sendJSON:@{ @"error": @"Invalid folder path" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(target);
        BOOL ok = NO;
        NSString *errMsg = nil;
        if (outsideSandbox) {
            (void)wq_grant(target.stringByDeletingLastPathComponent);
            ok = wq_create_dir(target, &errMsg);
        } else {
            NSError *err = nil;
            ok = [NSFileManager.defaultManager createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:&err];
            errMsg = err.localizedDescription;
        }
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"+ Created folder: %@", target.lastPathComponent]];
        } else {
            [self sendJSON:@{ @"error": errMsg ?: @"Could not create folder" } status:500 toFD:fd];
        }
        return;
    }

    if ([route isEqualToString:@"/api/delete"] && [method isEqualToString:@"POST"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target || [target isEqualToString:root.stringByStandardizingPath]) {
            [self sendJSON:@{ @"error": @"Invalid path" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(target);
        BOOL ok = NO;
        NSString *errMsg = nil;
        if (outsideSandbox) {
            (void)wq_grant(target.stringByDeletingLastPathComponent);
            ok = wq_delete(target, &errMsg);
            if (!ok) {
                ok = wq_delete_tree(target, nil, nil, NULL, NULL, &errMsg);
            }
        } else {
            NSError *err = nil;
            ok = [NSFileManager.defaultManager removeItemAtPath:target error:&err];
            errMsg = err.localizedDescription;
        }
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"× Deleted: %@", target.lastPathComponent]];
        } else {
            [self sendJSON:@{ @"error": errMsg ?: @"Delete failed" } status:500 toFD:fd];
        }
        return;
    }

    if ([route isEqualToString:@"/api/rename"] && [method isEqualToString:@"POST"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *newName = query[@"to"] ?: @"";
        NSString *src = wq_win_safe_resolve(root, rel);
        if (!src || !newName.length || [newName containsString:@"/"] || [newName isEqualToString:@".."] || [newName isEqualToString:@"."]) {
            [self sendJSON:@{ @"error": @"Invalid rename parameters" } status:400 toFD:fd];
            return;
        }
        BOOL outsideSandbox = wq_win_is_outside_sandbox(src);
        BOOL ok = NO;
        NSString *errMsg = nil;
        if (outsideSandbox) {
            (void)wq_grant(src.stringByDeletingLastPathComponent);
            ok = wq_rename(src, newName, &errMsg);
        } else {
            NSString *dst = [src.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName];
            NSError *err = nil;
            ok = [NSFileManager.defaultManager moveItemAtPath:src toPath:dst error:&err];
            errMsg = err.localizedDescription;
        }
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"✎ Renamed to: %@", newName]];
        } else {
            [self sendJSON:@{ @"error": errMsg ?: @"Rename failed" } status:500 toFD:fd];
        }
        return;
    }

    if ([route isEqualToString:@"/api/text"] && [method isEqualToString:@"POST"]) {
        long long contentLen = [headers[@"content-length"] longLongValue];
        if (contentLen < 0) contentLen = 0;
        if (contentLen > 256 * 1024) contentLen = 256 * 1024;
        NSMutableData *textData = [NSMutableData dataWithCapacity:(NSUInteger)contentLen];
        if (initialBody.length && contentLen > 0) {
            NSUInteger take = (NSUInteger)MIN((long long)initialBody.length, contentLen);
            [textData appendBytes:initialBody.bytes length:take];
        }
        uint8_t tbuf[8192];
        while ((long long)textData.length < contentLen) {
            size_t want = (size_t)MIN((long long)sizeof(tbuf), contentLen - (long long)textData.length);
            ssize_t r = recv(fd, tbuf, want, 0);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) break;
            [textData appendBytes:tbuf length:(NSUInteger)r];
        }
        NSString *txt = [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding] ?: @"";
        [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
        if (txt.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIPasteboard.generalPasteboard.string = txt;
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            });
            [self emitActivity:[NSString stringWithFormat:@"📋 Copied received text/link (%lu chars)", (unsigned long)txt.length]];
        }
        return;
    }

    if ([route isEqualToString:@"/api/setroot"] && [method isEqualToString:@"POST"]) {
        NSString *rootId = (query[@"id"] ?: @"").lowercaseString;
        if ([rootId isEqualToString:@"downloads"]) {
            self.rootPath = wq_win_downloads_dir();
            self.rootLabel = @"Downloads";
        } else if ([rootId isEqualToString:@"documents"]) {
            self.rootPath = wq_win_documents_dir();
            self.rootLabel = @"Documents";
        } else if ([rootId isEqualToString:@"selected"]) {
            self.rootPath = wq_win_selected_outbox_dir();
            self.rootLabel = @"My Selected Files";
        } else if ([rootId isEqualToString:@"appdata"]) {
            self.rootPath = @"/private/var/mobile/Containers/Data/Application";
            self.rootLabel = @"App Data";
        } else {
            [self sendJSON:@{ @"error": @"Unknown root id" } status:400 toFD:fd];
            return;
        }
        [self sendJSON:@{ @"ok": @YES, @"root": self.rootLabel ?: @"Downloads" } status:200 toFD:fd];
        [self emitActivity:[NSString stringWithFormat:@"📂 %@ switched shared folder → %@",
                            isUsbConnection ? @"PC (USB)" : @"PC (Wi-Fi)",
                            self.rootLabel]];
        wq_lan_notify_status_changed();
        void (^rcb)(void) = self.onRootChanged;
        if (rcb) dispatch_async(dispatch_get_main_queue(), rcb);
        return;
    }

    [self sendJSON:@{ @"error": @"Not found" } status:404 toFD:fd];
}

@end

#pragma mark - Cross-Platform Client Discovery & Remote File Browser

static NSString *wq_win_query_encode(NSString *value)
{
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *cs = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
        [cs removeCharactersInString:@"&=?+/#%"];
        allowed = [cs copy];
    });
    return [value ?: @"" stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *wq_win_speed_text(double bytesPerSec)
{
    if (bytesPerSec < 1024.0) return [NSString stringWithFormat:@"%.0f B/s", bytesPerSec];
    if (bytesPerSec < 1048576.0) return [NSString stringWithFormat:@"%.1f KB/s", bytesPerSec / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB/s", bytesPerSec / 1048576.0];
}

@interface WQLanPeer : NSObject
@property (nonatomic, copy) NSString *device;
@property (nonatomic, copy) NSString *platform;
@property (nonatomic, copy) NSString *osVersion;
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy) NSString *root;
@property (nonatomic, assign) NSTimeInterval lastSeen;
- (NSString *)endpoint;
- (NSString *)platformBadge;
- (NSString *)symbolName;
@end

@implementation WQLanPeer

- (NSString *)endpoint
{
    return [NSString stringWithFormat:@"%@:%u", self.ip ?: @"", (unsigned)self.port];
}

- (NSString *)normalizedPlatform
{
    NSString *p = (self.platform ?: @"").lowercaseString;
    if ([p isEqualToString:@"android"]) return @"android";
    if ([p isEqualToString:@"windows"]) return @"windows";
    return @"ios";
}

- (NSString *)platformBadge
{
    NSString *p = [self normalizedPlatform];
    if ([p isEqualToString:@"android"]) return @"Android";
    if ([p isEqualToString:@"windows"]) return @"Windows";
    return @"iOS";
}

- (NSString *)symbolName
{
    NSString *p = [self normalizedPlatform];
    if ([p isEqualToString:@"windows"]) return @"desktopcomputer";
    if ([p isEqualToString:@"android"]) return @"phone.fill";
    return @"iphone";
}

@end

@interface WQLanRemoteItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, assign) long long size;
@property (nonatomic, assign) long long mtime;
@end

@implementation WQLanRemoteItem
@end

@interface WQLanDiscoveryClient : NSObject
@property (nonatomic, copy, nullable) NSString *ignoreIP;
@property (nonatomic, assign) uint16_t ignorePort;
@property (nonatomic, copy, nullable) void (^onPeersChanged)(NSArray<WQLanPeer *> *peers);
- (void)start;
- (void)stop;
- (void)sendProbeNow;
@end

@implementation WQLanDiscoveryClient {
    int _udpFD;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    dispatch_source_t _probeTimer;
    NSMutableDictionary<NSString *, WQLanPeer *> *_peersByEndpoint;
    atomic_bool _running;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _udpFD = -1;
        _queue = dispatch_queue_create("com.wqglass.landiscovery.client", DISPATCH_QUEUE_SERIAL);
        _peersByEndpoint = [NSMutableDictionary new];
        atomic_init(&_running, false);
    }
    return self;
}

- (void)dealloc
{
    atomic_store(&_running, false);
    dispatch_source_t pt = _probeTimer;
    dispatch_source_t rs = _readSource;
    int fd = _udpFD;
    _probeTimer = nil;
    _readSource = nil;
    _udpFD = -1;
    if (pt) dispatch_source_cancel(pt);
    if (rs) dispatch_source_cancel(rs);
    else if (fd >= 0) close(fd);
}

- (void)start
{
    if (atomic_exchange(&_running, true)) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || !atomic_load(&me->_running)) return;

        if (me->_probeTimer) {
            dispatch_source_cancel(me->_probeTimer);
            me->_probeTimer = nil;
        }
        if (me->_readSource) {
            me->_udpFD = -1;
            dispatch_source_cancel(me->_readSource);
            me->_readSource = nil;
        } else if (me->_udpFD >= 0) {
            close(me->_udpFD);
            me->_udpFD = -1;
        }

        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) {
            atomic_store(&me->_running, false);
            return;
        }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kWQWinDiscoveryPort);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            // Unbound ephemeral socket still receives unicast replies to active probes.
        }
        me->_udpFD = fd;

        dispatch_source_t rs = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, me->_queue);
        dispatch_source_set_event_handler(rs, ^{
            __strong typeof(weakSelf) inner = weakSelf;
            if (!inner || !atomic_load(&inner->_running) || inner->_udpFD < 0) return;
            [inner drainIncomingPackets];
        });
        dispatch_source_set_cancel_handler(rs, ^{
            close(fd);
        });
        me->_readSource = rs;
        dispatch_resume(rs);

        dispatch_source_t pt = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, me->_queue);
        dispatch_source_set_timer(pt, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(pt, ^{
            __strong typeof(weakSelf) inner = weakSelf;
            if (!inner || !atomic_load(&inner->_running)) return;
            [inner sendProbeLocked];
            [inner pruneStaleLocked];
        });
        me->_probeTimer = pt;
        dispatch_resume(pt);
    });
}

- (void)stop
{
    if (!atomic_exchange(&_running, false)) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        if (me->_probeTimer) {
            dispatch_source_cancel(me->_probeTimer);
            me->_probeTimer = nil;
        }
        if (me->_readSource) {
            me->_udpFD = -1;
            dispatch_source_cancel(me->_readSource);
            me->_readSource = nil;
        } else if (me->_udpFD >= 0) {
            close(me->_udpFD);
            me->_udpFD = -1;
        }
    });
}

- (void)sendProbeNow
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || !atomic_load(&me->_running)) return;
        [me sendProbeLockedWithUnicastSweep:YES];
    });
}

- (void)sendProbeLocked
{
    [self sendProbeLockedWithUnicastSweep:NO];
}

- (void)sendProbeLockedWithUnicastSweep:(BOOL)unicastSweep
{
    if (_udpFD < 0) return;
    const char *probe = "WQGLASS_DISCOVER";
    size_t probeLen = strlen(probe);
    struct sockaddr_in bcast;
    memset(&bcast, 0, sizeof(bcast));
    bcast.sin_family = AF_INET;
    bcast.sin_port = htons(kWQWinDiscoveryPort);
    bcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(_udpFD, probe, probeLen, 0, (struct sockaddr *)&bcast, sizeof(bcast));

    NSString *myIP = wq_win_wifi_ipv4();
    NSArray<NSString *> *parts = [myIP componentsSeparatedByString:@"."];
    if (parts.count == 4) {
        NSString *prefix = [NSString stringWithFormat:@"%@.%@.%@", parts[0], parts[1], parts[2]];
        NSString *subBcast = [NSString stringWithFormat:@"%@.255", prefix];
        struct sockaddr_in sb;
        memset(&sb, 0, sizeof(sb));
        sb.sin_family = AF_INET;
        sb.sin_port = htons(kWQWinDiscoveryPort);
        if (inet_pton(AF_INET, subBcast.UTF8String, &sb.sin_addr) == 1) {
            sendto(_udpFD, probe, probeLen, 0, (struct sockaddr *)&sb, sizeof(sb));
        }
        if (unicastSweep) {
            NSInteger selfHost = parts[3].integerValue;
            for (int host = 1; host <= 254; host++) {
                if (host == selfHost) continue;
                NSString *targetIP = [NSString stringWithFormat:@"%@.%d", prefix, host];
                struct sockaddr_in uaddr;
                memset(&uaddr, 0, sizeof(uaddr));
                uaddr.sin_family = AF_INET;
                uaddr.sin_port = htons(kWQWinDiscoveryPort);
                if (inet_pton(AF_INET, targetIP.UTF8String, &uaddr.sin_addr) == 1) {
                    sendto(_udpFD, probe, probeLen, 0, (struct sockaddr *)&uaddr, sizeof(uaddr));
                }
            }
        }
    }
}

- (void)drainIncomingPackets
{
    char buf[2048];
    struct sockaddr_in peerAddr;
    for (int iter = 0; iter < 64; iter++) {
        socklen_t peerLen = sizeof(peerAddr);
        ssize_t n = recvfrom(_udpFD, buf, sizeof(buf) - 1, MSG_DONTWAIT, (struct sockaddr *)&peerAddr, &peerLen);
        if (n <= 0) break;
        buf[n] = '\0';

        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dict = (NSDictionary *)obj;
        if (![dict[@"app"] isKindOfClass:NSString.class] || ![dict[@"app"] isEqualToString:@"WQGlass"]) continue;

        NSString *ip = [dict[@"ip"] isKindOfClass:NSString.class] ? dict[@"ip"] : @"";
        if (!ip.length) {
            char ipStr[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &peerAddr.sin_addr, ipStr, sizeof(ipStr))) {
                ip = [NSString stringWithUTF8String:ipStr] ?: @"";
            }
        }
        if (!ip.length) continue;

        NSInteger rawPort = [dict[@"port"] respondsToSelector:@selector(integerValue)] ? [dict[@"port"] integerValue] : kWQWinBasePort;
        uint16_t port = (rawPort > 0 && rawPort <= 65535) ? (uint16_t)rawPort : kWQWinBasePort;

        // Filter out this iPhone's own active host server beacon.
        NSString *selfIP = self.ignoreIP;
        uint16_t selfPort = self.ignorePort;
        if (selfIP.length && selfPort > 0 && port == selfPort && [ip isEqualToString:selfIP]) {
            continue;
        }

        WQLanPeer *peer = [WQLanPeer new];
        peer.device = [dict[@"device"] isKindOfClass:NSString.class] ? dict[@"device"] : @"Device";
        peer.platform = [dict[@"platform"] isKindOfClass:NSString.class] ? dict[@"platform"] : @"ios";
        peer.osVersion = [dict[@"osVersion"] isKindOfClass:NSString.class] ? dict[@"osVersion"] : @"";
        peer.ip = ip;
        peer.port = port;
        peer.root = [dict[@"root"] isKindOfClass:NSString.class] ? dict[@"root"] : @"Downloads";
        peer.lastSeen = CFAbsoluteTimeGetCurrent();

        _peersByEndpoint[peer.endpoint] = peer;
        [self notifyPeersLocked];
    }
}

- (void)pruneStaleLocked
{
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSString *> *stale = [NSMutableArray new];
    for (NSString *key in _peersByEndpoint) {
        if (now - _peersByEndpoint[key].lastSeen > 12.0) {
            [stale addObject:key];
        }
    }
    if (stale.count) {
        [_peersByEndpoint removeObjectsForKeys:stale];
        [self notifyPeersLocked];
    }
}

- (void)notifyPeersLocked
{
    NSArray<WQLanPeer *> *sorted = [_peersByEndpoint.allValues sortedArrayUsingComparator:^NSComparisonResult(WQLanPeer *a, WQLanPeer *b) {
        return [a.device localizedCaseInsensitiveCompare:b.device];
    }];
    void (^cb)(NSArray<WQLanPeer *> *) = self.onPeersChanged;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(sorted);
    });
}

@end

#pragma mark - WQLanQRScannerViewController

@interface WQLanQRScannerViewController : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, copy, nullable) void (^onCodeScanned)(NSString *payload);
@end

@implementation WQLanQRScannerViewController {
    AVCaptureSession *_captureSession;
    AVCaptureVideoPreviewLayer *_previewLayer;
    BOOL _delivered;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.title = WQLocalized(@"Scan WQGlass QR Code");

    __weak typeof(self) weakSelf = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Cancel") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }]];

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        [self showCameraError:WQLocalized(@"Camera is not available on this device.")];
        return;
    }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
    if (!input) {
        [self showCameraError:err.localizedDescription ?: WQLocalized(@"Unable to open camera. Check Camera permission in Settings.")];
        return;
    }

    _captureSession = [AVCaptureSession new];
    if ([_captureSession canAddInput:input]) [_captureSession addInput:input];

    AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
    if ([_captureSession canAddOutput:output]) {
        [_captureSession addOutput:output];
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        if ([output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
            output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
        }
    }

    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_captureSession];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:_previewLayer];

    // Sleek cyan reticle frame
    UIView *reticle = [UIView new];
    reticle.translatesAutoresizingMaskIntoConstraints = NO;
    reticle.layer.borderColor = UIColor.systemTealColor.CGColor;
    reticle.layer.borderWidth = 2.5;
    reticle.layer.cornerRadius = 18.0;
    reticle.userInteractionEnabled = NO;
    [self.view addSubview:reticle];

    UILabel *hint = [UILabel new];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = WQLocalized(@"Point at the QR code on Windows PC, Android, or iPhone");
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.numberOfLines = 2;
    [self.view addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [reticle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [reticle.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [reticle.widthAnchor constraintEqualToConstant:240],
        [reticle.heightAnchor constraintEqualToConstant:240],
        [hint.topAnchor constraintEqualToAnchor:reticle.bottomAnchor constant:20],
        [hint.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [hint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];

    AVCaptureSession *session = _captureSession;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
    });
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _previewLayer.frame = self.view.bounds;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    AVCaptureSession *session = _captureSession;
    if (session.isRunning) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [session stopRunning];
        });
    }
}

- (void)showCameraError:(NSString *)msg
{
    UILabel *lbl = [UILabel new];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = msg;
    lbl.textColor = UIColor.whiteColor;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 0;
    [self.view addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [lbl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)captureOutput:(AVCaptureOutput *__unused)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *__unused)connection
{
    if (_delivered) return;
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj isKindOfClass:AVMetadataMachineReadableCodeObject.class]) {
            NSString *val = ((AVMetadataMachineReadableCodeObject *)obj).stringValue;
            if (val.length) {
                _delivered = YES;
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                AVCaptureSession *session = _captureSession;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [session stopRunning];
                });
                void (^cb)(NSString *) = self.onCodeScanned;
                [self dismissViewControllerAnimated:YES completion:^{
                    if (cb) cb(val);
                }];
                return;
            }
        }
    }
}

@end

#pragma mark - WQLanPeerBrowserViewController

@interface WQLanPeerBrowserViewController : UITableViewController <UIDocumentPickerDelegate, NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>
- (instancetype)initWithBaseURL:(NSString *)baseURL pin:(NSString *)pin deviceName:(NSString *)deviceName platformLabel:(NSString *)platformLabel rootLabel:(NSString *)rootLabel;
@end

@implementation WQLanPeerBrowserViewController {
    NSString *_baseURL;
    NSString *_pin;
    NSString *_deviceName;
    NSString *_platformLabel;
    NSString *_rootLabel;
    NSString *_currentPath;
    NSArray<WQLanRemoteItem *> *_allItems;
    NSArray<WQLanRemoteItem *> *_items;
    NSInteger _categoryFilter; // 0=All, 1=Folders, 2=Media, 3=Docs
    NSInteger _sortMode;       // 0=Name, 1=Size, 2=Newest
    BOOL _selecting;
    NSMutableSet<NSString *> *_selectedPaths;

    NSURLSession *_session;
    NSURLSessionTask *_activeTask;
    NSString *_activeFileName;
    NSTimeInterval _transferStartTime;
    NSMutableArray<NSURL *> *_uploadQueue;
    NSMutableArray<WQLanRemoteItem *> *_downloadQueue;
    NSUInteger _batchTotalCount;
    NSUInteger _batchDoneCount;
    BOOL _isDownloading;

    UIView *_progressHeader;
    UILabel *_progressTitleLabel;
    UILabel *_progressDetailLabel;
    UIProgressView *_progressBar;
}

- (instancetype)initWithBaseURL:(NSString *)baseURL pin:(NSString *)pin deviceName:(NSString *)deviceName platformLabel:(NSString *)platformLabel rootLabel:(NSString *)rootLabel
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _baseURL = [baseURL copy];
        _pin = [pin copy];
        _deviceName = deviceName.length ? [deviceName copy] : @"Remote Device";
        _platformLabel = platformLabel.length ? [platformLabel copy] : @"LAN";
        _rootLabel = rootLabel.length ? [rootLabel copy] : @"Shared";
        _currentPath = @"";
        _allItems = @[];
        _items = @[];
        _selectedPaths = [NSMutableSet new];
        _uploadQueue = [NSMutableArray new];
        _downloadQueue = [NSMutableArray new];
        self.title = [NSString stringWithFormat:@"%@ (%@)", _deviceName, _platformLabel];
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

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 3600.0;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:NSOperationQueue.mainQueue];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(refreshDirectory) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self rebuildNavButtons];
    [self buildProgressHeader];
    [self refreshDirectory];
}

- (void)rebuildNavButtons
{
    __weak typeof(self) weakSelf = self;
    if (_selecting) {
        UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Done") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf toggleSelectMode:NO];
        }]];
        UIBarButtonItem *batchBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Actions") image:[UIImage systemImageNamed:@"ellipsis.circle.fill"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf showSelectionBatchMenu];
        }]];
        self.navigationItem.rightBarButtonItems = @[doneBtn, batchBtn];
        return;
    }

    UIBarButtonItem *uploadBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Upload") image:[UIImage systemImageNamed:@"arrow.up.circle.fill"] identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf showUploadMenu];
    }]];
    UIBarButtonItem *moreBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"More") image:[UIImage systemImageNamed:@"ellipsis.circle"] identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf showBrowserToolsMenu];
    }]];
    self.navigationItem.rightBarButtonItems = @[moreBtn, uploadBtn];
}

- (void)toggleSelectMode:(BOOL)enabled
{
    wq_haptic_selection();
    _selecting = enabled;
    if (!enabled) [_selectedPaths removeAllObjects];
    [self rebuildNavButtons];
    [self.tableView reloadData];
}

- (void)showBrowserToolsMenu
{
    wq_haptic_selection();
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Explorer Tools"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Select Multiple Files…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self toggleSelectMode:YES];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Select All Files in Folder"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_selecting = YES;
        [self->_selectedPaths removeAllObjects];
        for (WQLanRemoteItem *it in self->_items) {
            if (!it.isDir) [self->_selectedPaths addObject:it.path];
        }
        [self rebuildNavButtons];
        [self.tableView reloadData];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"New Remote Folder…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptNewFolder];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Send Text / Link to Device…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptSendText];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Filter Category…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showFilterMenu];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Sort By…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showSortMenu];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSelectionBatchMenu
{
    wq_haptic_selection();
    NSMutableArray<WQLanRemoteItem *> *chosen = [NSMutableArray new];
    for (WQLanRemoteItem *it in _items) {
        if ([_selectedPaths containsObject:it.path]) [chosen addObject:it];
    }
    NSString *title = [NSString stringWithFormat:WQLocalized(@"%lu Selected"), (unsigned long)chosen.count];
    UIAlertController *sheet = wq_alert_controller(title, nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Select All"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        for (WQLanRemoteItem *it in self->_items) {
            if (!it.isDir) [self->_selectedPaths addObject:it.path];
        }
        [self.tableView reloadData];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Deselect All"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self->_selectedPaths removeAllObjects];
        [self.tableView reloadData];
    })];
    if (chosen.count) {
        [sheet addAction:wq_alert_action([NSString stringWithFormat:WQLocalized(@"Download %lu File(s) to Downloads"), (unsigned long)chosen.count], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self enqueueDownloads:chosen];
            [self toggleSelectMode:NO];
        })];
        [sheet addAction:wq_alert_action([NSString stringWithFormat:WQLocalized(@"Delete %lu Selected"), (unsigned long)chosen.count], UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            [self confirmBatchDelete:chosen];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showFilterMenu
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Filter Category"), nil, UIAlertControllerStyleActionSheet);
    NSArray<NSString *> *labels = @[WQLocalized(@"All Items"), WQLocalized(@"Folders Only"), WQLocalized(@"Videos / Photos / Audio"), WQLocalized(@"Documents & Archives")];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSInteger mode = (NSInteger)i;
        [sheet addAction:wq_alert_action(labels[i], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_categoryFilter = mode;
            [self applyFilterAndSort];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSortMenu
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Sort Items"), nil, UIAlertControllerStyleActionSheet);
    NSArray<NSString *> *labels = @[WQLocalized(@"Name (A–Z)"), WQLocalized(@"Size (Largest First)"), WQLocalized(@"Date Modified (Newest)")];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSInteger mode = (NSInteger)i;
        [sheet addAction:wq_alert_action(labels[i], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_sortMode = mode;
            [self applyFilterAndSort];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyFilterAndSort
{
    NSMutableArray<WQLanRemoteItem *> *filtered = [NSMutableArray new];
    NSSet<NSString *> *mediaExts = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"webm", @"jpg", @"jpeg", @"png", @"heic", @"gif", @"webp", @"mp3", @"m4a", @"wav", @"flac", @"aac"]];
    NSSet<NSString *> *docExts = [NSSet setWithArray:@[@"pdf", @"doc", @"docx", @"txt", @"md", @"csv", @"json", @"zip", @"rar", @"7z", @"apk", @"ipa"]];

    for (WQLanRemoteItem *it in _allItems) {
        if (_categoryFilter == 1 && !it.isDir) continue;
        if (_categoryFilter == 2 && (it.isDir || ![mediaExts containsObject:it.name.pathExtension.lowercaseString])) continue;
        if (_categoryFilter == 3 && (it.isDir || ![docExts containsObject:it.name.pathExtension.lowercaseString])) continue;
        [filtered addObject:it];
    }

    [filtered sortUsingComparator:^NSComparisonResult(WQLanRemoteItem *a, WQLanRemoteItem *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        if (self->_sortMode == 1) {
            if (a.size != b.size) return a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
        } else if (self->_sortMode == 2) {
            if (a.mtime != b.mtime) return a.mtime > b.mtime ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    _items = filtered;
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_activeTask cancel];
        [_session invalidateAndCancel];
        _session = nil;
        wq_lan_record_transfer_speed(0);
        wq_lan_record_client_connected(@"none", @"", @"", @"");
    }
}

- (void)dealloc
{
    [_session invalidateAndCancel];
}

- (void)buildProgressHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 108)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIVisualEffectView *card = wq_theme_make_glass_card(16.0, YES);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:card];

    _progressTitleLabel = [UILabel new];
    _progressTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _progressTitleLabel.textColor = wq_theme_primary_text();

    _progressDetailLabel = [UILabel new];
    _progressDetailLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _progressDetailLabel.textColor = wq_theme_secondary_text();

    _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressBar.tintColor = wq_theme_accent();

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:WQLocalized(@"Cancel") forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [cancelBtn addTarget:self action:@selector(cancelActiveTransfer) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[_progressTitleLabel, cancelBtn]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, _progressBar, _progressDetailLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [card.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
    ]];
    _progressHeader = box;
}

- (void)showProgress:(NSString *)title detail:(NSString *)detail fraction:(float)fraction
{
    _progressTitleLabel.text = title;
    _progressDetailLabel.text = detail;
    _progressBar.progress = fraction;
    if (self.tableView.tableHeaderView != _progressHeader) {
        self.tableView.tableHeaderView = _progressHeader;
    }
}

- (void)hideProgress
{
    wq_lan_record_transfer_speed(0);
    if (self.tableView.tableHeaderView == _progressHeader) {
        self.tableView.tableHeaderView = nil;
    }
}

- (NSMutableURLRequest *)requestForMethod:(NSString *)method relativePath:(NSString *)rel
{
    NSURL *url = [NSURL URLWithString:[_baseURL stringByAppendingString:rel]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    [req setValue:_pin forHTTPHeaderField:@"X-WQ-PIN"];
    BOOL isUsb = [_baseURL containsString:@"127.0.0.1"];
    [req setValue:(isUsb ? @"usb" : @"wifi") forHTTPHeaderField:@"X-WQ-TRANSPORT"];
    [req setValue:(UIDevice.currentDevice.name ?: @"iPhone") forHTTPHeaderField:@"X-WQ-CLIENT"];
    return req;
}

- (void)refreshDirectory
{
    if (!_session) return;
    NSString *rel = [NSString stringWithFormat:@"/api/list?path=%@", wq_win_query_encode(_currentPath)];
    NSMutableURLRequest *req = [self requestForMethod:@"GET" relativePath:rel];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me.refreshControl endRefreshing];
        if (error) {
            wq_log_error(@"TransferBrowser", @"List directory '%@' on %@ failed: %@", me->_currentPath ?: @"", me->_baseURL ?: @"", error.localizedDescription ?: error);
            wq_alert(me, WQLocalized(@"Connection Error"), error.localizedDescription ?: WQLocalized(@"Unable to reach remote device."));
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200 || !data.length) {
            wq_log_error(@"TransferBrowser", @"List directory '%@' on %@ returned HTTP %ld", me->_currentPath ?: @"", me->_baseURL ?: @"", (long)http.statusCode);
            wq_alert(me, WQLocalized(@"Request Failed"), [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
            return;
        }
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) return;
        NSArray *rawItems = [obj[@"items"] isKindOfClass:NSArray.class] ? obj[@"items"] : @[];
        NSMutableArray<WQLanRemoteItem *> *parsed = [NSMutableArray arrayWithCapacity:rawItems.count];
        for (id entry in rawItems) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *d = (NSDictionary *)entry;
            WQLanRemoteItem *it = [WQLanRemoteItem new];
            it.name = [d[@"name"] isKindOfClass:NSString.class] ? d[@"name"] : @"";
            it.path = [d[@"path"] isKindOfClass:NSString.class] ? d[@"path"] : @"";
            it.isDir = [d[@"isDir"] respondsToSelector:@selector(boolValue)] ? [d[@"isDir"] boolValue] : NO;
            it.size = [d[@"size"] respondsToSelector:@selector(longLongValue)] ? [d[@"size"] longLongValue] : 0;
            it.mtime = [d[@"mtime"] respondsToSelector:@selector(longLongValue)] ? [d[@"mtime"] longLongValue] : 0;
            if (it.name.length) [parsed addObject:it];
        }
        me->_allItems = parsed;
        [me->_selectedPaths removeAllObjects];
        [me applyFilterAndSort];
    }];
    [task resume];
}

- (void)cancelActiveTransfer
{
    [_uploadQueue removeAllObjects];
    [_downloadQueue removeAllObjects];
    [_activeTask cancel];
    _activeTask = nil;
    [self hideProgress];
}

- (void)enqueueDownloads:(NSArray<WQLanRemoteItem *> *)items
{
    if (!_session || !items.count) return;
    for (WQLanRemoteItem *it in items) {
        if (!it.isDir) [_downloadQueue addObject:it];
    }
    if (!_downloadQueue.count) return;
    if (!_activeTask) {
        _batchTotalCount = _downloadQueue.count;
        _batchDoneCount = 0;
        [self pumpNextDownload];
    }
}

- (void)pumpNextDownload
{
    if (!_session || _activeTask || !_downloadQueue.count) {
        if (!_activeTask && _batchDoneCount > 0) {
            NSUInteger done = _batchDoneCount;
            _batchDoneCount = 0;
            _batchTotalCount = 0;
            [self hideProgress];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Saved to Downloads"),
                     [NSString stringWithFormat:WQLocalized(@"Saved %lu file(s) into WQ Glass Downloads."), (unsigned long)done]);
        }
        return;
    }
    WQLanRemoteItem *item = _downloadQueue.firstObject;
    [_downloadQueue removeObjectAtIndex:0];

    NSString *rel = [NSString stringWithFormat:@"/api/download?path=%@", wq_win_query_encode(item.path)];
    NSMutableURLRequest *req = [self requestForMethod:@"GET" relativePath:rel];
    _activeFileName = item.name;
    _isDownloading = YES;
    _transferStartTime = CFAbsoluteTimeGetCurrent();
    [self showProgress:[NSString stringWithFormat:@"↓ (%lu/%lu) %@", (unsigned long)(_batchDoneCount + 1), (unsigned long)MAX(1UL, _batchTotalCount), item.name]
                detail:WQLocalized(@"Starting download…")
              fraction:0.0f];
    NSURLSessionDownloadTask *dt = [_session downloadTaskWithRequest:req];
    _activeTask = dt;
    [dt resume];
}

- (void)startDownloadItem:(WQLanRemoteItem *)item
{
    [self enqueueDownloads:@[item]];
}

- (void)showUploadMenu
{
    wq_haptic_selection();
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Send Files to Remote Device"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Pick from iOS Files App…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        picker.allowsMultipleSelection = YES;
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Pick from WQ Glass Downloads…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptLocalDownloadFileUpload];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptLocalDownloadFileUpload
{
    NSString *dir = wq_win_downloads_dir();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSString *> *files = [NSMutableArray new];
    for (NSString *n in names) {
        if ([n hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
            [files addObject:n];
        }
    }
    if (!files.count) {
        wq_alert(self, WQLocalized(@"Downloads Empty"), WQLocalized(@"No local files found in WQ Glass Downloads."));
        return;
    }
    [files sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Upload from WQ Glass Downloads"), nil, UIAlertControllerStyleActionSheet);
    NSUInteger limit = MIN(files.count, (NSUInteger)25);
    for (NSUInteger i = 0; i < limit; i++) {
        NSString *name = files[i];
        NSURL *u = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
        [sheet addAction:wq_alert_action(name, UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self enqueueUploadURLs:@[u]];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count) [self enqueueUploadURLs:urls];
}

- (void)enqueueUploadURLs:(NSArray<NSURL *> *)urls
{
    [_uploadQueue addObjectsFromArray:urls];
    if (!_activeTask) {
        _batchTotalCount = _uploadQueue.count;
        _batchDoneCount = 0;
        [self pumpNextUpload];
    }
}

- (void)pumpNextUpload
{
    if (!_session || _activeTask || !_uploadQueue.count) {
        if (!_activeTask) {
            _batchTotalCount = 0;
            _batchDoneCount = 0;
            [self hideProgress];
            [self refreshDirectory];
        }
        return;
    }
    NSURL *fileURL = _uploadQueue.firstObject;
    [_uploadQueue removeObjectAtIndex:0];

    NSString *name = fileURL.lastPathComponent ?: @"file.bin";
    NSString *rel = [NSString stringWithFormat:@"/api/upload?path=%@&name=%@",
                     wq_win_query_encode(_currentPath), wq_win_query_encode(name)];
    NSMutableURLRequest *req = [self requestForMethod:@"POST" relativePath:rel];
    [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

    _activeFileName = name;
    _isDownloading = NO;
    _transferStartTime = CFAbsoluteTimeGetCurrent();
    [self showProgress:[NSString stringWithFormat:@"↑ (%lu/%lu) %@", (unsigned long)(_batchDoneCount + 1), (unsigned long)MAX(1UL, _batchTotalCount), name]
                detail:WQLocalized(@"Starting upload…")
              fraction:0.0f];

    NSURLSessionUploadTask *ut = [_session uploadTaskWithRequest:req fromFile:fileURL];
    _activeTask = ut;
    [ut resume];
}

- (void)promptSendText
{
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Send Text / Link"),
                                               [NSString stringWithFormat:WQLocalized(@"Instantly copy a link or note to %@:"), _deviceName],
                                               UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Paste link or note…");
        NSString *clip = UIPasteboard.generalPasteboard.string;
        if (clip.length > 0 && clip.length < 1000) tf.text = clip;
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Send"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *txt = a.textFields.firstObject.text ?: @"";
        if (!txt.length || !self->_session) return;
        NSMutableURLRequest *req = [self requestForMethod:@"POST" relativePath:@"/api/text"];
        [req setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [txt dataUsingEncoding:NSUTF8StringEncoding];
        __weak typeof(self) weakSelf = self;
        [[self->_session dataTaskWithRequest:req completionHandler:^(NSData *__unused d, NSURLResponse *r, NSError *e) {
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
            if (!e && http.statusCode >= 200 && http.statusCode < 300) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(me, WQLocalized(@"Sent"), WQLocalized(@"Text/link sent to remote device."));
            } else {
                wq_alert(me, WQLocalized(@"Send Failed"), e.localizedDescription ?: WQLocalized(@"Remote device did not accept text."));
            }
        }] resume];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptNewFolder
{
    wq_haptic_selection();
    UIAlertController *a = wq_alert_controller(WQLocalized(@"New Remote Folder"), nil, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Folder name");
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Create"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        NSString *target = self->_currentPath.length ? [self->_currentPath stringByAppendingPathComponent:name] : name;
        NSString *rel = [NSString stringWithFormat:@"/api/mkdir?path=%@", wq_win_query_encode(target)];
        [self performSimplePost:rel];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptRenameItem:(WQLanRemoteItem *)item
{
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Rename Remote Item"), nil, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = item.name;
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Rename"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *newName = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!newName.length || [newName isEqualToString:item.name]) return;
        NSString *rel = [NSString stringWithFormat:@"/api/rename?path=%@&to=%@",
                         wq_win_query_encode(item.path), wq_win_query_encode(newName)];
        [self performSimplePost:rel];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmDeleteItem:(WQLanRemoteItem *)item
{
    [self confirmBatchDelete:@[item]];
}

- (void)confirmBatchDelete:(NSArray<WQLanRemoteItem *> *)items
{
    if (!items.count) return;
    NSString *msg = (items.count == 1)
        ? [NSString stringWithFormat:WQLocalized(@"Delete \"%@\" from %@?"), items.firstObject.name, _deviceName]
        : [NSString stringWithFormat:WQLocalized(@"Delete %lu selected item(s) from %@?"), (unsigned long)items.count, _deviceName];
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Delete Remote Item(s)?"), msg, UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Delete"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused act) {
        for (WQLanRemoteItem *it in items) {
            NSString *rel = [NSString stringWithFormat:@"/api/delete?path=%@", wq_win_query_encode(it.path)];
            [self performSimplePost:rel];
        }
        [self toggleSelectMode:NO];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)performSimplePost:(NSString *)rel
{
    if (!_session) return;
    NSMutableURLRequest *req = [self requestForMethod:@"POST" relativePath:rel];
    __weak typeof(self) weakSelf = self;
    [[_session dataTaskWithRequest:req completionHandler:^(NSData *__unused data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        if (error) {
            wq_log_error(@"TransferBrowser", @"POST %@ on %@ failed: %@", rel, me->_baseURL ?: @"", error.localizedDescription ?: error);
            wq_alert(me, WQLocalized(@"Operation Failed"), error.localizedDescription ?: WQLocalized(@"Network error"));
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode >= 200 && http.statusCode < 300) {
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            [me refreshDirectory];
        } else {
            wq_log_error(@"TransferBrowser", @"POST %@ on %@ returned HTTP %ld", rel, me->_baseURL ?: @"", (long)http.statusCode);
            wq_alert(me, WQLocalized(@"Operation Failed"), [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
        }
    }] resume];
}

#pragma mark - NSURLSession Delegates

- (void)URLSession:(NSURLSession *__unused)session
      downloadTask:(NSURLSessionDownloadTask *__unused)downloadTask
      didWriteData:(int64_t __unused)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    double elapsed = MAX(0.05, CFAbsoluteTimeGetCurrent() - _transferStartTime);
    double speed = (double)totalBytesWritten / elapsed;
    float frac = (totalBytesExpectedToWrite > 0) ? (float)((double)totalBytesWritten / (double)totalBytesExpectedToWrite) : 0.0f;
    NSString *detail = [NSString stringWithFormat:@"%@ / %@ · %@",
                        wq_size_text((unsigned long long)MAX(0LL, totalBytesWritten)),
                        totalBytesExpectedToWrite > 0 ? wq_size_text((unsigned long long)totalBytesExpectedToWrite) : @"--",
                        wq_win_speed_text(speed)];
    [self showProgress:[NSString stringWithFormat:@"↓ (%lu/%lu) %@", (unsigned long)(_batchDoneCount + 1), (unsigned long)MAX(1UL, _batchTotalCount), _activeFileName ?: @""]
                detail:detail
              fraction:frac];
}

- (void)URLSession:(NSURLSession *__unused)session
      downloadTask:(NSURLSessionDownloadTask *__unused)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSString *dst = wq_win_unique_upload_path(wq_win_downloads_dir(), _activeFileName ?: @"downloaded.bin");
    NSError *mvErr = nil;
    BOOL ok = [NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:dst] error:&mvErr];
    _activeTask = nil;
    if (ok) {
        wq_log(@"[TransferBrowser] Downloaded %@ to %@", _activeFileName ?: @"file", dst.lastPathComponent);
        _batchDoneCount++;
        [self pumpNextDownload];
    } else {
        [_downloadQueue removeAllObjects];
        [self hideProgress];
        wq_log_error(@"TransferBrowser", @"Save downloaded file '%@' failed: %@", _activeFileName ?: @"", mvErr.localizedDescription ?: mvErr);
        wq_alert(self, WQLocalized(@"Save Failed"), mvErr.localizedDescription ?: WQLocalized(@"Could not save file."));
    }
}

- (void)URLSession:(NSURLSession *__unused)session
              task:(NSURLSessionTask *__unused)task
   didSendBodyData:(int64_t __unused)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    double elapsed = MAX(0.05, CFAbsoluteTimeGetCurrent() - _transferStartTime);
    double speed = (double)totalBytesSent / elapsed;
    float frac = (totalBytesExpectedToSend > 0) ? (float)((double)totalBytesSent / (double)totalBytesExpectedToSend) : 0.0f;
    NSString *detail = [NSString stringWithFormat:@"%@ / %@ · %@",
                        wq_size_text((unsigned long long)MAX(0LL, totalBytesSent)),
                        totalBytesExpectedToSend > 0 ? wq_size_text((unsigned long long)totalBytesExpectedToSend) : @"--",
                        wq_win_speed_text(speed)];
    [self showProgress:[NSString stringWithFormat:@"↑ (%lu/%lu) %@", (unsigned long)(_batchDoneCount + 1), (unsigned long)MAX(1UL, _batchTotalCount), _activeFileName ?: @""]
                detail:detail
              fraction:frac];
}

- (void)URLSession:(NSURLSession *__unused)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    if (task != _activeTask) return;
    _activeTask = nil;
    if (error) {
        [_downloadQueue removeAllObjects];
        [_uploadQueue removeAllObjects];
        [self hideProgress];
        if (error.code != NSURLErrorCancelled) {
            wq_log_error(@"TransferBrowser", @"Transfer of '%@' on %@ failed: %@", _activeFileName ?: @"", _baseURL ?: @"", error.localizedDescription ?: error);
            wq_alert(self, WQLocalized(@"Transfer Error"), error.localizedDescription ?: WQLocalized(@"Transfer failed."));
        }
        return;
    }
    if (!_isDownloading) {
        NSHTTPURLResponse *http = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            [_uploadQueue removeAllObjects];
            [self hideProgress];
            wq_log_error(@"TransferBrowser", @"Upload of '%@' to %@ failed with HTTP %ld", _activeFileName ?: @"", _baseURL ?: @"", (long)http.statusCode);
            wq_alert(self, WQLocalized(@"Upload Failed"), [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
            return;
        }
        wq_log(@"[TransferBrowser] Uploaded %@ to %@", _activeFileName ?: @"file", _baseURL ?: @"");
        _batchDoneCount++;
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self pumpNextUpload];
    }
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger __unused)section
{
    NSString *base = _currentPath.length
        ? [NSString stringWithFormat:@"/%@/%@ (%lu)", _rootLabel, _currentPath, (unsigned long)_items.count]
        : [NSString stringWithFormat:@"/%@ (%lu)", _rootLabel, (unsigned long)_items.count];
    if (_selecting) {
        return [NSString stringWithFormat:@"%@ · %lu selected", base, (unsigned long)_selectedPaths.count];
    }
    return base;
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    NSInteger extra = _currentPath.length ? 1 : 0;
    return MAX(1, (NSInteger)_items.count + extra);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"peer-item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"peer-item"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();

    BOOL hasUp = _currentPath.length > 0;
    if (hasUp && indexPath.row == 0) {
        c.text = WQLocalized(@"↑ Parent Folder");
        c.secondaryText = _currentPath;
        c.image = [UIImage systemImageNamed:@"arrow.turn.up.left"];
        c.imageProperties.tintColor = wq_theme_accent();
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.contentConfiguration = c;
        return cell;
    }

    NSInteger idx = indexPath.row - (hasUp ? 1 : 0);
    if (idx < 0 || (NSUInteger)idx >= _items.count) {
        c.text = WQLocalized(@"Empty Folder");
        c.secondaryText = WQLocalized(@"Tap the upload icon above to send files here.");
        c.image = [UIImage systemImageNamed:@"tray"];
        c.imageProperties.tintColor = wq_theme_secondary_text();
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.contentConfiguration = c;
        return cell;
    }

    WQLanRemoteItem *it = _items[(NSUInteger)idx];
    c.text = it.name;
    c.secondaryText = it.isDir ? WQLocalized(@"Folder") : wq_size_text((unsigned long long)MAX(0LL, it.size));
    if (_selecting && !it.isDir) {
        BOOL checked = [_selectedPaths containsObject:it.path];
        c.image = [UIImage systemImageNamed:checked ? @"checkmark.circle.fill" : @"circle"];
        c.imageProperties.tintColor = checked ? wq_theme_accent() : wq_theme_secondary_text();
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        c.image = [UIImage systemImageNamed:it.isDir ? @"folder.fill" : @"doc.fill"];
        c.imageProperties.tintColor = it.isDir ? wq_theme_accent() : wq_theme_secondary_text();
        cell.accessoryType = it.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();

    BOOL hasUp = _currentPath.length > 0;
    if (hasUp && indexPath.row == 0) {
        NSRange slash = [_currentPath rangeOfString:@"/" options:NSBackwardsSearch];
        _currentPath = (slash.location != NSNotFound) ? [_currentPath substringToIndex:slash.location] : @"";
        [self refreshDirectory];
        return;
    }

    NSInteger idx = indexPath.row - (hasUp ? 1 : 0);
    if (idx < 0 || (NSUInteger)idx >= _items.count) return;
    WQLanRemoteItem *it = _items[(NSUInteger)idx];
    if (it.isDir) {
        _currentPath = it.path;
        [self refreshDirectory];
        return;
    }

    if (_selecting) {
        if ([_selectedPaths containsObject:it.path]) [_selectedPaths removeObject:it.path];
        else [_selectedPaths addObject:it.path];
        [self.tableView reloadData];
        return;
    }

    UIAlertController *sheet = wq_alert_controller(it.name, wq_size_text((unsigned long long)MAX(0LL, it.size)), UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Download to WQ Glass Downloads"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self startDownloadItem:it];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Rename…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptRenameItem:it];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Delete"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self confirmDeleteItem:it];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Global Connection Status Snapshot & Reusable Top Pill

static WQWinTransferServer *wq_shared_transfer_server(void)
{
    static WQWinTransferServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [WQWinTransferServer new];
    });
    return shared;
}

void wq_lan_transfer_ensure_background_server(void)
{
    WQWinTransferServer *srv = wq_shared_transfer_server();
    if (!srv.isRunning) {
        [srv startWithError:nil];
    }
}

WQLanTransferConnectionSnapshot *wq_lan_transfer_current_status(void)
{
    WQWinTransferServer *srv = wq_shared_transfer_server();
    WQLanTransferConnectionSnapshot *snap = [WQLanTransferConnectionSnapshot new];
    snap.serverRunning = srv.isRunning;
    snap.pinText = srv.pin ?: @"----";
    snap.rootLabel = srv.rootLabel ?: @"Downloads";
    if (srv.isRunning && srv.ipAddress.length) {
        snap.endpointText = [srv.ipAddress isEqualToString:@"127.0.0.1"]
            ? @"USB Cable Ready"
            : [NSString stringWithFormat:@"%@:%u", srv.ipAddress, (unsigned)srv.port];
    } else {
        snap.endpointText = @"Server Stopped";
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [gWQTransferStateLock() lock];
    if (now - gHostLastPeerSeen > 15.0 && ![gHostActiveTransport isEqualToString:@"none"]) {
        gHostActiveTransport = @"none";
        gHostActivePeerName = @"";
    }
    if (now - gActiveTransferBpsTime > 3.0) {
        gActiveTransferBps = 0;
    }
    NSString *hostTrans = [gHostActiveTransport copy];
    NSString *hostPeer = [gHostActivePeerName copy];
    NSString *cliTrans = [gClientActiveTransport copy];
    NSString *cliPeer = [gClientActivePeerName copy];
    NSString *cliEp = [gClientActiveEndpoint copy];
    NSString *cliRoot = [gClientActiveRoot copy];
    double bps = gActiveTransferBps;
    [gWQTransferStateLock() unlock];

    snap.activeBytesPerSec = bps;

    if ([hostTrans isEqualToString:@"usb"]) {
        snap.mode = WQLanConnectionModeConnectedUSB;
        snap.transport = @"usb";
        snap.peerName = hostPeer.length ? hostPeer : @"Windows PC";
    } else if ([cliTrans isEqualToString:@"usb"]) {
        snap.mode = WQLanConnectionModeConnectedUSB;
        snap.transport = @"usb";
        snap.peerName = cliPeer.length ? cliPeer : @"USB Device";
        snap.endpointText = cliEp;
        snap.rootLabel = cliRoot;
    } else if ([hostTrans isEqualToString:@"wifi"]) {
        snap.mode = WQLanConnectionModeConnectedWiFi;
        snap.transport = @"wifi";
        snap.peerName = hostPeer.length ? hostPeer : @"Remote Device";
    } else if ([cliTrans isEqualToString:@"wifi"]) {
        snap.mode = WQLanConnectionModeConnectedWiFi;
        snap.transport = @"wifi";
        snap.peerName = cliPeer.length ? cliPeer : @"Remote Device";
        snap.endpointText = cliEp;
        snap.rootLabel = cliRoot;
    } else if (srv.isRunning) {
        snap.mode = WQLanConnectionModeWaitingReady;
        snap.transport = @"none";
        snap.peerName = @"";
    } else {
        snap.mode = WQLanConnectionModeNotConnected;
        snap.transport = @"none";
        snap.peerName = @"";
    }
    return snap;
}

@interface WQLanGlobalStatusPillView : UIControl
@property (nonatomic, copy, nullable) void (^onTapHandler)(void);
- (void)refreshState;
@end

@implementation WQLanGlobalStatusPillView {
    UIView *_dotView;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subLabel;
    UILabel *_actionBadge;
    NSTimer *_heartbeatTimer;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 16.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.clipsToBounds = YES;

        _dotView = [UIView new];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        _dotView.layer.cornerRadius = 5.0;
        _dotView.userInteractionEnabled = NO;

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.userInteractionEnabled = NO;

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        _titleLabel.numberOfLines = 1;
        _titleLabel.userInteractionEnabled = NO;

        _subLabel = [UILabel new];
        _subLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightMedium];
        _subLabel.numberOfLines = 1;
        _subLabel.userInteractionEnabled = NO;

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subLabel]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 1.5;
        textStack.userInteractionEnabled = NO;

        _actionBadge = [UILabel new];
        _actionBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _actionBadge.textAlignment = NSTextAlignmentCenter;
        _actionBadge.layer.cornerRadius = 8.0;
        _actionBadge.clipsToBounds = YES;
        _actionBadge.userInteractionEnabled = NO;
        [_actionBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_actionBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_dotView, _iconView, textStack, _actionBadge]];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8.0;
        row.userInteractionEnabled = NO;
        [self addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [_dotView.widthAnchor constraintEqualToConstant:10],
            [_dotView.heightAnchor constraintEqualToConstant:10],
            [_iconView.widthAnchor constraintEqualToConstant:18],
            [_iconView.heightAnchor constraintEqualToConstant:18],
            [_actionBadge.widthAnchor constraintGreaterThanOrEqualToConstant:62],
            [_actionBadge.heightAnchor constraintEqualToConstant:24],
            [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        ]];

        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshState) name:WQLanTransferStatusDidChangeNotification object:nil];
        _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:2.5 target:self selector:@selector(refreshState) userInfo:nil repeats:YES];
        [self refreshState];
    }
    return self;
}

- (void)dealloc
{
    [_heartbeatTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleTap
{
    wq_haptic_selection();
    if (self.onTapHandler) self.onTapHandler();
}

- (void)refreshState
{
    WQLanTransferConnectionSnapshot *snap = wq_lan_transfer_current_status();
    UIColor *accent = nil;
    NSString *sym = @"bolt.horizontal.circle.fill";
    NSString *badgeText = @"Transfer →";

    switch (snap.mode) {
        case WQLanConnectionModeConnectedUSB:
            accent = UIColor.systemTealColor;
            sym = @"cable.connector.horizontal";
            badgeText = @"USB LIVE";
            break;
        case WQLanConnectionModeConnectedWiFi:
            accent = UIColor.systemGreenColor;
            sym = @"wifi";
            badgeText = @"Wi-Fi LIVE";
            break;
        case WQLanConnectionModeWaitingReady:
            accent = wq_theme_accent();
            sym = @"antenna.radiowaves.left.and.right";
            badgeText = @"USB / Wi-Fi";
            break;
        default:
            accent = UIColor.systemOrangeColor;
            sym = @"bolt.slash.fill";
            badgeText = @"Connect";
            break;
    }

    self.backgroundColor = [accent colorWithAlphaComponent:0.13];
    self.layer.borderColor = [accent colorWithAlphaComponent:0.42].CGColor;
    _dotView.backgroundColor = accent;
    _iconView.image = [UIImage systemImageNamed:sym] ?: [UIImage systemImageNamed:@"arrow.left.arrow.right.circle.fill"];
    _iconView.tintColor = accent;
    _titleLabel.text = [snap statusTitle];
    _titleLabel.textColor = wq_theme_primary_text();
    _subLabel.text = [snap statusSubtitle];
    _subLabel.textColor = wq_theme_secondary_text();
    _actionBadge.text = [NSString stringWithFormat:@"  %@  ", badgeText];
    _actionBadge.textColor = accent;
    _actionBadge.backgroundColor = [accent colorWithAlphaComponent:0.18];
}

@end

UIView *wq_lan_transfer_make_global_status_pill(void (^onTap)(void))
{
    wq_lan_transfer_ensure_background_server();
    WQLanGlobalStatusPillView *pill = [[WQLanGlobalStatusPillView alloc] initWithFrame:CGRectZero];
    pill.onTapHandler = onTap;
    return pill;
}

#pragma mark - WQWinTransferViewController

@interface WQWinTransferViewController () <UIDocumentPickerDelegate>
@end

@implementation WQWinTransferViewController {
    WQWinTransferServer *_server;
    WQLanDiscoveryClient *_discovery;
    NSArray<WQLanPeer *> *_peers;
    UISegmentedControl *_modeControl;
    NSInteger _mode; // 0 = Share iPhone (Wi-Fi), 1 = USB Cable Mode, 2 = Connect to Device
    NSString *_errorText;
    NSMutableArray<NSString *> *_logs;
    UIView *_heroHeader;
    UIView *_topConnectionPill;
    UIImageView *_qrView;
    UILabel *_pinLabel;
    UILabel *_addrLabel;
    UILabel *_statusLabel;
    UILabel *_transportBadgeLabel;
    UIBackgroundTaskIdentifier _bgTask;
    BOOL _wasRunningBeforeBackground;
}

- (instancetype)initWithInitialRootPath:(NSString *)rootPath title:(NSString *)rootTitle
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _server = wq_shared_transfer_server();
        if (rootPath.length) {
            _server.rootPath = rootPath;
            _server.rootLabel = rootTitle.length ? rootTitle : rootPath.lastPathComponent;
        }
        _discovery = [WQLanDiscoveryClient new];
        _peers = @[];
        _logs = [NSMutableArray new];
        _mode = 0;
        _bgTask = UIBackgroundTaskInvalid;
        _wasRunningBeforeBackground = NO;
        self.title = WQLocalized(@"USB & Wi-Fi Transfer");
        self.hidesBottomBarWhenPushed = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    }
    return self;
}

- (void)appendSessionLog:(NSString *)entry
{
    if (!entry.length) return;
    [_logs insertObject:entry atIndex:0];
    if (_logs.count > 60) [_logs removeLastObject];
    if (_mode == 0 || _mode == 1) [self.tableView reloadData];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    wq_theme_apply_scroll_insets(self.tableView, 40.0);

    _modeControl = [[UISegmentedControl alloc] initWithItems:@[
        WQLocalized(@"Wi-Fi Share"),
        WQLocalized(@"⚡ USB Cable"),
        WQLocalized(@"Connect Peer")
    ]];
    _modeControl.selectedSegmentIndex = 0;
    [_modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _modeControl;

    __weak typeof(self) weakSelf = self;
    _server.onActivity = ^(NSString *entry) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me appendSessionLog:entry];
        [me refreshHeader];
    };

    _server.onRootChanged = ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me refreshHeader];
        [me.tableView reloadData];
    };

    _discovery.onPeersChanged = ^(NSArray<WQLanPeer *> *peers) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        me->_peers = peers;
        if (me->_mode == 2) [me.tableView reloadData];
    };

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Done") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf dismissViewControllerAnimated:YES completion:nil];
        }]];
    }

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshHeader) name:WQLanTransferStatusDidChangeNotification object:nil];
    [self buildHeroHeader];
    if (!_server.isRunning) {
        [self startServer];
    } else {
        [self refreshHeader];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        [self endBackgroundKeepAliveTask];
        [_discovery stop];
    }
}

- (void)dealloc
{
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [self endBackgroundKeepAliveTask];
    [_discovery stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)endBackgroundKeepAliveTask
{
    if (_bgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }
}

- (void)appDidEnterBackground
{
    _wasRunningBeforeBackground = _server.isRunning;
    if (_server.isRunning && _bgTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        _bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"WQGlassTransferKeepAlive" expirationHandler:^{
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            [me->_server stop];
            [me->_discovery stop];
            [me refreshHeader];
            [me endBackgroundKeepAliveTask];
        }];
    }
}

- (void)appWillEnterForeground
{
    [self endBackgroundKeepAliveTask];
    if (_wasRunningBeforeBackground && !_server.isRunning) {
        [self startServer];
    } else {
        [self refreshHeader];
    }
    if (_mode == 2) {
        [_discovery start];
        [_discovery sendProbeNow];
    }
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    wq_haptic_selection();
    _mode = sender.selectedSegmentIndex;
    if (_mode == 0 || _mode == 1) {
        [_discovery stop];
        self.tableView.tableHeaderView = _heroHeader;
        [self refreshHeader];
    } else {
        _discovery.ignoreIP = _server.isRunning ? _server.ipAddress : nil;
        _discovery.ignorePort = _server.isRunning ? _server.port : 0;
        self.tableView.tableHeaderView = _heroHeader;
        [self refreshHeader];
        [_discovery start];
        [_discovery sendProbeNow];
    }
    [self.tableView reloadData];
}

- (void)startServer
{
    NSString *err = nil;
    if ([_server startWithError:&err]) {
        _errorText = nil;
    } else {
        _errorText = err;
    }
    _discovery.ignoreIP = _server.isRunning ? _server.ipAddress : nil;
    _discovery.ignorePort = _server.isRunning ? _server.port : 0;
    [self refreshHeader];
    [self.tableView reloadData];
}

- (void)buildHeroHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 344)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    __weak typeof(self) weakSelf = self;
    _topConnectionPill = wq_lan_transfer_make_global_status_pill(^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        if (!me->_server.isRunning) [me startServer];
    });

    UIVisualEffectView *card = wq_theme_make_glass_card(22.0, YES);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:_topConnectionPill];
    [box addSubview:card];

    _transportBadgeLabel = [UILabel new];
    _transportBadgeLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    _transportBadgeLabel.textAlignment = NSTextAlignmentCenter;
    _transportBadgeLabel.layer.cornerRadius = 8.0;
    _transportBadgeLabel.clipsToBounds = YES;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;

    _pinLabel = [UILabel new];
    _pinLabel.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightHeavy];
    _pinLabel.textColor = wq_theme_accent();
    _pinLabel.textAlignment = NSTextAlignmentCenter;

    _addrLabel = [UILabel new];
    _addrLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    _addrLabel.textColor = wq_theme_primary_text();
    _addrLabel.textAlignment = NSTextAlignmentCenter;
    _addrLabel.numberOfLines = 2;

    _qrView = [UIImageView new];
    _qrView.contentMode = UIViewContentModeScaleAspectFit;
    _qrView.backgroundColor = UIColor.whiteColor;
    _qrView.layer.cornerRadius = 12;
    _qrView.clipsToBounds = YES;
    _qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [_qrView.widthAnchor constraintEqualToConstant:118].active = YES;
    [_qrView.heightAnchor constraintEqualToConstant:118].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_transportBadgeLabel, _statusLabel, _pinLabel, _addrLabel, _qrView]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_topConnectionPill.topAnchor constraintEqualToAnchor:box.topAnchor constant:6],
        [_topConnectionPill.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [_topConnectionPill.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:_topConnectionPill.bottomAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [card.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
    ]];
    _heroHeader = box;
    self.tableView.tableHeaderView = _heroHeader;
}

- (void)refreshHeader
{
    if ([_topConnectionPill isKindOfClass:WQLanGlobalStatusPillView.class]) {
        [(WQLanGlobalStatusPillView *)_topConnectionPill refreshState];
    }
    WQLanTransferConnectionSnapshot *snap = wq_lan_transfer_current_status();

    if (snap.mode == WQLanConnectionModeConnectedUSB) {
        _transportBadgeLabel.text = [NSString stringWithFormat:@"  ⚡ ACTIVE TRANSPORT: USB CABLE (%@)  ", snap.peerName];
        _transportBadgeLabel.textColor = UIColor.systemTealColor;
        _transportBadgeLabel.backgroundColor = [UIColor.systemTealColor colorWithAlphaComponent:0.18];
    } else if (snap.mode == WQLanConnectionModeConnectedWiFi) {
        _transportBadgeLabel.text = [NSString stringWithFormat:@"  📶 ACTIVE TRANSPORT: WI-FI (%@)  ", snap.peerName];
        _transportBadgeLabel.textColor = UIColor.systemGreenColor;
        _transportBadgeLabel.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.18];
    } else if (_mode == 1) {
        _transportBadgeLabel.text = @"  🔌 USB CABLE TRANSFER MODE (LIKE 3UTOOLS / ITUNES)  ";
        _transportBadgeLabel.textColor = UIColor.systemTealColor;
        _transportBadgeLabel.backgroundColor = [UIColor.systemTealColor colorWithAlphaComponent:0.18];
    } else {
        _transportBadgeLabel.text = @"  ⚡ DUAL ENGINE: USB CABLE + WI-FI READY  ";
        _transportBadgeLabel.textColor = wq_theme_accent();
        _transportBadgeLabel.backgroundColor = [wq_theme_accent() colorWithAlphaComponent:0.16];
    }

    if (_server.isRunning && _server.ipAddress.length) {
        BOOL usbOnly = [_server.ipAddress isEqualToString:@"127.0.0.1"] || (_mode == 1);
        if (usbOnly) {
            _statusLabel.text = (snap.mode == WQLanConnectionModeConnectedUSB)
                ? [NSString stringWithFormat:@"● Connected to %@ via USB Cable · Sharing /%@", snap.peerName, _server.rootLabel]
                : WQLocalized(@"● USB Cable Ready · Plug into Windows PC (No PIN or Wi-Fi Needed!)");
            _statusLabel.textColor = UIColor.systemTealColor;
            _pinLabel.text = [NSString stringWithFormat:@"PIN  %@  (Auto-Paired on USB)", _server.pin];
            _addrLabel.text = [NSString stringWithFormat:@"USB Port %u · Sharing /%@ (App Containers & Docs Ready)", (unsigned)_server.port, _server.rootLabel ?: @"Downloads"];
            _qrView.hidden = YES;
        } else {
            NSString *urlStr = [NSString stringWithFormat:@"http://%@:%u", _server.ipAddress, (unsigned)_server.port];
            NSString *qrStr = [NSString stringWithFormat:@"%@/?pin=%@", urlStr, wq_win_query_encode(_server.pin)];
            _statusLabel.text = (snap.mode == WQLanConnectionModeConnectedWiFi)
                ? [NSString stringWithFormat:@"● Connected to %@ via Wi-Fi · Sharing /%@", snap.peerName, _server.rootLabel]
                : WQLocalized(@"● Live · Wi-Fi + USB Cable Ready (Windows, Android, or Browser)");
            _statusLabel.textColor = UIColor.systemGreenColor;
            _pinLabel.text = [NSString stringWithFormat:@"PIN  %@", _server.pin];
            _addrLabel.text = urlStr;
            _qrView.image = wq_win_qr_image(qrStr, 240.0);
            _qrView.hidden = NO;
        }
    } else {
        _statusLabel.text = _errorText ?: WQLocalized(@"Server Stopped");
        _statusLabel.textColor = UIColor.systemOrangeColor;
        _pinLabel.text = @"----";
        _addrLabel.text = WQLocalized(@"Tap Start Server below");
        _qrView.hidden = YES;
    }
}

- (NSUInteger)selectedOutboxCount
{
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:wq_win_selected_outbox_dir() error:nil] ?: @[];
    NSUInteger count = 0;
    for (NSString *n in names) {
        if (![n hasPrefix:@"."]) count++;
    }
    return count;
}

- (void)openOutboxDocumentPicker
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)clearSelectedOutbox
{
    NSString *dir = wq_win_selected_outbox_dir();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *n in names) {
        [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:n] error:nil];
    }
    [_logs insertObject:@"🧹 Cleared My Selected Files outbox" atIndex:0];
    if (_logs.count > 40) [_logs removeLastObject];
    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    [self.tableView reloadData];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    NSString *outbox = wq_win_selected_outbox_dir();
    NSUInteger added = 0;
    for (NSURL *u in urls) {
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSString *name = u.lastPathComponent.length ? u.lastPathComponent : @"shared_file";
        NSString *dst = wq_win_unique_upload_path(outbox, name);
        if (u.path.length && [NSFileManager.defaultManager copyItemAtPath:u.path toPath:dst error:nil]) {
            added++;
        }
        if (scoped) [u stopAccessingSecurityScopedResource];
    }
    if (added > 0) {
        _server.rootPath = outbox;
        _server.rootLabel = @"My Selected Files";
        NSString *entry = [NSString stringWithFormat:@"📤 Added %lu file(s) to My Selected Files — ready for PC!", (unsigned long)added];
        [_logs insertObject:entry atIndex:0];
        if (_logs.count > 40) [_logs removeLastObject];
        wq_lan_notify_status_changed();
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self refreshHeader];
        [self.tableView reloadData];
        wq_alert(self,
                 WQLocalized(@"Files Ready to Share"),
                 [NSString stringWithFormat:WQLocalized(@"Added %lu file(s) to \"My Selected Files\".\n\nOn Windows PC, click 🍎 Connect iPhone (USB) or connect via Wi-Fi and click \"My Selected Files\" to download them."), (unsigned long)added]);
    } else {
        wq_alert(self, WQLocalized(@"Could Not Add Files"), WQLocalized(@"Please try selecting those files again."));
    }
}

- (void)connectToEndpoint:(NSString *)endpoint pin:(NSString *)pin fallbackName:(NSString *)fallbackName fallbackPlatform:(NSString *)fallbackPlatform
{
    NSString *raw = [endpoint stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([raw hasSuffix:@"/"]) raw = [raw substringToIndex:raw.length - 1];
    NSString *clean = raw;
    if (![clean.lowercaseString hasPrefix:@"http://"] && ![clean.lowercaseString hasPrefix:@"https://"]) {
        clean = [@"http://" stringByAppendingString:clean];
    }
    NSURLComponents *comps = [NSURLComponents componentsWithString:clean];
    if (!comps.host.length) {
        wq_log_error(@"TransferClient", @"Invalid endpoint entered: '%@'", endpoint ?: @"");
        [self appendSessionLog:[NSString stringWithFormat:@"❌ Invalid endpoint: %@", endpoint ?: @""]];
        wq_alert(self, WQLocalized(@"Invalid Address"), WQLocalized(@"Enter a valid IP:Port such as 192.168.1.42:8765"));
        return;
    }

    NSString *host = comps.host;
    NSInteger initialPort = comps.port ? comps.port.integerValue : kWQWinBasePort;
    NSMutableArray<NSNumber *> *portsToTry = [NSMutableArray arrayWithObject:@(initialPort)];
    for (uint16_t p = kWQWinBasePort; p < kWQWinBasePort + 4; p++) {
        if ((NSInteger)p != initialPort) [portsToTry addObject:@(p)];
    }

    NSString *cleanPin = [pin stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *localIfaces = wq_win_all_network_interfaces_summary();
    wq_log(@"[TransferClient] Connecting to %@:%ld (PIN len=%lu · local ifaces: %@)", host, (long)initialPort, (unsigned long)cleanPin.length, localIfaces);
    [self appendSessionLog:[NSString stringWithFormat:@"→ Connecting to %@:%ld…", host, (long)initialPort]];

    [self tryConnectHost:host ports:portsToTry index:0 pin:cleanPin fallbackName:fallbackName fallbackPlatform:fallbackPlatform lastError:nil];
}

- (void)tryConnectHost:(NSString *)host
                 ports:(NSArray<NSNumber *> *)ports
                 index:(NSUInteger)idx
                   pin:(NSString *)cleanPin
          fallbackName:(NSString *)fallbackName
      fallbackPlatform:(NSString *)fallbackPlatform
             lastError:(NSError *)lastError
{
    if (idx >= ports.count) {
        NSInteger code = lastError.code;
        NSString *errDesc = lastError.localizedDescription ?: WQLocalized(@"Unable to reach target device.");
        NSString *ifaces = wq_win_all_network_interfaces_summary();
        wq_log_error(@"TransferClient", @"Connect failed to %@ (ports tried: %@) · error=%@ (domain=%@ code=%ld) · local ifaces: %@",
                     host, [ports componentsJoinedByString:@","], errDesc, lastError.domain ?: @"", (long)code, ifaces);
        [self appendSessionLog:[NSString stringWithFormat:@"❌ Connect failed to %@: %@ (code %ld)", host, errDesc, (long)code]];

        NSString *hint = nil;
        if (code == NSURLErrorCannotConnectToHost) {
            hint = [NSString stringWithFormat:WQLocalized(@"%@\n\nTarget %@ refused the connection. Make sure WQGlass Transfer is open on the Android/PC/iPhone and 'Start Sharing' (Share Device) is active."), errDesc, host];
        } else if (code == NSURLErrorTimedOut || code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost) {
            hint = [NSString stringWithFormat:WQLocalized(@"%@\n\nCould not reach %@.\n1. Check that both devices are on the same Wi-Fi or Mobile Hotspot.\n2. Verify Local Network permission is enabled in iOS Settings → Privacy & Security → Local Network → WQ Glass.\n3. If your Wi-Fi router has AP Isolation, turn on Mobile Hotspot on one phone and connect the other phone directly."), errDesc, host];
        } else {
            hint = [NSString stringWithFormat:@"%@ (code %ld)", errDesc, (long)code];
        }
        wq_alert(self, WQLocalized(@"Could Not Connect"), hint);
        return;
    }

    NSInteger port = ports[idx].integerValue;
    NSString *base = [NSString stringWithFormat:@"http://%@:%ld", host, (long)port];
    NSURL *infoURL = [NSURL URLWithString:[base stringByAppendingString:@"/api/info"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:infoURL];
    req.timeoutInterval = (idx == 0) ? 5.0 : 2.5;
    [req setValue:cleanPin forHTTPHeaderField:@"X-WQ-PIN"];
    BOOL isUsb = [host isEqualToString:@"127.0.0.1"];
    [req setValue:(isUsb ? @"usb" : @"wifi") forHTTPHeaderField:@"X-WQ-TRANSPORT"];
    [req setValue:(UIDevice.currentDevice.name ?: @"iPhone") forHTTPHeaderField:@"X-WQ-CLIENT"];

    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            if (error) {
                [me tryConnectHost:host ports:ports index:idx + 1 pin:cleanPin fallbackName:fallbackName fallbackPlatform:fallbackPlatform lastError:error];
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 401) {
                wq_log_error(@"TransferClient", @"PIN rejected (HTTP 401) by %@:%ld", host, (long)port);
                [me appendSessionLog:[NSString stringWithFormat:@"❌ Incorrect PIN for %@:%ld (HTTP 401)", host, (long)port]];
                wq_alert(me, WQLocalized(@"Incorrect PIN"), WQLocalized(@"Check the PIN shown on the target PC or phone and try again."));
                return;
            }
            if (http.statusCode != 200 || !data.length) {
                wq_log_error(@"TransferClient", @"Unexpected HTTP %ld from %@:%ld", (long)http.statusCode, host, (long)port);
                [me appendSessionLog:[NSString stringWithFormat:@"❌ HTTP %ld from %@:%ld", (long)http.statusCode, host, (long)port]];
                wq_alert(me, WQLocalized(@"Could Not Connect"), [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
                return;
            }
            NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *dev = ([info isKindOfClass:NSDictionary.class] && [info[@"device"] isKindOfClass:NSString.class]) ? info[@"device"] : fallbackName;
            NSString *plat = ([info isKindOfClass:NSDictionary.class] && [info[@"platform"] isKindOfClass:NSString.class]) ? info[@"platform"] : fallbackPlatform;
            NSString *root = ([info isKindOfClass:NSDictionary.class] && [info[@"root"] isKindOfClass:NSString.class]) ? info[@"root"] : @"Downloads";

            NSString *platLabel = [plat.lowercaseString isEqualToString:@"windows"] ? @"Windows"
                                : [plat.lowercaseString isEqualToString:@"android"] ? @"Android"
                                : @"iOS";

            NSString *resolvedEndpoint = [NSString stringWithFormat:@"%@:%ld", host, (long)port];
            [NSUserDefaults.standardUserDefaults setObject:resolvedEndpoint forKey:kWQWinLastEndpointPref];
            [NSUserDefaults.standardUserDefaults setObject:cleanPin forKey:kWQWinLastPinPref];
            wq_lan_record_client_connected(isUsb ? @"usb" : @"wifi", dev, resolvedEndpoint, root);
            wq_log(@"[TransferClient] Connected to %@ (%@) at %@ · /%@", dev, platLabel, resolvedEndpoint, root);
            [me appendSessionLog:[NSString stringWithFormat:@"✓ Connected to %@ (%@) at %@", dev, platLabel, resolvedEndpoint]];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);

            WQLanPeerBrowserViewController *browser = [[WQLanPeerBrowserViewController alloc] initWithBaseURL:base
                                                                                                          pin:cleanPin
                                                                                                   deviceName:dev
                                                                                                platformLabel:platLabel
                                                                                                    rootLabel:root];
            [me.navigationController pushViewController:browser animated:YES];
        });
    }] resume];
}

- (void)promptPinForPeer:(WQLanPeer *)peer
{
    NSString *title = [NSString stringWithFormat:WQLocalized(@"Connect to %@ (%@)"), peer.device, peer.platformBadge];
    UIAlertController *a = wq_alert_controller(title, peer.endpoint, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"4–8 Digit PIN");
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinLastPinPref] ?: @"";
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Connect"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *pin = a.textFields.firstObject.text ?: @"";
        [self connectToEndpoint:peer.endpoint pin:pin fallbackName:peer.device fallbackPlatform:peer.platform];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptManualConnect
{
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Connect to PC / Android / iPhone"),
                                               WQLocalized(@"Enter the Wi-Fi IP:Port and pairing PIN shown on the other device."),
                                               UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"192.168.1.42:8765";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.text = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinLastEndpointPref] ?: @"";
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"PIN (e.g. 4829)");
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinLastPinPref] ?: @"";
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Connect"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *ep = a.textFields.count > 0 ? (a.textFields[0].text ?: @"") : @"";
        NSString *pin = a.textFields.count > 1 ? (a.textFields[1].text ?: @"") : @"";
        [self connectToEndpoint:ep pin:pin fallbackName:@"Remote Device" fallbackPlatform:@"windows"];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)presentQRScanner
{
    WQLanQRScannerViewController *scanner = [WQLanQRScannerViewController new];
    __weak typeof(self) weakSelf = self;
    scanner.onCodeScanned = ^(NSString *payload) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me handleScannedQRPayload:payload];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scanner];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)handleScannedQRPayload:(NSString *)raw
{
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *comps = [NSURLComponents componentsWithString:trimmed];
    if (!comps.host.length) {
        NSString *prefixed = [@"http://" stringByAppendingString:trimmed];
        comps = [NSURLComponents componentsWithString:prefixed];
    }
    if (!comps.host.length) {
        wq_alert(self, WQLocalized(@"Invalid QR Code"), WQLocalized(@"This QR code is not a WQGlass Transfer address."));
        return;
    }
    NSInteger port = comps.port ? comps.port.integerValue : kWQWinBasePort;
    NSString *ep = [NSString stringWithFormat:@"%@:%ld", comps.host, (long)port];
    NSString *pin = nil;
    for (NSURLQueryItem *qi in comps.queryItems) {
        if ([qi.name.lowercaseString isEqualToString:@"pin"] && qi.value.length) {
            pin = qi.value;
            break;
        }
    }
    if (pin.length >= 4) {
        [self connectToEndpoint:ep pin:pin fallbackName:comps.host fallbackPlatform:@"windows"];
    } else {
        WQLanPeer *p = [WQLanPeer new];
        p.device = comps.host;
        p.ip = comps.host;
        p.port = (uint16_t)port;
        p.platform = @"windows";
        [self promptPinForPeer:p];
    }
}

- (NSString *)buildTransferDiagnosticReport
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *ver = info[@"CFBundleShortVersionString"] ?: @"4.0";
    NSString *bld = info[@"CFBundleVersion"] ?: @"1";
    NSString *dev = [NSString stringWithFormat:@"%@ · iOS %@", UIDevice.currentDevice.model ?: @"iPhone", UIDevice.currentDevice.systemVersion ?: @"26.0"];
    NSString *ifaces = wq_win_all_network_interfaces_summary();
    WQLanTransferConnectionSnapshot *snap = wq_lan_transfer_current_status();
    NSString *crashes = wq_crash_log_text();
    NSString *session = wq_log_text();
    NSString *xferLogs = _logs.count ? [_logs componentsJoinedByString:@"\n"] : @"(No recent transfer activity entries)";
    return [NSString stringWithFormat:
            @"==================================================================\n"
            @"WQ Glass (iOS) — Transfer, Error & Crash Diagnostic Report\n"
            @"==================================================================\n"
            @"App Version : %@ (%@)\n"
            @"Device      : %@\n"
            @"Server      : %@ (%@:%u · /%@)\n"
            @"Connection  : %@\n"
            @"Active IPs  : %@\n"
            @"==================================================================\n\n"
            @"--- PERSISTED CRASH & ERROR LOG ---\n%@\n\n"
            @"--- TRANSFER SESSION ACTIVITY ---\n%@\n\n"
            @"--- FULL APP DIAGNOSTIC LOG ---\n%@\n",
            ver, bld, dev,
            _server.isRunning ? @"Running" : @"Stopped",
            _server.ipAddress ?: @"127.0.0.1",
            (unsigned)_server.port,
            _server.rootLabel ?: @"Downloads",
            [snap statusTitle],
            ifaces,
            crashes.length ? crashes : @"None recorded",
            xferLogs,
            session.length ? session : @"None"];
}

- (void)presentDiagnosticLogsSheetFromSource:(UIView *)sourceView
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Diagnostic, Error & Crash Logs"),
                                                   WQLocalized(@"Copy or share the full diagnostic & crash report so any issue can be inspected and fixed immediately."),
                                                   UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Copy Full Log & Crash Report"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = [self buildTransferDiagnosticReport];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        wq_alert(self, WQLocalized(@"Logs Copied"), WQLocalized(@"Full diagnostic, error & crash report copied to clipboard."));
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Share Log File…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *report = [self buildTransferDiagnosticReport];
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[report] applicationActivities:nil];
        avc.popoverPresentationController.sourceView = sourceView ?: self.view;
        avc.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
        [self presentViewController:avc animated:YES completion:nil];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Clear Saved Logs & Crash History"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        wq_clear_logs();
        [self->_logs removeAllObjects];
        [self.tableView reloadData];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = sourceView ?: self.view;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_mode == 0 || _mode == 1) {
        if (section == 0) return 6;
        return MAX(1, (NSInteger)_logs.count);
    }
    if (section == 0) {
        return (NSInteger)_peers.count + 1;
    }
    return 3;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_mode == 0) {
        return (section == 0) ? WQLocalized(@"Wi-Fi & USB Transfer Controls") : WQLocalized(@"Live Transfer Activity (USB & Wi-Fi)");
    }
    if (_mode == 1) {
        return (section == 0) ? WQLocalized(@"⚡ USB Cable Mode (Like 3uTools / iTunes)") : WQLocalized(@"Live USB Cable Activity");
    }
    return (section == 0) ? WQLocalized(@"Nearby Devices on Wi-Fi (PC · Android · iOS)") : WQLocalized(@"QR, Manual & Diagnostics");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"win-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"win-row"];

    if (_mode == 0 || _mode == 1) {
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        c.textProperties.color = wq_theme_primary_text();
        c.secondaryTextProperties.color = wq_theme_secondary_text();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        if (indexPath.section == 0) {
            if (indexPath.row == 0) {
                c.text = (_mode == 1) ? WQLocalized(@"USB Shared Folder (App Containers / Docs)") : WQLocalized(@"Shared Folder");
                c.secondaryText = _server.rootLabel;
                c.image = [UIImage systemImageNamed:(_mode == 1) ? @"cable.connector.horizontal" : @"folder.fill"];
            } else if (indexPath.row == 1) {
                c.text = WQLocalized(@"Pick Files from iPhone to Share…");
                NSUInteger cnt = [self selectedOutboxCount];
                c.secondaryText = cnt > 0
                    ? [NSString stringWithFormat:@"%lu ready", (unsigned long)cnt]
                    : WQLocalized(@"Files / iCloud");
                c.image = [UIImage systemImageNamed:@"plus.rectangle.on.folder.fill"];
            } else if (indexPath.row == 2) {
                if (_mode == 1) {
                    c.text = WQLocalized(@"Switch USB to App Data Containers");
                    c.secondaryText = [_server.rootLabel isEqualToString:@"App Data"] ? WQLocalized(@"Active") : WQLocalized(@"All Apps");
                    c.image = [UIImage systemImageNamed:@"square.grid.2x2.fill"];
                } else {
                    c.text = WQLocalized(@"Copy Wi-Fi Address & PIN");
                    c.secondaryText = _server.isRunning ? _server.pin : @"--";
                    c.image = [UIImage systemImageNamed:@"doc.on.doc"];
                }
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else if (indexPath.row == 3) {
                c.text = WQLocalized(@"Set Fixed Pairing PIN…");
                NSString *fixed = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinFixedPinPref];
                c.secondaryText = fixed.length ? fixed : WQLocalized(@"Random");
                c.image = [UIImage systemImageNamed:@"key.fill"];
            } else if (indexPath.row == 4) {
                c.text = WQLocalized(@"Share / Copy Diagnostic & Crash Logs…");
                NSString *crashes = wq_crash_log_text();
                c.secondaryText = crashes.length ? WQLocalized(@"Has Crash/Error Log") : WQLocalized(@"Export");
                c.image = [UIImage systemImageNamed:@"ladybug.fill"];
            } else {
                c.text = _server.isRunning ? WQLocalized(@"Stop Transfer Server") : WQLocalized(@"Start Transfer Server");
                c.textProperties.color = _server.isRunning ? UIColor.systemRedColor : wq_theme_accent();
                c.image = [UIImage systemImageNamed:_server.isRunning ? @"stop.circle.fill" : @"play.circle.fill"];
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            c.imageProperties.tintColor = (indexPath.row == 1 || indexPath.row == 4 || _mode == 1) ? UIColor.systemTealColor : wq_theme_accent();
        } else {
            c = [UIListContentConfiguration subtitleCellConfiguration];
            if (!_logs.count) {
                if (_mode == 1) {
                    c.text = WQLocalized(@"⚡ USB Cable Mode Active — Plug iPhone into Windows PC");
                    c.secondaryText = WQLocalized(@"On Windows PC, open WQGlass Transfer and click '🍎 Connect iPhone (USB)' to browse all App Data Containers, Documents, Downloads, or My Selected Files at full USB cable speed (even with Wi-Fi OFF).");
                } else {
                    c.text = WQLocalized(@"Waiting for Windows PC (USB / Wi-Fi), Android, or Browser…");
                    c.secondaryText = WQLocalized(@"Tap 'Pick Files from iPhone to Share…' to choose files right from your screen, or plug into Windows PC & click 🍎 Connect iPhone (USB).");
                }
            } else {
                c.text = _logs[(NSUInteger)indexPath.row];
            }
            c.textProperties.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            c.textProperties.color = wq_theme_primary_text();
            c.secondaryTextProperties.color = wq_theme_secondary_text();
            c.secondaryTextProperties.numberOfLines = 3;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        cell.contentConfiguration = c;
        return cell;
    }

    // Mode 2: Client (Connect to Device)
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();

    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _peers.count) {
            WQLanPeer *p = _peers[(NSUInteger)indexPath.row];
            c.text = [NSString stringWithFormat:@"%@ · %@", p.device, p.platformBadge];
            c.secondaryText = [NSString stringWithFormat:@"%@ · /%@", p.endpoint, p.root];
            c.image = [UIImage systemImageNamed:p.symbolName];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            c.text = _peers.count ? WQLocalized(@"Scan Wi-Fi Again") : WQLocalized(@"Scanning Wi-Fi for PC, Android & iPhone…");
            c.secondaryText = WQLocalized(@"Make sure Host Mode is running on your Windows PC or Android app.");
            c.image = [UIImage systemImageNamed:@"dot.radiowaves.left.and.right"];
            c.imageProperties.tintColor = wq_theme_accent();
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else if (indexPath.row == 0) {
        c.text = WQLocalized(@"Scan QR Code to Connect…");
        c.secondaryText = WQLocalized(@"Instant pairing with Windows PC, Android, or another iPhone");
        c.image = [UIImage systemImageNamed:@"qrcode.viewfinder"];
        c.imageProperties.tintColor = UIColor.systemTealColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.row == 1) {
        c.text = WQLocalized(@"Connect by IP:Port & PIN…");
        NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinLastEndpointPref];
        c.secondaryText = last.length ? [NSString stringWithFormat:@"Last: %@", last] : WQLocalized(@"Example: 192.168.1.42:8765");
        c.image = [UIImage systemImageNamed:@"network"];
        c.imageProperties.tintColor = wq_theme_accent();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.text = WQLocalized(@"Share / Copy Diagnostic & Crash Logs…");
        c.secondaryText = WQLocalized(@"Export error & crash log if a connection fails");
        c.image = [UIImage systemImageNamed:@"ladybug.fill"];
        c.imageProperties.tintColor = UIColor.systemTealColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();

    if (_mode == 2) {
        if (indexPath.section == 0) {
            if ((NSUInteger)indexPath.row < _peers.count) {
                [self promptPinForPeer:_peers[(NSUInteger)indexPath.row]];
            } else {
                [_discovery sendProbeNow];
            }
        } else if (indexPath.row == 0) {
            [self presentQRScanner];
        } else if (indexPath.row == 1) {
            [self promptManualConnect];
        } else {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            [self presentDiagnosticLogsSheetFromSource:cell ?: self.view];
        }
        return;
    }

    if (indexPath.section != 0) return;

    if (indexPath.row == 0) {
        UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Choose Folder to Share (Wi-Fi & USB Cable)"), nil, UIAlertControllerStyleActionSheet);
        [sheet addAction:wq_alert_action(WQLocalized(@"App Data Containers (All Installed Apps · Like 3uTools)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = @"/private/var/mobile/Containers/Data/Application";
            self->_server.rootLabel = @"App Data";
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"WQ Glass Downloads (Videos / Audio / Files)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_downloads_dir();
            self->_server.rootLabel = @"Downloads";
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"WQ Glass Documents (All Saved Files)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_documents_dir();
            self->_server.rootLabel = @"Documents";
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"My Selected Files (Picked on iPhone)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_selected_outbox_dir();
            self->_server.rootLabel = @"My Selected Files";
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.row == 1) {
        NSUInteger cnt = [self selectedOutboxCount];
        UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Share Specific Files from iPhone"),
                                                       WQLocalized(@"Pick any files from Files, iCloud Drive, or On My iPhone so your PC can download them over USB cable or Wi-Fi."),
                                                       UIAlertControllerStyleActionSheet);
        [sheet addAction:wq_alert_action(WQLocalized(@"Pick Files from iPhone / iCloud Drive…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self openOutboxDocumentPicker];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Switch Shared Folder to My Selected Files"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_selected_outbox_dir();
            self->_server.rootLabel = @"My Selected Files";
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        if (cnt > 0) {
            [sheet addAction:wq_alert_action([NSString stringWithFormat:WQLocalized(@"Clear My Selected Files (%lu)"), (unsigned long)cnt], UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                [self clearSelectedOutbox];
            })];
        }
        [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.row == 2) {
        if (_mode == 1) {
            _server.rootPath = @"/private/var/mobile/Containers/Data/Application";
            _server.rootLabel = @"App Data";
            [self appendSessionLog:@"📦 Switched USB shared folder to App Data Containers (all installed apps)"];
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        } else if (_server.isRunning && _server.ipAddress.length) {
            NSString *copyText = [_server.ipAddress isEqualToString:@"127.0.0.1"]
                ? [NSString stringWithFormat:@"USB Cable Mode · PIN: %@", _server.pin]
                : [NSString stringWithFormat:@"http://%@:%u (PIN: %@)", _server.ipAddress, (unsigned)_server.port, _server.pin];
            UIPasteboard.generalPasteboard.string = copyText;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Copied"), WQLocalized(@"Transfer address & PIN copied to clipboard."));
        }
    } else if (indexPath.row == 3) {
        UIAlertController *a = wq_alert_controller(WQLocalized(@"Fixed Pairing PIN"),
                                                   WQLocalized(@"Enter a 4–8 digit PIN to reuse every time, or leave blank for a new random PIN."),
                                                   UIAlertControllerStyleAlert);
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinFixedPinPref] ?: @"";
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = @"4829";
        }];
        [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
        [a addAction:wq_alert_action(WQLocalized(@"Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
            NSString *val = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!val.length) {
                [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQWinFixedPinPref];
                self->_server.pin = wq_win_random_pin();
            } else if (val.length >= 4 && val.length <= 8) {
                [NSUserDefaults.standardUserDefaults setObject:val forKey:kWQWinFixedPinPref];
                self->_server.pin = val;
            } else {
                wq_alert(self, WQLocalized(@"Invalid PIN"), WQLocalized(@"PIN must be 4 to 8 digits."));
                return;
            }
            wq_lan_notify_status_changed();
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [self presentViewController:a animated:YES completion:nil];
    } else if (indexPath.row == 4) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [self presentDiagnosticLogsSheetFromSource:cell ?: self.view];
    } else {
        if (_server.isRunning) {
            [_server stop];
            _discovery.ignoreIP = nil;
            _discovery.ignorePort = 0;
            [self refreshHeader];
            [self.tableView reloadData];
        } else {
            [self startServer];
        }
    }
}

@end

void wq_present_windows_transfer(UIViewController *host, NSString *rootPath, NSString *title)
{
    if (!host) return;
    WQWinTransferViewController *vc = [[WQWinTransferViewController alloc] initWithInitialRootPath:rootPath title:title];
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }
}
