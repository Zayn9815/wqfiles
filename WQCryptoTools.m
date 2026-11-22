//
//  WQCryptoTools.m
//  WQ Glass Portable PBKDF2 + AES-256 (.wqenc) File Locker & Secure Shredder
//  GPL-3.0-or-later.
//

#import "WQCryptoTools.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static const uint8_t kWQEncMagic[4] = { 'W', 'Q', 'E', '1' };
static const uint32_t kWQEncPBKDF2Rounds = 100000;

static NSString *wq_crypto_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"Encrypted Locker"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL wq_derive_enc_keys(NSString *password, const uint8_t salt[16], uint8_t outKeys[64])
{
    NSData *pwData = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!pwData.length) return NO;
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2,
                                  (const char *)pwData.bytes, pwData.length,
                                  salt, 16,
                                  kCCPRFHmacAlgSHA256,
                                  kWQEncPBKDF2Rounds,
                                  outKeys, 64);
    return rc == kCCSuccess;
}

static NSData *wq_enc_encrypt_data(NSData *plain, NSString *password, NSString **errorOut)
{
    if (!plain || !password.length) {
        if (errorOut) *errorOut = WQLocalized(@"Missing data or passphrase.");
        return nil;
    }
    uint8_t salt[16];
    uint8_t iv[kCCBlockSizeAES128];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(salt), salt) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, sizeof(iv), iv) != errSecSuccess) {
        if (errorOut) *errorOut = WQLocalized(@"Random byte generation failed.");
        return nil;
    }
    uint8_t keys[64];
    if (!wq_derive_enc_keys(password, salt, keys)) {
        if (errorOut) *errorOut = WQLocalized(@"Key derivation failed.");
        return nil;
    }
    size_t outCap = plain.length + kCCBlockSizeAES128;
    NSMutableData *cipher = [NSMutableData dataWithLength:outCap];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 keys, 32, iv,
                                 plain.bytes, plain.length,
                                 cipher.mutableBytes, cipher.length, &outLen);
    if (st != kCCSuccess) {
        memset_s(keys, sizeof(keys), 0, sizeof(keys));
        if (errorOut) *errorOut = WQLocalized(@"AES-256 encryption failed.");
        return nil;
    }
    cipher.length = outLen;

    NSMutableData *blob = [NSMutableData dataWithCapacity:4 + 16 + 16 + outLen + CC_SHA256_DIGEST_LENGTH];
    [blob appendBytes:kWQEncMagic length:4];
    [blob appendBytes:salt length:16];
    [blob appendBytes:iv length:16];
    [blob appendData:cipher];

    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keys + 32, 32, blob.bytes, blob.length, mac);
    memset_s(keys, sizeof(keys), 0, sizeof(keys));
    [blob appendBytes:mac length:sizeof(mac)];
    return blob;
}

static NSData *wq_enc_decrypt_data(NSData *blob, NSString *password, NSString **errorOut)
{
    const NSUInteger headerLen = 4 + 16 + 16;
    if (blob.length <= headerLen + CC_SHA256_DIGEST_LENGTH || memcmp(blob.bytes, kWQEncMagic, 4) != 0) {
        if (errorOut) *errorOut = WQLocalized(@"Not a valid .wqenc encrypted file.");
        return nil;
    }
    const uint8_t *raw = blob.bytes;
    const uint8_t *salt = raw + 4;
    const uint8_t *iv = raw + 20;
    NSUInteger authLen = blob.length - CC_SHA256_DIGEST_LENGTH;
    const uint8_t *storedMac = raw + authLen;

    uint8_t keys[64];
    if (!wq_derive_enc_keys(password, salt, keys)) {
        if (errorOut) *errorOut = WQLocalized(@"Key derivation failed.");
        return nil;
    }
    uint8_t calcMac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keys + 32, 32, raw, authLen, calcMac);
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) diff |= (uint8_t)(calcMac[i] ^ storedMac[i]);
    if (diff != 0) {
        memset_s(keys, sizeof(keys), 0, sizeof(keys));
        if (errorOut) *errorOut = WQLocalized(@"Wrong passphrase or corrupted file (HMAC mismatch).");
        return nil;
    }

    NSUInteger cipherLen = authLen - headerLen;
    NSMutableData *plain = [NSMutableData dataWithLength:cipherLen + kCCBlockSizeAES128];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 keys, 32, iv,
                                 raw + headerLen, cipherLen,
                                 plain.mutableBytes, plain.length, &outLen);
    memset_s(keys, sizeof(keys), 0, sizeof(keys));
    if (st != kCCSuccess) {
        if (errorOut) *errorOut = WQLocalized(@"AES-256 decryption failed.");
        return nil;
    }
    plain.length = outLen;
    return plain;
}

