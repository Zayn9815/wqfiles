//
//  WQWinTransfer.m
//  WQ Glass
//
//  Ultra-fast iPhone <-> Windows Wi-Fi Transfer Server + UDP LAN Auto-Discovery (port 45888)
//  compatible with the WQGlass Transfer Windows desktop software and any PC browser.
//

#import "WQWinTransfer.h"
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

static NSString *const kWQWinFixedPinPref = @"WQWinTransferFixedPIN";
static NSString *const kWQWinLastEndpointPref = @"WQWinTransferLastEndpoint";
static NSString *const kWQWinLastPinPref = @"WQWinTransferLastPIN";
static const uint16_t kWQWinDiscoveryPort = 45888;
static const uint16_t kWQWinBasePort = 8765;
static const size_t kWQWinChunkBytes = 1024 * 1024;
static const int kWQWinSocketBufBytes = 4 * 1024 * 1024;
static const NSUInteger kWQWinMaxHeaderBytes = 16384;

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

static NSString *wq_win_wifi_ipv4(void)
{
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return nil;
    NSString *fallback = nil;
    NSString *wifi = nil;
    for (struct ifaddrs *cur = addrs; cur; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        if (!(cur->ifa_flags & IFF_UP) || (cur->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        NSString *name = cur->ifa_name ? [NSString stringWithUTF8String:cur->ifa_name] : @"";
        if ([name isEqualToString:@"en0"]) {
            wifi = ip;
            break;
        }
        if ([name hasPrefix:@"en"] || [name hasPrefix:@"bridge"]) {
            fallback = ip;
        }
    }
    freeifaddrs(addrs);
    return wifi ?: fallback;
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
    if (!self.onActivity || !line.length) return;
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
        if (!me || atomic_load(&me->_stopped) || me->_udpFD < 0) return;
        char buf[512];
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(me->_udpFD, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&peer, &peerLen);
        if (n > 0) {
            buf[n] = '\0';
            if (strstr(buf, "WQGLASS_DISCOVER") != NULL) {
                NSData *resp = [me discoveryBeaconJSON];
                if (resp.length) {
                    sendto(me->_udpFD, resp.bytes, resp.length, 0, (struct sockaddr *)&peer, peerLen);
                }
            }
        }
    });
    _udpReadSource = rs;
    dispatch_resume(rs);

    dispatch_source_t bt = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _netQueue);
    dispatch_source_set_timer(bt, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(bt, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || atomic_load(&me->_stopped) || me->_udpFD < 0) return;
        NSData *pkt = [me discoveryBeaconJSON];
        if (!pkt.length) return;
        struct sockaddr_in bcast;
        memset(&bcast, 0, sizeof(bcast));
        bcast.sin_family = AF_INET;
        bcast.sin_port = htons(kWQWinDiscoveryPort);
        bcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
        sendto(me->_udpFD, pkt.bytes, pkt.length, 0, (struct sockaddr *)&bcast, sizeof(bcast));
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
        if (errorOut) *errorOut = WQLocalized(@"Could not bind a local Wi-Fi / USB transfer port.");
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
        int cfd = accept(me->_listenFD, (struct sockaddr *)&cli, &cliLen);
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
    _acceptSource = acc;
    dispatch_resume(acc);

    if (wifiAvailable) {
        [self startUDPDiscovery];
    }
    return YES;
}

- (void)stop
{
    atomic_store(&_stopped, true);
    if (_beaconTimer) { dispatch_source_cancel(_beaconTimer); _beaconTimer = nil; }
    if (_udpReadSource) { dispatch_source_cancel(_udpReadSource); _udpReadSource = nil; }
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    if (_udpFD >= 0) { close(_udpFD); _udpFD = -1; }
    if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }
}

#pragma mark HTTP Request Handling

