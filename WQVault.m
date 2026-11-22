//
//  WQVault.m
//  WQ Glass Face ID Encrypted Private Vault (AES-256-CBC + HMAC-SHA256 + Keychain)
//  GPL-3.0-or-later.
//

#import "WQVault.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQSecurity.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kWQVaultKeychainService = @"cz.kolbi.wqfiles.privatevault";
static NSString *const kWQVaultKeychainAccount = @"master-key-v1";
static const char kWQVaultMagic[4] = {'W', 'Q', 'V', '1'};

static NSString *wq_vault_dir(void)
{
    NSString *appSup = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [appSup stringByAppendingPathComponent:@"PrivateVault"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_vault_index_path(void)
{
    return [wq_vault_dir() stringByAppendingPathComponent:@"index.plist"];
}

static NSString *wq_vault_temp_dir(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-vault-preview"];
}

static void wq_vault_wipe_temp(void)
{
    [NSFileManager.defaultManager removeItemAtPath:wq_vault_temp_dir() error:nil];
}

// Returns 64-byte key material (32-byte AES-256 key + 32-byte HMAC-SHA256 key) from Keychain.
static NSData *_Nullable wq_vault_master_key(void)
{
    NSDictionary *query = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: kWQVaultKeychainService,
        (id)kSecAttrAccount: kWQVaultKeychainAccount,
        (id)kSecReturnData: @YES,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess) {
        NSData *key = CFBridgingRelease(result);
        if (key.length == 64) return key;
    }
    uint8_t raw[64];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(raw), raw) != errSecSuccess) return nil;
    NSData *newKey = [NSData dataWithBytes:raw length:sizeof(raw)];
    memset(raw, 0, sizeof(raw));
    NSDictionary *add = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: kWQVaultKeychainService,
        (id)kSecAttrAccount: kWQVaultKeychainAccount,
        (id)kSecAttrAccessible: (id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        (id)kSecValueData: newKey,
    };
    SecItemDelete((__bridge CFDictionaryRef)@{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: kWQVaultKeychainService,
        (id)kSecAttrAccount: kWQVaultKeychainAccount,
    });
    if (SecItemAdd((__bridge CFDictionaryRef)add, NULL) != errSecSuccess) return nil;
    return newKey;
}

static NSData *_Nullable wq_vault_encrypt(NSData *plain)
{
    NSData *key = wq_vault_master_key();
    if (key.length != 64 || !plain) return nil;
    const uint8_t *encKey = (const uint8_t *)key.bytes;
    const uint8_t *macKey = encKey + 32;

    uint8_t iv[kCCBlockSizeAES128];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(iv), iv) != errSecSuccess) return nil;

    size_t outCap = plain.length + kCCBlockSizeAES128;
    NSMutableData *cipher = [NSMutableData dataWithLength:outCap];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 encKey, kCCKeySizeAES256, iv,
                                 plain.bytes, plain.length,
                                 cipher.mutableBytes, outCap, &outLen);
    if (st != kCCSuccess) return nil;
    cipher.length = outLen;

    // Format: [4B magic "WQV1"][16B IV][ciphertext][32B HMAC-SHA256(magic||IV||ciphertext)]
    NSMutableData *blob = [NSMutableData dataWithCapacity:4 + sizeof(iv) + outLen + CC_SHA256_DIGEST_LENGTH];
    [blob appendBytes:kWQVaultMagic length:4];
    [blob appendBytes:iv length:sizeof(iv)];
    [blob appendData:cipher];
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, macKey, 32, blob.bytes, blob.length, mac);
    [blob appendBytes:mac length:sizeof(mac)];
    return blob;
}

static NSData *_Nullable wq_vault_decrypt(NSData *blob)
{
    NSData *key = wq_vault_master_key();
    NSUInteger overhead = 4 + kCCBlockSizeAES128 + CC_SHA256_DIGEST_LENGTH;
    if (key.length != 64 || blob.length < overhead) return nil;
    if (memcmp(blob.bytes, kWQVaultMagic, 4) != 0) return nil;

    const uint8_t *encKey = (const uint8_t *)key.bytes;
    const uint8_t *macKey = encKey + 32;
    NSUInteger payloadLen = blob.length - CC_SHA256_DIGEST_LENGTH;
    uint8_t expectedMac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, macKey, 32, blob.bytes, payloadLen, expectedMac);

    const uint8_t *actualMac = (const uint8_t *)blob.bytes + payloadLen;
    uint8_t diff = 0;
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) diff |= (uint8_t)(expectedMac[i] ^ actualMac[i]);
    if (diff != 0) return nil;

    const uint8_t *iv = (const uint8_t *)blob.bytes + 4;
    const uint8_t *cipher = iv + kCCBlockSizeAES128;
    size_t cipherLen = payloadLen - 4 - kCCBlockSizeAES128;
    NSMutableData *plain = [NSMutableData dataWithLength:cipherLen + kCCBlockSizeAES128];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 encKey, kCCKeySizeAES256, iv,
                                 cipher, cipherLen,
                                 plain.mutableBytes, plain.length, &outLen);
    if (st != kCCSuccess) return nil;
    plain.length = outLen;
    return plain;
}