void wq_confirm_secure_shred(UIViewController *host, NSString *filePath, void (^onDone)(BOOL ok))
{
    if (wq_refuse_if_deleting_off(host)) return;
    if (!filePath.length) return;
    wq_present_glass_confirm(host,
                             WQLocalizedFormat(@"Securely Shred “%@”?", filePath.lastPathComponent),
                             WQLocalized(@"Overwrites the file's bytes with random data + zeros and permanently deletes it WITHOUT creating a backup. This cannot be undone."),
                             WQLocalized(@"Shred Permanently"),
                             YES,
                             ^{
        dispatch_async(wq_io(), ^{
            wq_grant(filePath.stringByDeletingLastPathComponent);
            struct stat st;
            BOOL ok = NO;
            NSString *errText = nil;
            if (lstat(filePath.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) {
                int fd = open(filePath.fileSystemRepresentation, O_WRONLY);
                if (fd >= 0) {
                    unsigned long long remaining = (unsigned long long)MAX(0LL, st.st_size);
                    uint8_t buf[65536];
                    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(buf), buf) != errSecSuccess) {
                        memset(buf, 0, sizeof(buf));
                    }
                    while (remaining > 0) {
                        size_t chunk = (size_t)MIN(remaining, (unsigned long long)sizeof(buf));
                        ssize_t w = write(fd, buf, chunk);
                        if (w <= 0) break;
                        remaining -= (unsigned long long)w;
                    }
                    fsync(fd);
                    close(fd);
                }
                if (unlink(filePath.fileSystemRepresentation) == 0) {
                    ok = YES;
                } else {
                    errText = [NSString stringWithUTF8String:strerror(errno)];
                }
            } else {
                errText = WQLocalized(@"Only regular files can be securely shredded.");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_haptic_notify(ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError);
                if (!ok) wq_alert(host, WQLocalized(@"Shred Failed"), errText ?: WQLocalized(@"Permission denied."));
                if (onDone) onDone(ok);
            });
        });
    });
}

@interface WQCryptoToolsViewController () <UIDocumentPickerDelegate>
@end

@implementation WQCryptoToolsViewController {
    NSString *_selectedPath;
    BOOL _busy;
    NSString *_status;
    BOOL _pickDecrypt;
}

- (instancetype)initWithInitialPath:(NSString *)filePath
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _selectedPath = [filePath copy];
        self.title = WQLocalized(@"Portable File Locker (.wqenc)");
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
}

- (void)pickFileForDecrypt:(BOOL)decrypt
{
    if (_busy) return;
    _pickDecrypt = decrypt;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *u = urls.firstObject;
    if (!u) return;
    _selectedPath = u.path;
    [self.tableView reloadData];
    [self promptPassphraseAndRunDecrypt:_pickDecrypt];
}