- (void)sendStatus:(int)code text:(NSString *)statusText contentType:(NSString *)ctype body:(NSData *)body toFD:(int)fd
{
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: X-WQ-PIN, Content-Type\r\nConnection: close\r\n\r\n",
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

    NSString *suppliedPin = headers[@"x-wq-pin"] ?: query[@"pin"] ?: @"";
    if (![suppliedPin isEqualToString:self.pin]) {
        [self sendJSON:@{ @"error": @"Invalid PIN" } status:401 toFD:fd];
        return;
    }

    NSString *root = self.rootPath ?: wq_win_downloads_dir();

    if ([route isEqualToString:@"/api/info"] && [method isEqualToString:@"GET"]) {
        struct statvfs stv;
        unsigned long long freeB = 0, totalB = 0;
        if (statvfs(root.fileSystemRepresentation, &stv) == 0) {
            freeB = (unsigned long long)stv.f_bavail * (unsigned long long)stv.f_frsize;
            totalB = (unsigned long long)stv.f_blocks * (unsigned long long)stv.f_frsize;
        }
        [self sendJSON:@{
            @"app": @"WQGlass",
            @"version": @"1.1",
            @"device": UIDevice.currentDevice.name ?: @"iPhone",
            @"platform": @"ios",
            @"osVersion": UIDevice.currentDevice.systemVersion ?: @"",
            @"ios": UIDevice.currentDevice.systemVersion ?: @"",
            @"root": self.rootLabel ?: @"Downloads",
            @"freeBytes": @(freeB),
            @"totalBytes": @(totalB),
        } status:200 toFD:fd];
        [self emitActivity:WQLocalized(@"Connected: Peer verified PIN")];
        return;
    }

    if ([route isEqualToString:@"/api/list"] && [method isEqualToString:@"GET"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target) {
            [self sendJSON:@{ @"error": @"Invalid path" } status:400 toFD:fd];
            return;
        }
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:target error:nil] ?: @[];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *name in names) {
            if ([name hasPrefix:@".wq"]) continue;
            NSString *full = [target stringByAppendingPathComponent:name];
            struct stat st;
            if (lstat(full.fileSystemRepresentation, &st) != 0) continue;
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
        struct stat st;
        if (!target || lstat(target.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
            [self sendJSON:@{ @"error": @"File not found" } status:404 toFD:fd];
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
        if (!wq_win_send_all(fd, hData.bytes, hData.length) || [method isEqualToString:@"HEAD"]) return;

        int ffd = open(target.fileSystemRepresentation, O_RDONLY);
        if (ffd < 0) return;
        if (start > 0) lseek(ffd, (off_t)start, SEEK_SET);
        uint8_t *chunk = (uint8_t *)malloc(kWQWinChunkBytes);
        if (chunk) {
            int64_t rem = sendLen;
            while (rem > 0 && !atomic_load(&_stopped)) {
                size_t toRead = (size_t)MIN((int64_t)kWQWinChunkBytes, rem);
                ssize_t nr = read(ffd, chunk, toRead);
                if (nr <= 0) break;
                if (!wq_win_send_all(fd, chunk, (size_t)nr)) break;
                rem -= (int64_t)nr;
            }
            free(chunk);
        }
        close(ffd);
        [self emitActivity:[NSString stringWithFormat:@"→ Sent to PC: %@ (%@)", target.lastPathComponent, wq_size_text((unsigned long long)fileSize)]];
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
        [NSFileManager.defaultManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
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
        NSString *finalPath = wq_win_unique_upload_path(dirPath, fileName);
        NSString *tmpPath = [dirPath stringByAppendingPathComponent:[NSString stringWithFormat:@".wq-win-%@", NSUUID.UUID.UUIDString]];
        int outFD = open(tmpPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (outFD < 0) {
            [self sendJSON:@{ @"error": @"Cannot write to folder" } status:500 toFD:fd];
            return;
        }
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
        }
        if (chunk) free(chunk);
        fsync(outFD);
        close(outFD);

        if (!ok || written != expected) {
            unlink(tmpPath.fileSystemRepresentation);
            [self sendJSON:@{ @"error": @"Incomplete upload" } status:500 toFD:fd];
            return;
        }
        if (rename(tmpPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) != 0) {
            unlink(tmpPath.fileSystemRepresentation);
            [self sendJSON:@{ @"error": @"Could not finalize upload" } status:500 toFD:fd];
            return;
        }
        [self sendJSON:@{ @"ok": @YES, @"name": finalPath.lastPathComponent, @"bytes": @(written) } status:200 toFD:fd];
        [self emitActivity:[NSString stringWithFormat:@"← Received from PC: %@ (%@)", finalPath.lastPathComponent, wq_size_text((unsigned long long)written)]];
        return;
    }

    if ([route isEqualToString:@"/api/mkdir"] && [method isEqualToString:@"POST"]) {
        NSString *rel = query[@"path"] ?: @"";
        NSString *target = wq_win_safe_resolve(root, rel);
        if (!target || [target isEqualToString:root.stringByStandardizingPath]) {
            [self sendJSON:@{ @"error": @"Invalid folder path" } status:400 toFD:fd];
            return;
        }
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:&err];
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"+ Created folder: %@", target.lastPathComponent]];
        } else {
            [self sendJSON:@{ @"error": err.localizedDescription ?: @"Could not create folder" } status:500 toFD:fd];
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
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager removeItemAtPath:target error:&err];
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"× Deleted: %@", target.lastPathComponent]];
        } else {
            [self sendJSON:@{ @"error": err.localizedDescription ?: @"Delete failed" } status:500 toFD:fd];
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
        NSString *dst = [src.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName];
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager moveItemAtPath:src toPath:dst error:&err];
        if (ok) {
            [self sendJSON:@{ @"ok": @YES } status:200 toFD:fd];
            [self emitActivity:[NSString stringWithFormat:@"✎ Renamed to: %@", newName]];
        } else {
            [self sendJSON:@{ @"error": err.localizedDescription ?: @"Rename failed" } status:500 toFD:fd];
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
        [self emitActivity:[NSString stringWithFormat:@"📂 PC switched shared folder → %@", self.rootLabel]];
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
    [self stop];
}