@interface WQPrivateVaultViewController () <UIDocumentPickerDelegate>
@end

@implementation WQPrivateVaultViewController {
    BOOL _unlocked;
    NSMutableArray<NSDictionary<NSString *, id> *> *_entries;   // id, name, size, added
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Private Vault");
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
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lockAndWipe)
                                               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self updateNav];
}

- (void)dealloc
{
    wq_vault_wipe_temp();
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!_unlocked) [self requestUnlock];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) {
        wq_vault_wipe_temp();
    }
}

- (void)lockAndWipe
{
    wq_vault_wipe_temp();
    _unlocked = NO;
    _entries = [NSMutableArray new];
    [self updateNav];
    [self.tableView reloadData];
}

- (void)updateNav
{
    if (!_unlocked) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:WQLocalized(@"Unlock") style:UIBarButtonItemStylePlain target:self action:@selector(requestUnlock)];
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIMenu *addMenu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:WQLocalized(@"Import File into Vault") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf importFile];
        }],
        [UIAction actionWithTitle:WQLocalized(@"New Encrypted Note") image:[UIImage systemImageNamed:@"note.text.badge.plus"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf createSecretNote];
        }],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle.fill"] menu:addMenu];
}

- (void)requestUnlock
{
    __weak typeof(self) weakSelf = self;
    wq_app_lock_authenticate(WQLocalized(@"Authenticate to unlock Private Vault."), ^(BOOL ok, NSString *_Nullable errText) {
        WQPrivateVaultViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            me->_unlocked = YES;
            [me loadIndex];
            [me updateNav];
            [me.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        } else if (errText.length) {
            wq_alert(me, WQLocalized(@"Vault Locked"), errText);
        }
    });
}

- (void)loadIndex
{
    NSArray *raw = [NSArray arrayWithContentsOfFile:wq_vault_index_path()];
    _entries = [NSMutableArray new];
    if ([raw isKindOfClass:NSArray.class]) {
        for (id item in raw) {
            if ([item isKindOfClass:NSDictionary.class]) [_entries addObject:item];
        }
    }
}

- (void)saveIndex
{
    [_entries writeToFile:wq_vault_index_path() atomically:YES];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSDictionary *> *added = [NSMutableArray new];
        for (NSURL *u in urls) {
            @autoreleasepool {
                NSData *plain = [NSData dataWithContentsOfURL:u];
                if (!plain) continue;
                NSData *enc = wq_vault_encrypt(plain);
                if (!enc) continue;
                NSString *vid = NSUUID.UUID.UUIDString;
                NSString *dest = [wq_vault_dir() stringByAppendingPathComponent:[vid stringByAppendingString:@".wqvault"]];
                if ([enc writeToFile:dest atomically:YES]) {
                    [added addObject:@{
                        @"id": vid,
                        @"name": u.lastPathComponent ?: @"File",
                        @"size": @(plain.length),
                        @"added": NSDate.date,
                    }];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQPrivateVaultViewController *me = weakSelf;
            if (!me) return;
            for (NSDictionary *entry in added) [me->_entries insertObject:entry atIndex:0];
            [me saveIndex];
            [me.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        });
    });
}