- (void)promptPassphraseAndRunDecrypt:(BOOL)decrypt
{
    if (!_selectedPath.length || _busy) return;
    UIAlertController *a = wq_alert_controller(decrypt ? WQLocalized(@"Decrypt .wqenc File") : WQLocalized(@"Encrypt File with Passphrase"),
                                               WQVerbatim(_selectedPath.lastPathComponent),
                                               UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = WQLocalized(@"Passphrase");
        f.secureTextEntry = YES;
    }];
    if (!decrypt) {
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.placeholder = WQLocalized(@"Confirm passphrase");
            f.secureTextEntry = YES;
        }];
    }
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(decrypt ? WQLocalized(@"Decrypt") : WQLocalized(@"Encrypt"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *pw = a.textFields[0].text ?: @"";
        if (pw.length < 4) {
            wq_alert(self, WQLocalized(@"Passphrase Too Short"), WQLocalized(@"Use at least 4 characters."));
            return;
        }
        if (!decrypt && ![pw isEqualToString:a.textFields[1].text ?: @""]) {
            wq_alert(self, WQLocalized(@"Passphrases Don't Match"), WQLocalized(@"Re-enter matching passphrases."));
            return;
        }
        [self executeCryptoWithPassword:pw decrypt:decrypt];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)executeCryptoWithPassword:(NSString *)password decrypt:(BOOL)decrypt
{
    _busy = YES;
    _status = decrypt ? WQLocalized(@"Deriving PBKDF2 key & decrypting…") : WQLocalized(@"Deriving PBKDF2 key & encrypting…");
    [self.tableView reloadData];

    NSString *srcPath = _selectedPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = nil;
        NSData *input = wq_read(srcPath, 128 * 1024 * 1024, &err) ?: [NSData dataWithContentsOfFile:srcPath];
        NSData *output = nil;
        if (input.length) {
            output = decrypt ? wq_enc_decrypt_data(input, password, &err) : wq_enc_encrypt_data(input, password, &err);
        } else if (!err) {
            err = WQLocalized(@"Unable to read input file.");
        }
        NSString *outPath = nil;
        BOOL ok = NO;
        if (output) {
            NSString *name = srcPath.lastPathComponent ?: @"file";
            NSString *outName = decrypt
                ? ([name.pathExtension.lowercaseString isEqualToString:@"wqenc"] ? name.stringByDeletingPathExtension : [name stringByAppendingString:@".decrypted"])
                : [name stringByAppendingPathExtension:@"wqenc"];
            outPath = [wq_crypto_output_dir() stringByAppendingPathComponent:outName];
            ok = [output writeToFile:outPath atomically:YES];
            if (!ok) err = WQLocalized(@"Failed to write output file.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQCryptoToolsViewController *me = weakSelf;
            if (!me) return;
            me->_busy = NO;
            me->_status = nil;
            [me.tableView reloadData];
            if (ok && outPath) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                UIAlertController *done = wq_alert_controller(decrypt ? WQLocalized(@"File Decrypted") : WQLocalized(@"Encrypted .wqenc Created"),
                                                              WQLocalizedFormat(@"Saved to Documents/Encrypted Locker/%@", outPath.lastPathComponent),
                                                              UIAlertControllerStyleAlert);
                [done addAction:wq_alert_action(WQLocalized(@"Share File"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                    share.popoverPresentationController.sourceView = me.view;
                    [me presentViewController:share animated:YES completion:nil];
                })];
                [done addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
                [me presentViewController:done animated:YES completion:nil];
            } else {
                wq_haptic_notify(UINotificationFeedbackTypeError);
                wq_alert(me, decrypt ? WQLocalized(@"Decryption Failed") : WQLocalized(@"Encryption Failed"), err ?: WQLocalized(@"Operation failed."));
            }
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 2; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : 2;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return _status ?: WQLocalized(@"Selected File");
    return WQLocalized(@"PBKDF2 (100k) + AES-256-CBC + HMAC-SHA256");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) {
        return WQLocalized(@"Encrypted .wqenc files are portable and safe to send over AirDrop, iCloud, Messages, or Email. Only someone with the passphrase can decrypt them inside WQ Glass.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cry-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cry-row"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.imageProperties.tintColor = wq_theme_accent();

    if (indexPath.section == 0) {
        c.text = _selectedPath.length ? _selectedPath.lastPathComponent : WQLocalized(@"No file selected yet");
        c.secondaryText = _selectedPath.length ? _selectedPath : WQLocalized(@"Choose Encrypt or Decrypt below to pick a file.");
        c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
        c.image = [UIImage systemImageNamed:@"lock.doc.fill"];
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (indexPath.row == 0) {
        c.text = _selectedPath.length ? WQLocalized(@"Encrypt Selected File (.wqenc)…") : WQLocalized(@"Pick File to Encrypt (.wqenc)…");
        c.secondaryText = WQLocalized(@"Password-locks any file with AES-256 + HMAC integrity");
        c.image = [UIImage systemImageNamed:@"lock.fill"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.text = (_selectedPath.length && [_selectedPath.pathExtension.lowercaseString isEqualToString:@"wqenc"])
            ? WQLocalized(@"Decrypt Selected .wqenc File…")
            : WQLocalized(@"Pick .wqenc File to Decrypt…");
        c.secondaryText = WQLocalized(@"Verifies HMAC-SHA256 & restores the original file");
        c.image = [UIImage systemImageNamed:@"lock.open.fill"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    wq_haptic_selection();
    BOOL decrypt = (indexPath.row == 1);
    if (_selectedPath.length && (!decrypt || [_selectedPath.pathExtension.lowercaseString isEqualToString:@"wqenc"])) {
        [self promptPassphraseAndRunDecrypt:decrypt];
    } else {
        [self pickFileForDecrypt:decrypt];
    }
}

@end

void wq_present_crypto_tools(UIViewController *host, NSString *filePath)
{
    WQCryptoToolsViewController *vc = [[WQCryptoToolsViewController alloc] initWithInitialPath:filePath];
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }
}