- (void)start
{
    if (atomic_exchange(&_running, true)) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || !atomic_load(&me->_running)) return;

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
    atomic_store(&_running, false);
    dispatch_async(_queue, ^{
        if (self->_probeTimer) {
            dispatch_source_cancel(self->_probeTimer);
            self->_probeTimer = nil;
        }
        if (self->_readSource) {
            dispatch_source_cancel(self->_readSource);
            self->_readSource = nil;
        }
        if (self->_udpFD >= 0) {
            close(self->_udpFD);
            self->_udpFD = -1;
        }
    });
}

- (void)sendProbeNow
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me || !atomic_load(&me->_running)) return;
        [me sendProbeLocked];
    });
}

- (void)sendProbeLocked
{
    if (_udpFD < 0) return;
    const char *probe = "WQGLASS_DISCOVER";
    struct sockaddr_in bcast;
    memset(&bcast, 0, sizeof(bcast));
    bcast.sin_family = AF_INET;
    bcast.sin_port = htons(kWQWinDiscoveryPort);
    bcast.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(_udpFD, probe, strlen(probe), 0, (struct sockaddr *)&bcast, sizeof(bcast));
}

- (void)drainIncomingPackets
{
    char buf[2048];
    struct sockaddr_in peerAddr;
    socklen_t peerLen = sizeof(peerAddr);
    ssize_t n = recvfrom(_udpFD, buf, sizeof(buf) - 1, MSG_DONTWAIT, (struct sockaddr *)&peerAddr, &peerLen);
    if (n <= 0) return;
    buf[n] = '\0';

    NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = (NSDictionary *)obj;
    if (![dict[@"app"] isKindOfClass:NSString.class] || ![dict[@"app"] isEqualToString:@"WQGlass"]) return;

    NSString *ip = [dict[@"ip"] isKindOfClass:NSString.class] ? dict[@"ip"] : @"";
    if (!ip.length) {
        char ipStr[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &peerAddr.sin_addr, ipStr, sizeof(ipStr))) {
            ip = [NSString stringWithUTF8String:ipStr] ?: @"";
        }
    }
    if (!ip.length) return;

    NSInteger rawPort = [dict[@"port"] respondsToSelector:@selector(integerValue)] ? [dict[@"port"] integerValue] : kWQWinBasePort;
    uint16_t port = (rawPort > 0 && rawPort <= 65535) ? (uint16_t)rawPort : kWQWinBasePort;

    // Filter out this iPhone's own active host server beacon.
    NSString *selfIP = self.ignoreIP;
    uint16_t selfPort = self.ignorePort;
    if (selfIP.length && selfPort > 0 && port == selfPort && [ip isEqualToString:selfIP]) {
        return;
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
            wq_alert(me, WQLocalized(@"Connection Error"), error.localizedDescription ?: WQLocalized(@"Unable to reach remote device."));
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200 || !data.length) {
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
            wq_alert(me, WQLocalized(@"Operation Failed"), error.localizedDescription ?: WQLocalized(@"Network error"));
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode >= 200 && http.statusCode < 300) {
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            [me refreshDirectory];
        } else {
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
        _batchDoneCount++;
        [self pumpNextDownload];
    } else {
        [_downloadQueue removeAllObjects];
        [self hideProgress];
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
            wq_alert(self, WQLocalized(@"Transfer Error"), error.localizedDescription ?: WQLocalized(@"Transfer failed."));
        }
        return;
    }
    if (!_isDownloading) {
        NSHTTPURLResponse *http = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            [_uploadQueue removeAllObjects];
            [self hideProgress];
            wq_alert(self, WQLocalized(@"Upload Failed"), [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
            return;
        }
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

#pragma mark - WQWinTransferViewController

@interface WQWinTransferViewController () <UIDocumentPickerDelegate>
@end

@implementation WQWinTransferViewController {
    WQWinTransferServer *_server;
    WQLanDiscoveryClient *_discovery;
    NSArray<WQLanPeer *> *_peers;
    UISegmentedControl *_modeControl;
    NSInteger _mode; // 0 = Host (Share iPhone), 1 = Client (Connect to PC / Android / iPhone)
    NSString *_errorText;
    NSMutableArray<NSString *> *_logs;
    UIView *_heroHeader;
    UIImageView *_qrView;
    UILabel *_pinLabel;
    UILabel *_addrLabel;
    UILabel *_statusLabel;
}

- (instancetype)initWithInitialRootPath:(NSString *)rootPath title:(NSString *)rootTitle
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _server = [WQWinTransferServer new];
        if (rootPath.length) {
            _server.rootPath = rootPath;
            _server.rootLabel = rootTitle.length ? rootTitle : rootPath.lastPathComponent;
        }
        _discovery = [WQLanDiscoveryClient new];
        _peers = @[];
        _logs = [NSMutableArray new];
        _mode = 0;
        self.title = WQLocalized(@"LAN Transfer");
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

    _modeControl = [[UISegmentedControl alloc] initWithItems:@[WQLocalized(@"Share iPhone"), WQLocalized(@"Connect to Device")]];
    _modeControl.selectedSegmentIndex = 0;
    [_modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _modeControl;

    __weak typeof(self) weakSelf = self;
    _server.onActivity = ^(NSString *entry) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me->_logs insertObject:entry atIndex:0];
        if (me->_logs.count > 40) [me->_logs removeLastObject];
        if (me->_mode == 0) [me.tableView reloadData];
    };

    _server.onRootChanged = ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        if (me->_mode == 0) [me.tableView reloadData];
    };

    _discovery.onPeersChanged = ^(NSArray<WQLanPeer *> *peers) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        me->_peers = peers;
        if (me->_mode == 1) [me.tableView reloadData];
    };

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Done") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf dismissViewControllerAnimated:YES completion:nil];
        }]];
    }

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self buildHeroHeader];
    [self startServer];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_server stop];
        [_discovery stop];
    }
}

