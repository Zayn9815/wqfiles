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
#import <CoreImage/CoreImage.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/statvfs.h>
#import <unistd.h>

static NSString *const kWQWinFixedPinPref = @"WQWinTransferFixedPIN";
static const uint16_t kWQWinDiscoveryPort = 45888;
static const uint16_t kWQWinBasePort = 8765;
static const size_t kWQWinChunkBytes = 256 * 1024;
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
           @"<title>WQ Glass · Windows Transfer</title>"
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
           @"<h1>WQ Glass · iPhone ↔ Windows Transfer</h1>"
           @"<div class='sub' id='info'>Enter the 4-digit PIN shown on your iPhone to browse, download & upload files.</div>"
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
        @"version": @"1.0",
        @"device": UIDevice.currentDevice.name ?: @"iPhone",
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
    if (!ip.length) {
        if (errorOut) *errorOut = WQLocalized(@"Connect your iPhone and Windows PC to the same Wi-Fi network first.");
        return NO;
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
        if (errorOut) *errorOut = WQLocalized(@"Could not bind a local Wi-Fi transfer port.");
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

    [self startUDPDiscovery];
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
            @"version": @"1.0",
            @"device": UIDevice.currentDevice.name ?: @"iPhone",
            @"ios": UIDevice.currentDevice.systemVersion ?: @"",
            @"root": self.rootLabel ?: @"Downloads",
            @"freeBytes": @(freeB),
            @"totalBytes": @(totalB),
        } status:200 toFD:fd];
        [self emitActivity:WQLocalized(@"Connected: Windows PC verified PIN")];
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

    [self sendJSON:@{ @"error": @"Not found" } status:404 toFD:fd];
}

@end

#pragma mark - WQWinTransferViewController

@implementation WQWinTransferViewController {
    WQWinTransferServer *_server;
    NSString *_errorText;
    NSMutableArray<NSString *> *_logs;
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
        _logs = [NSMutableArray new];
        self.title = WQLocalized(@"iPhone ↔ Windows");
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

    __weak typeof(self) weakSelf = self;
    _server.onActivity = ^(NSString *entry) {
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        [me->_logs insertObject:entry atIndex:0];
        if (me->_logs.count > 40) [me->_logs removeLastObject];
        [me.tableView reloadData];
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
    }
}

- (void)dealloc
{
    [_server stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)appDidEnterBackground
{
    [_server stop];
    [self refreshHeader];
}

- (void)startServer
{
    NSString *err = nil;
    if ([_server startWithError:&err]) {
        _errorText = nil;
    } else {
        _errorText = err;
    }
    [self refreshHeader];
    [self.tableView reloadData];
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
    self.tableView.tableHeaderView = box;
}

- (void)refreshHeader
{
    if (_server.isRunning && _server.ipAddress.length) {
        NSString *urlStr = [NSString stringWithFormat:@"http://%@:%u", _server.ipAddress, (unsigned)_server.port];
        _statusLabel.text = WQLocalized(@"● Live · Open WQGlass Transfer on Windows (auto-detected on Wi-Fi)");
        _statusLabel.textColor = UIColor.systemGreenColor;
        _pinLabel.text = [NSString stringWithFormat:@"PIN  %@", _server.pin];
        _addrLabel.text = urlStr;
        _qrView.image = wq_win_qr_image(urlStr, 240.0);
        _qrView.hidden = NO;
    } else {
        _statusLabel.text = _errorText ?: WQLocalized(@"Server Stopped");
        _statusLabel.textColor = UIColor.systemOrangeColor;
        _pinLabel.text = @"----";
        _addrLabel.text = WQLocalized(@"Tap Start Server below");
        _qrView.hidden = YES;
    }
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 4;
    return MAX(1, (NSInteger)_logs.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    return (section == 0) ? WQLocalized(@"Transfer Controls") : WQLocalized(@"Live Transfer Activity");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"win-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"win-row"];
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
            c.text = WQLocalized(@"Copy Wi-Fi Address & PIN");
            c.secondaryText = _server.isRunning ? _server.pin : @"--";
            c.image = [UIImage systemImageNamed:@"doc.on.doc"];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 2) {
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
        c.imageProperties.tintColor = wq_theme_accent();
    } else {
        c = [UIListContentConfiguration subtitleCellConfiguration];
        if (!_logs.count) {
            c.text = WQLocalized(@"Waiting for Windows PC…");
            c.secondaryText = WQLocalized(@"Install WQGlass Transfer on Windows (or open the URL above in Edge/Chrome).");
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    wq_haptic_selection();

    if (indexPath.row == 0) {
        UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Choose Folder to Share with Windows"), nil, UIAlertControllerStyleActionSheet);
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
        if (_server.isRunning && _server.ipAddress.length) {
            UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"http://%@:%u (PIN: %@)", _server.ipAddress, (unsigned)_server.port, _server.pin];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            wq_alert(self, WQLocalized(@"Copied"), WQLocalized(@"Wi-Fi address & PIN copied to clipboard."));
        }
    } else if (indexPath.row == 2) {
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