- (void)createSecretNote
{
    UIAlertController *alert = wq_alert_controller(WQLocalized(@"New Encrypted Note"),
        WQLocalized(@"Stored with AES-256-CBC + HMAC-SHA256 using a Keychain key."),
        UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = WQLocalized(@"Title (e.g. Recovery Codes)"); }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = WQLocalized(@"Secret note content"); }];
    [alert addAction:wq_alert_action(WQLocalized(@"Encrypt & Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *title = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *body = alert.textFields[1].text ?: @"";
        if (!title.length) title = @"Secret Note";
        if (![title.lowercaseString hasSuffix:@".txt"]) title = [title stringByAppendingString:@".txt"];
        NSData *plain = [body dataUsingEncoding:NSUTF8StringEncoding];
        NSData *enc = wq_vault_encrypt(plain);
        if (!enc) { wq_alert(self, WQLocalized(@"Encryption Failed"), WQLocalized(@"Could not access Keychain key.")); return; }
        NSString *vid = NSUUID.UUID.UUIDString;
        NSString *dest = [wq_vault_dir() stringByAppendingPathComponent:[vid stringByAppendingString:@".wqvault"]];
        if ([enc writeToFile:dest atomically:YES]) {
            [self->_entries insertObject:@{ @"id": vid, @"name": title, @"size": @(plain.length), @"added": NSDate.date } atIndex:0];
            [self saveIndex];
            [self.tableView reloadData];
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        }
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openEntryAtIndex:(NSUInteger)idx fromView:(UIView *)source
{
    if (idx >= _entries.count) return;
    NSDictionary *entry = _entries[idx];
    NSString *vid = entry[@"id"];
    NSString *name = entry[@"name"] ?: @"file";
    NSString *encPath = [wq_vault_dir() stringByAppendingPathComponent:[vid stringByAppendingString:@".wqvault"]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *blob = [NSData dataWithContentsOfFile:encPath];
        NSData *plain = blob ? wq_vault_decrypt(blob) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            WQPrivateVaultViewController *me = weakSelf;
            if (!me || !me->_unlocked) return;
            if (!plain) {
                wq_alert(me, WQLocalized(@"Decryption Failed"), WQLocalized(@"Vault integrity check failed or key is unavailable."));
                return;
            }
            // Text files show directly in-memory without touching disk.
            NSString *ext = name.pathExtension.lowercaseString;
            if ([@[@"txt", @"md", @"json", @"xml", @"plist", @"log"] containsObject:ext] && plain.length < 256 * 1024) {
                NSString *txt = [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
                if (txt) {
                    UIAlertController *alert = wq_alert_controller(WQVerbatim(name), txt, UIAlertControllerStyleAlert);
                    [alert addAction:wq_alert_action(WQLocalized(@"Copy"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                        UIPasteboard.generalPasteboard.string = txt;
                        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                    })];
                    [alert addAction:wq_alert_action(WQLocalized(@"Close"), UIAlertActionStyleCancel, nil)];
                    [me presentViewController:alert animated:YES completion:nil];
                    return;
                }
            }
            // Other files write to an ephemeral temp folder auto-wiped on exit/background.
            NSString *tmpDir = wq_vault_temp_dir();
            [NSFileManager.defaultManager createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *tmpFile = [tmpDir stringByAppendingPathComponent:name];
            if ([plain writeToFile:tmpFile atomically:YES]) {
                UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:tmpFile]] applicationActivities:nil];
                av.popoverPresentationController.sourceView = source ?: me.view;
                av.popoverPresentationController.sourceRect = (source ?: me.view).bounds;
                av.completionWithItemsHandler = ^(UIActivityType __unused t, BOOL __unused c, NSArray *__unused r, NSError *__unused e) {
                    wq_vault_wipe_temp();
                };
                [me presentViewController:av animated:YES completion:nil];
            }
        });
    });
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    if (!_unlocked || !_entries.count) return 1;
    return (NSInteger)_entries.count;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger __unused)section
{
    return _unlocked ? WQLocalized(@"AES-256 Encrypted Files") : WQLocalized(@"Locked");
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger __unused)section
{
    return WQLocalized(@"Protected by AES-256-CBC + HMAC-SHA256 with a device-only Keychain key. Temporary previews wipe automatically on exit.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"vault-item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"vault-item"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_unlocked) {
        c.text = WQLocalized(@"Tap to Authenticate & Unlock");
        c.secondaryText = WQLocalizedFormat(@"Requires %@", wq_app_lock_biometry_name());
        c.image = [UIImage systemImageNamed:@"lock.shield.fill"];
        c.imageProperties.tintColor = wq_theme_accent();
        c.textProperties.color = wq_theme_primary_text();
        c.secondaryTextProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        return cell;
    }
    if (!_entries.count) {
        c.text = WQLocalized(@"Vault is Empty");
        c.secondaryText = WQLocalized(@"Tap + to encrypt and import files or secret notes.");
        c.textProperties.color = wq_theme_secondary_text();
        c.secondaryTextProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        return cell;
    }
    NSDictionary *e = _entries[(NSUInteger)indexPath.row];
    c.text = e[@"name"] ?: @"File";
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryText = wq_size_text([e[@"size"] unsignedLongLongValue]);
    c.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    c.secondaryTextProperties.color = wq_theme_secondary_text();
    c.image = [UIImage systemImageNamed:@"lock.doc.fill"];
    c.imageProperties.tintColor = wq_theme_aurora_teal();
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_haptic_selection();
    if (!_unlocked) { [self requestUnlock]; return; }
    if (!_entries.count) { [self importFile]; return; }
    [self openEntryAtIndex:(NSUInteger)indexPath.row fromView:[tableView cellForRowAtIndexPath:indexPath]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_unlocked || !_entries.count) return nil;
    NSUInteger idx = (NSUInteger)indexPath.row;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:WQLocalized(@"Delete") handler:^(UIContextualAction *__unused a, UIView *__unused v, void (^done)(BOOL)) {
        if (idx < self->_entries.count) {
            NSString *vid = self->_entries[idx][@"id"];
            NSString *encPath = [wq_vault_dir() stringByAppendingPathComponent:[vid stringByAppendingString:@".wqvault"]];
            [NSFileManager.defaultManager removeItemAtPath:encPath error:nil];
            [self->_entries removeObjectAtIndex:idx];
            [self saveIndex];
            [self.tableView reloadData];
        }
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