- (void)dealloc
{
    [_server stop];
    [_discovery stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)appDidEnterBackground
{
    [_server stop];
    [_discovery stop];
    [self refreshHeader];
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    wq_haptic_selection();
    _mode = sender.selectedSegmentIndex;
    if (_mode == 0) {
        [_discovery stop];
        self.tableView.tableHeaderView = _heroHeader;
        [self refreshHeader];
    } else {
        _discovery.ignoreIP = _server.isRunning ? _server.ipAddress : nil;
        _discovery.ignorePort = _server.isRunning ? _server.port : 0;
        self.tableView.tableHeaderView = nil;
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
    if (_mode == 0) [self.tableView reloadData];
}

- (void)buildHeroHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 286)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIVisualEffectView *card = wq_theme_make_glass_card(22.0, YES);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:card];

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;

    _pinLabel = [UILabel new];
    _pinLabel.font = [UIFont monospacedDigitSystemFontOfSize:34 weight:UIFontWeightHeavy];
    _pinLabel.textColor = wq_theme_accent();
    _pinLabel.textAlignment = NSTextAlignmentCenter;

    _addrLabel = [UILabel new];
    _addrLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    _addrLabel.textColor = wq_theme_primary_text();
    _addrLabel.textAlignment = NSTextAlignmentCenter;

    _qrView = [UIImageView new];
    _qrView.contentMode = UIViewContentModeScaleAspectFit;
    _qrView.backgroundColor = UIColor.whiteColor;
    _qrView.layer.cornerRadius = 12;
    _qrView.clipsToBounds = YES;
    _qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [_qrView.widthAnchor constraintEqualToConstant:124].active = YES;
    [_qrView.heightAnchor constraintEqualToConstant:124].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_statusLabel, _pinLabel, _addrLabel, _qrView]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [card.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
    ]];
    _heroHeader = box;
    self.tableView.tableHeaderView = _heroHeader;
}

- (void)refreshHeader
{
    if (_server.isRunning && _server.ipAddress.length) {
        BOOL usbOnly = [_server.ipAddress isEqualToString:@"127.0.0.1"];
        if (usbOnly) {
            _statusLabel.text = WQLocalized(@"● USB Cable Ready · Plug into Windows PC & click 🍎 iPhone App Docs (USB)");
            _statusLabel.textColor = UIColor.systemTealColor;
            _pinLabel.text = [NSString stringWithFormat:@"PIN  %@", _server.pin];
            _addrLabel.text = WQLocalized(@"USB Cable Mode (Wi-Fi Off · Direct Lightning / USB-C)");
            _qrView.hidden = YES;
        } else {
            NSString *urlStr = [NSString stringWithFormat:@"http://%@:%u", _server.ipAddress, (unsigned)_server.port];
            NSString *qrStr = [NSString stringWithFormat:@"%@/?pin=%@", urlStr, wq_win_query_encode(_server.pin)];
            _statusLabel.text = WQLocalized(@"● Live · Wi-Fi + USB Cable Ready (Windows, Android, or Browser)");
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
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        [self.tableView reloadData];
        wq_alert(self,
                 WQLocalized(@"Files Ready to Share"),
                 [NSString stringWithFormat:WQLocalized(@"Added %lu file(s) to \"My Selected Files\".\n\nOn Windows PC, click 🍎 iPhone App Docs (USB) or connect via Wi-Fi and click \"My Selected Files\" to download them."), (unsigned long)added]);
    } else {
        wq_alert(self, WQLocalized(@"Could Not Add Files"), WQLocalized(@"Please try selecting those files again."));
    }
}

- (void)connectToEndpoint:(NSString *)endpoint pin:(NSString *)pin fallbackName:(NSString *)fallbackName fallbackPlatform:(NSString *)fallbackPlatform
{
    NSString *clean = [endpoint stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([clean hasSuffix:@"/"]) clean = [clean substringToIndex:clean.length - 1];
    if (![clean.lowercaseString hasPrefix:@"http://"] && ![clean.lowercaseString hasPrefix:@"https://"]) {
        clean = [@"http://" stringByAppendingString:clean];
    }
    NSString *cleanPin = [pin stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *infoURL = [NSURL URLWithString:[clean stringByAppendingString:@"/api/info"]];
    if (!infoURL) {
        wq_alert(self, WQLocalized(@"Invalid Address"), WQLocalized(@"Enter a valid IP:Port such as 192.168.1.42:8765"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:infoURL];
    req.timeoutInterval = 8.0;
    [req setValue:cleanPin forHTTPHeaderField:@"X-WQ-PIN"];

    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            if (error) {
                wq_alert(me, WQLocalized(@"Could Not Connect"), error.localizedDescription ?: WQLocalized(@"Check that both devices are on the same Wi-Fi."));
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 401) {
                wq_alert(me, WQLocalized(@"Incorrect PIN"), WQLocalized(@"Check the PIN shown on the target PC or phone and try again."));
                return;
            }
            if (http.statusCode != 200 || !data.length) {
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

            [NSUserDefaults.standardUserDefaults setObject:endpoint forKey:kWQWinLastEndpointPref];
            [NSUserDefaults.standardUserDefaults setObject:cleanPin forKey:kWQWinLastPinPref];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);

            WQLanPeerBrowserViewController *browser = [[WQLanPeerBrowserViewController alloc] initWithBaseURL:clean
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

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_mode == 0) {
        if (section == 0) return 5;
        return MAX(1, (NSInteger)_logs.count);
    }
    if (section == 0) {
        return (NSInteger)_peers.count + 1;
    }
    return 2;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_mode == 0) {
        return (section == 0) ? WQLocalized(@"Transfer Controls (Wi-Fi & USB Cable)") : WQLocalized(@"Live Transfer Activity");
    }
    return (section == 0) ? WQLocalized(@"Nearby Devices on Wi-Fi (PC · Android · iOS)") : WQLocalized(@"QR & Manual Connection");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"win-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"win-row"];

    if (_mode == 0) {
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        c.textProperties.color = wq_theme_primary_text();
        c.secondaryTextProperties.color = wq_theme_secondary_text();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        if (indexPath.section == 0) {
            if (indexPath.row == 0) {
                c.text = WQLocalized(@"Shared Folder");
                c.secondaryText = _server.rootLabel;
                c.image = [UIImage systemImageNamed:@"folder.fill"];
            } else if (indexPath.row == 1) {
                c.text = WQLocalized(@"Pick Files from iPhone to Share…");
                NSUInteger cnt = [self selectedOutboxCount];
                c.secondaryText = cnt > 0
                    ? [NSString stringWithFormat:@"%lu ready", (unsigned long)cnt]
                    : WQLocalized(@"Files / iCloud");
                c.image = [UIImage systemImageNamed:@"plus.rectangle.on.folder.fill"];
            } else if (indexPath.row == 2) {
                c.text = WQLocalized(@"Copy Wi-Fi Address & PIN");
                c.secondaryText = _server.isRunning ? _server.pin : @"--";
                c.image = [UIImage systemImageNamed:@"doc.on.doc"];
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else if (indexPath.row == 3) {
                c.text = WQLocalized(@"Set Fixed Pairing PIN…");
                NSString *fixed = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinFixedPinPref];
                c.secondaryText = fixed.length ? fixed : WQLocalized(@"Random");
                c.image = [UIImage systemImageNamed:@"key.fill"];
            } else {
                c.text = _server.isRunning ? WQLocalized(@"Stop Transfer Server") : WQLocalized(@"Start Transfer Server");
                c.textProperties.color = _server.isRunning ? UIColor.systemRedColor : wq_theme_accent();
                c.image = [UIImage systemImageNamed:_server.isRunning ? @"stop.circle.fill" : @"play.circle.fill"];
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            c.imageProperties.tintColor = (indexPath.row == 1) ? UIColor.systemTealColor : wq_theme_accent();
        } else {
            c = [UIListContentConfiguration subtitleCellConfiguration];
            if (!_logs.count) {
                c.text = WQLocalized(@"Waiting for Windows PC (USB / Wi-Fi), Android, or Browser…");
                c.secondaryText = WQLocalized(@"Tap 'Pick Files from iPhone to Share…' to choose files right from your screen, or plug into Windows PC & click 🍎 iPhone App Docs (USB).");
            } else {
                c.text = _logs[(NSUInteger)indexPath.row];
            }
            c.textProperties.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            c.textProperties.color = wq_theme_primary_text();
            c.secondaryTextProperties.color = wq_theme_secondary_text();
            c.secondaryTextProperties.numberOfLines = 2;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        cell.contentConfiguration = c;
        return cell;
    }

    // Mode 1: Client (Connect to Device)
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
    } else {
        c.text = WQLocalized(@"Connect by IP:Port & PIN…");
        NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:kWQWinLastEndpointPref];
        c.secondaryText = last.length ? [NSString stringWithFormat:@"Last: %@", last] : WQLocalized(@"Example: 192.168.1.42:8765");
        c.image = [UIImage systemImageNamed:@"network"];
        c.imageProperties.tintColor = wq_theme_accent();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();

    if (_mode == 1) {
        if (indexPath.section == 0) {
            if ((NSUInteger)indexPath.row < _peers.count) {
                [self promptPinForPeer:_peers[(NSUInteger)indexPath.row]];
            } else {
                [_discovery sendProbeNow];
            }
        } else if (indexPath.row == 0) {
            [self presentQRScanner];
        } else {
            [self promptManualConnect];
        }
        return;
    }

    if (indexPath.section != 0) return;

    if (indexPath.row == 0) {
        UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Choose Folder to Share (Wi-Fi & USB)"), nil, UIAlertControllerStyleActionSheet);
        [sheet addAction:wq_alert_action(WQLocalized(@"WQ Glass Downloads (Videos / Audio / Files)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_downloads_dir();
            self->_server.rootLabel = @"Downloads";
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"WQ Glass Documents (All Saved Files)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_documents_dir();
            self->_server.rootLabel = @"Documents";
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"My Selected Files (Picked on iPhone)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = wq_win_selected_outbox_dir();
            self->_server.rootLabel = @"My Selected Files";
            [self.tableView reloadData];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"App Data Containers"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_server.rootPath = @"/private/var/mobile/Containers/Data/Application";
            self->_server.rootLabel = @"App Data";
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
        if (_server.isRunning && _server.ipAddress.length) {
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
            [self refreshHeader];
            [self.tableView reloadData];
        })];
        [self presentViewController:a animated:YES completion:nil];
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
