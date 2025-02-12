/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "NCSettingsController.h"

#import <openssl/rsa.h>
#import <openssl/pem.h>
#import <openssl/bio.h>
#import <openssl/bn.h>
#import <openssl/sha.h>
#import <openssl/err.h>

#import "JDStatusBarNotification.h"
#import "OpenInFirefoxControllerObjC.h"

#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCConnectionController.h"
#import "NCDatabaseManager.h"
#import "NCExternalSignalingController.h"
#import "NCKeyChainController.h"
#import "NCRoomsManager.h"
#import "NCUserInterfaceController.h"
#import "NCUserDefaults.h"
#import "NCChatFileController.h"
#import "NotificationCenterNotifications.h"

@interface NCSettingsController ()
{
    NSString *_lockScreenPasscode;
    NCPasscodeType _lockScreenPasscodeType;
}

@end

@implementation NCSettingsController

NSString * const kUserProfileUserId             = @"id";
NSString * const kUserProfileDisplayName        = @"displayname";
NSString * const kUserProfileDisplayNameScope   = @"displaynameScope";
NSString * const kUserProfileEmail              = @"email";
NSString * const kUserProfileEmailScope         = @"emailScope";
NSString * const kUserProfilePhone              = @"phone";
NSString * const kUserProfilePhoneScope         = @"phoneScope";
NSString * const kUserProfileAddress            = @"address";
NSString * const kUserProfileAddressScope       = @"addressScope";
NSString * const kUserProfileWebsite            = @"website";
NSString * const kUserProfileWebsiteScope       = @"websiteScope";
NSString * const kUserProfileTwitter            = @"twitter";
NSString * const kUserProfileTwitterScope       = @"twitterScope";
NSString * const kUserProfileAvatarScope        = @"avatarScope";

NSString * const kUserProfileScopePrivate       = @"v2-private";
NSString * const kUserProfileScopeLocal         = @"v2-local";
NSString * const kUserProfileScopeFederated     = @"v2-federated";
NSString * const kUserProfileScopePublished     = @"v2-published";

NSInteger const kDefaultChatMaxLength           = 1000;

NSString * const kPreferredFileSorting  = @"preferredFileSorting";
NSString * const kContactSyncEnabled  = @"contactSyncEnabled";

+ (NCSettingsController *)sharedInstance
{
    static dispatch_once_t once;
    static NCSettingsController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _videoSettingsModel = [[ARDSettingsModel alloc] init];
        _signalingConfigutations = [NSMutableDictionary new];
        _externalSignalingControllers = [NSMutableDictionary new];
        
        [self readValuesFromKeyChain];
        [self configureDatabase];
        [self checkStoredDataInKechain];
        [self configureAppSettings];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tokenRevokedResponseReceived:) name:NCTokenRevokedResponseReceivedNotification object:nil];
    }
    return self;
}

#pragma mark - Database

- (void)configureDatabase
{
    // Init database
    [NCDatabaseManager sharedInstance];
    
    // Check possible account migration to database
    if (_ncUser && _ncServer) {
        NSLog(@"Migrating user to the database");
        TalkAccount *account =  [[TalkAccount alloc] init];
        account.accountId = [NSString stringWithFormat:@"%@@%@", _ncUser, _ncServer];
        account.server = _ncServer;
        account.user = _ncUser;
        account.pushNotificationSubscribed = _pushNotificationSubscribed;
        account.pushNotificationPublicKey = _ncPNPublicKey;
        account.pushNotificationPublicKey = _ncPNPublicKey;
        account.deviceIdentifier = _ncDeviceIdentifier;
        account.deviceSignature = _ncDeviceSignature;
        account.userPublicKey = _ncUserPublicKey;
        account.active = YES;
        
        [[NCKeyChainController sharedInstance] setToken:_ncToken forAccountId:account.accountId];
        [[NCKeyChainController sharedInstance] setPushNotificationPrivateKey:_ncPNPrivateKey forAccountId:account.accountId];
        
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            [realm addObject:account];
        }];
        
        [self cleanUserAndServerStoredValues];
    }
}

- (void)checkStoredDataInKechain
{
    // Removed data stored in the Keychain if there are no accounts configured
    // This step should be always done before the possible account migration
    if ([[NCDatabaseManager sharedInstance] numberOfAccounts] == 0) {
        NSLog(@"Removing all data stored in Keychain");
        [self cleanUserAndServerStoredValues];
        [[NCKeyChainController sharedInstance] removeAllItems];
    }
}

#pragma mark - User accounts

- (void)addNewAccountForUser:(NSString *)user withToken:(NSString *)token inServer:(NSString *)server
{
    NSString *accountId = [[NCDatabaseManager sharedInstance] accountIdForUser:user inServer:server];
    TalkAccount *account = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId];
    if (!account) {
        [[NCDatabaseManager sharedInstance] createAccountForUser:user inServer:server];
        [[NCDatabaseManager sharedInstance] setActiveAccountWithAccountId:accountId];
        [[NCKeyChainController sharedInstance] setToken:token forAccountId:accountId];
        TalkAccount *talkAccount = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId];
        [[NCAPIController sharedInstance] createAPISessionManagerForAccount:talkAccount];
        [self subscribeForPushNotificationsForAccountId:accountId];
    } else {
        [self setActiveAccountWithAccountId:accountId];
        [JDStatusBarNotification showWithStatus:@"Account already added" dismissAfter:4.0f styleName:JDStatusBarStyleSuccess];
    }
}

- (void)setActiveAccountWithAccountId:(NSString *)accountId
{
    [[NCUserInterfaceController sharedInstance] presentConversationsList];
    [[NCDatabaseManager sharedInstance] setActiveAccountWithAccountId:accountId];
    [[NCDatabaseManager sharedInstance] resetUnreadBadgeNumberForAccountId:accountId];
    [[NCNotificationController sharedInstance] removeAllNotificationsForAccountId:accountId];
    [[NCConnectionController sharedInstance] checkAppState];
}

#pragma mark - Notifications

- (void)tokenRevokedResponseReceived:(NSNotification *)notification
{
    NSString *accountId = [notification.userInfo objectForKey:@"accountId"];
    [self logoutAccountWithAccountId:accountId withCompletionBlock:^(NSError *error) {
        [[NCUserInterfaceController sharedInstance] presentConversationsList];
        [[NCUserInterfaceController sharedInstance] presentLoggedOutInvalidCredentialsAlert];
        [[NCConnectionController sharedInstance] checkAppState];
    }];
}

#pragma mark - User defaults

- (NCPreferredFileSorting)getPreferredFileSorting
{
    NCPreferredFileSorting sorting = (NCPreferredFileSorting)[[[NSUserDefaults standardUserDefaults] objectForKey:kPreferredFileSorting] integerValue];
    if (!sorting) {
        sorting = NCModificationDateSorting;
        [[NSUserDefaults standardUserDefaults] setObject:@(sorting) forKey:kPreferredFileSorting];
    }
    return sorting;
}

- (void)setPreferredFileSorting:(NCPreferredFileSorting)sorting
{
    [[NSUserDefaults standardUserDefaults] setObject:@(sorting) forKey:kPreferredFileSorting];
}

- (BOOL)isContactSyncEnabled
{
    // Migration from global setting to per-account setting
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:kContactSyncEnabled] boolValue]) {
        // If global setting was enabled then we enable contact sync for all accounts
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm beginWriteTransaction];
        for (TalkAccount *account in [TalkAccount allObjects]) {
            account.hasContactSyncEnabled = YES;
        }
        [realm commitWriteTransaction];
        // Remove global setting
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kContactSyncEnabled];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return YES;
    }
    
    return [[NCDatabaseManager sharedInstance] activeAccount].hasContactSyncEnabled;
}

- (void)setContactSync:(BOOL)enabled
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm beginWriteTransaction];
    TalkAccount *account = [TalkAccount objectsWhere:(@"active = true")].firstObject;
    account.hasContactSyncEnabled = enabled;
    [realm commitWriteTransaction];
}

#pragma mark - KeyChain

- (void)readValuesFromKeyChain
{
    _ncServer = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCServerKey];
    _ncUser = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCUserKey];
    _ncUserId = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCUserIdKey];
    _ncUserDisplayName = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCUserDisplayNameKey];
    _ncToken = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCTokenKey];
    _ncPushToken = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCPushTokenKey];
    _ncNormalPushToken = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCNormalPushTokenKey];
    _ncPushKitToken = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCPushKitTokenKey];
    _pushNotificationSubscribed = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCPushSubscribedKey];
    _ncPNPublicKey = [[NCKeyChainController sharedInstance].keychain dataForKey:kNCPNPublicKey];
    _ncPNPrivateKey = [[NCKeyChainController sharedInstance].keychain dataForKey:kNCPNPrivateKey];
    _ncDeviceIdentifier = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCDeviceIdentifier];
    _ncDeviceSignature = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCDeviceSignature];
    _ncUserPublicKey = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCUserPublicKey];
}

- (void)cleanUserAndServerStoredValues
{
    _ncServer = nil;
    _ncUser = nil;
    _ncUserDisplayName = nil;
    _ncToken = nil;
    _ncPNPublicKey = nil;
    _ncPNPrivateKey = nil;
    _ncUserPublicKey = nil;
    _ncDeviceIdentifier = nil;
    _ncDeviceSignature = nil;
    _pushNotificationSubscribed = nil;
    
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCServerKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCUserKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCUserDisplayNameKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCTokenKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCPushSubscribedKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCPNPublicKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCPNPrivateKey];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCDeviceIdentifier];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCDeviceSignature];
    [[NCKeyChainController sharedInstance].keychain removeItemForKey:kNCUserPublicKey];
}

#pragma mark - User Profile

- (void)getUserProfileWithCompletionBlock:(UpdatedProfileCompletionBlock)block
{
    [[NCAPIController sharedInstance] getUserProfileForAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSDictionary *userProfile, NSError *error) {
        if (!error) {
            id emailObject = [userProfile objectForKey:kUserProfileEmail];
            NSString *email = emailObject;
            if (!emailObject || [emailObject isEqual:[NSNull null]]) {
                email = @"";
            }
            RLMRealm *realm = [RLMRealm defaultRealm];
            [realm beginWriteTransaction];
            TalkAccount *managedActiveAccount = [TalkAccount objectsWhere:(@"active = true")].firstObject;
            managedActiveAccount.userId = [userProfile objectForKey:kUserProfileUserId];
            // "display-name" is returned by /cloud/user endpoint
            // change to kUserProfileDisplayName ("displayName") when using /cloud/users/{userId} endpoint
            managedActiveAccount.userDisplayName = [userProfile objectForKey:@"display-name"];
            managedActiveAccount.userDisplayNameScope = [userProfile objectForKey:kUserProfileDisplayNameScope];
            managedActiveAccount.phone = [userProfile objectForKey:kUserProfilePhone];
            managedActiveAccount.phoneScope = [userProfile objectForKey:kUserProfilePhoneScope];
            managedActiveAccount.email = email;
            managedActiveAccount.emailScope = [userProfile objectForKey:kUserProfileEmailScope];
            managedActiveAccount.address = [userProfile objectForKey:kUserProfileAddress];
            managedActiveAccount.addressScope = [userProfile objectForKey:kUserProfileAddressScope];
            managedActiveAccount.website = [userProfile objectForKey:kUserProfileWebsite];
            managedActiveAccount.websiteScope = [userProfile objectForKey:kUserProfileWebsiteScope];
            managedActiveAccount.twitter = [userProfile objectForKey:kUserProfileTwitter];
            managedActiveAccount.twitterScope = [userProfile objectForKey:kUserProfileTwitterScope];
            managedActiveAccount.avatarScope = [userProfile objectForKey:kUserProfileAvatarScope];
            [realm commitWriteTransaction];
            [[NCAPIController sharedInstance] saveProfileImageForAccount:[[NCDatabaseManager sharedInstance] activeAccount]];
            if (block) block(nil);
        } else {
            NSLog(@"Error while getting the user profile");
            if (block) block(error);
        }
    }];
}

- (void)logoutAccountWithAccountId:(NSString *)accountId withCompletionBlock:(LogoutCompletionBlock)block
{
    TalkAccount *removingAccount = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId];
    if (removingAccount.deviceIdentifier) {
        [[NCAPIController sharedInstance] unsubscribeAccount:removingAccount fromNextcloudServerWithCompletionBlock:^(NSError *error) {
            if (!error) {
                NSLog(@"Unsubscribed from NC server!!!");
            } else {
                NSLog(@"Error while unsubscribing from NC server.");
            }
        }];
        [[NCAPIController sharedInstance] unsubscribeAccount:removingAccount fromPushServerWithCompletionBlock:^(NSError *error) {
            if (!error) {
                NSLog(@"Unsubscribed from Push Notification server!!!");
            } else {
                NSLog(@"Error while unsubscribing from Push Notification server.");
            }
        }];
    }
    NCExternalSignalingController *extSignalingController = [self externalSignalingControllerForAccountId:removingAccount.accountId];
    [extSignalingController disconnect];
    [[NCSettingsController sharedInstance] cleanUserAndServerStoredValues];
    [[NCAPIController sharedInstance] removeProfileImageForAccount:removingAccount];
    [[NCDatabaseManager sharedInstance] removeAccountWithAccountId:removingAccount.accountId];
    [[[NCChatFileController alloc] init] deleteDownloadDirectoryForAccount:removingAccount];
    [[[NCRoomsManager sharedInstance] chatViewController] leaveChat];
    
    // Activate any of the inactive accounts
    NSArray *inactiveAccounts = [[NCDatabaseManager sharedInstance] inactiveAccounts];
    if (inactiveAccounts.count > 0) {
        TalkAccount *inactiveAccount = [inactiveAccounts objectAtIndex:0];
        [self setActiveAccountWithAccountId:inactiveAccount.accountId];
    }
    
    if (block) block(nil);
}

#pragma mark - App settings

- (void)configureAppSettings
{
    [self configureDefaultBrowser];
    [self configureLockScreen];
}

#pragma mark - Default browser

- (void)configureDefaultBrowser
{
    // Check supported browsers
    NSMutableArray *supportedBrowsers = [[NSMutableArray alloc] initWithObjects:@"Safari", nil];
    if ([[OpenInFirefoxControllerObjC sharedInstance] isFirefoxInstalled]) {
        [supportedBrowsers addObject:@"Firefox"];
    }
    _supportedBrowsers = supportedBrowsers;
    // Check if default browser is valid
    if (![supportedBrowsers containsObject:[NCUserDefaults defaultBrowser]]) {
        [NCUserDefaults setDefaultBrowser:@"Safari"];
    }
}

#pragma mark - Lock screen

- (void)configureLockScreen
{
    _lockScreenPasscode = [[NCKeyChainController sharedInstance].keychain stringForKey:kNCLockScreenPasscode];
}

- (void)setLockScreenPasscode:(NSString *)lockScreenPasscode
{
    _lockScreenPasscode = lockScreenPasscode;
    [[NCKeyChainController sharedInstance].keychain setString:lockScreenPasscode forKey:kNCLockScreenPasscode];
}

- (NCPasscodeType)lockScreenPasscodeType
{
    NCPasscodeType passcodeType = (NCPasscodeType)[[[NSUserDefaults standardUserDefaults] objectForKey:kNCLockScreenPasscodeType] integerValue];
    if (!passcodeType) {
        passcodeType = NCPasscodeTypeSimple;
        [[NSUserDefaults standardUserDefaults] setObject:@(passcodeType) forKey:kNCLockScreenPasscodeType];
    }
    return passcodeType;
}

- (void)setLockScreenPasscodeType:(NCPasscodeType)lockScreenPasscodeType
{
    _lockScreenPasscodeType = lockScreenPasscodeType;
    [[NSUserDefaults standardUserDefaults] setObject:@(lockScreenPasscodeType) forKey:kNCLockScreenPasscodeType];
}

#pragma mark - Signaling Configuration

- (void)getSignalingConfigurationWithCompletionBlock:(GetSignalingConfigCompletionBlock)block
{
    [[NCAPIController sharedInstance] getSignalingSettingsForAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSDictionary *settings, NSError *error) {
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        if (!error) {
            NSDictionary *signalingConfiguration = [[settings objectForKey:@"ocs"] objectForKey:@"data"];
            [self->_signalingConfigutations setObject:signalingConfiguration forKey:activeAccount.accountId];
            if (block) block(nil);
        } else {
            NSLog(@"Error while getting signaling configuration");
            if (block) block(error);
        }
    }];
}

// SetSignalingConfiguration should be called just once
- (void)setSignalingConfigurationForAccountId:(NSString *)accountId
{
    NSDictionary *signalingConfiguration = [_signalingConfigutations objectForKey:accountId];
    NSString *externalSignalingServer = nil;
    id server = [signalingConfiguration objectForKey:@"server"];
    if ([server isKindOfClass:[NSString class]] && ![server isEqualToString:@""]) {
        externalSignalingServer = server;
    }
    NSString *externalSignalingTicket = [signalingConfiguration objectForKey:@"ticket"];
    if (externalSignalingServer && externalSignalingTicket) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NCExternalSignalingController *extSignalingController = [self->_externalSignalingControllers objectForKey:accountId];
            if (!extSignalingController) {
                TalkAccount *account = [[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId];
                extSignalingController = [[NCExternalSignalingController alloc] initWithAccount:account server:externalSignalingServer andTicket:externalSignalingTicket];
                [self->_externalSignalingControllers setObject:extSignalingController forKey:accountId];
            }
        });
    }
}

- (NCExternalSignalingController *)externalSignalingControllerForAccountId:(NSString *)accountId
{
    return [_externalSignalingControllers objectForKey:accountId];
}

#pragma mark - Server Capabilities

- (void)getCapabilitiesWithCompletionBlock:(GetCapabilitiesCompletionBlock)block;
{
    [[NCAPIController sharedInstance] getServerCapabilitiesForAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSDictionary *serverCapabilities, NSError *error) {
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        if (!error && [serverCapabilities isKindOfClass:[NSDictionary class]]) {
            [[NCDatabaseManager sharedInstance] setServerCapabilities:serverCapabilities forAccountId:activeAccount.accountId];
            [self checkServerCapabilities];
            [[NSNotificationCenter defaultCenter] postNotificationName:NCServerCapabilitiesUpdatedNotification
                                                                object:self
                                                              userInfo:nil];
            if (block) block(nil);
        } else {
            NSLog(@"Error while getting server capabilities");
            if (block) block(error);
        }
    }];
}

- (void)checkServerCapabilities
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities  = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    if (serverCapabilities) {
        NSArray *talkFeatures = [serverCapabilities.talkCapabilities valueForKey:@"self"];
        if (!talkFeatures) {
            [[NSNotificationCenter defaultCenter] postNotificationName:NCTalkNotInstalledNotification
                                                                object:self
                                                              userInfo:nil];
        }
        if (![talkFeatures containsObject:kMinimumRequiredTalkCapability]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:NCOutdatedTalkVersionNotification
                                                                object:self
                                                              userInfo:nil];
        }
    }
}

- (NSInteger)chatMaxLengthConfigCapability
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities  = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    if (serverCapabilities) {
        NSInteger chatMaxLength = serverCapabilities.chatMaxLength;
        return chatMaxLength > 0 ? chatMaxLength : kDefaultChatMaxLength;
    }
    return kDefaultChatMaxLength;
}

- (BOOL)canCreateGroupAndPublicRooms
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities  = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    if (serverCapabilities) {
        return serverCapabilities.canCreate;
    }
    return YES;
}

#pragma mark - Push Notifications

- (void)subscribeForPushNotificationsForAccountId:(NSString *)accountId
{
#if !TARGET_IPHONE_SIMULATOR
    if ([self generatePushNotificationsKeyPairForAccountId:accountId]) {
        [[NCAPIController sharedInstance] subscribeAccount:[[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId] toNextcloudServerWithCompletionBlock:^(NSDictionary *responseDict, NSError *error) {
            if (!error) {
                NSLog(@"Subscribed to NC server successfully.");
                
                NSString *publicKey = [responseDict objectForKey:@"publicKey"];
                NSString *deviceIdentifier = [responseDict objectForKey:@"deviceIdentifier"];
                NSString *signature = [responseDict objectForKey:@"signature"];
                
                RLMRealm *realm = [RLMRealm defaultRealm];
                [realm beginWriteTransaction];
                NSPredicate *query = [NSPredicate predicateWithFormat:@"accountId = %@", accountId];
                TalkAccount *managedAccount = [TalkAccount objectsWithPredicate:query].firstObject;
                managedAccount.userPublicKey = publicKey;
                managedAccount.deviceIdentifier = deviceIdentifier;
                managedAccount.deviceSignature = signature;
                [realm commitWriteTransaction];
                
                [[NCAPIController sharedInstance] subscribeAccount:[[NCDatabaseManager sharedInstance] talkAccountForAccountId:accountId] toPushServerWithCompletionBlock:^(NSError *error) {
                    if (!error) {
                        RLMRealm *realm = [RLMRealm defaultRealm];
                        [realm beginWriteTransaction];
                        NSPredicate *query = [NSPredicate predicateWithFormat:@"accountId = %@", accountId];
                        TalkAccount *managedAccount = [TalkAccount objectsWithPredicate:query].firstObject;
                        managedAccount.pushNotificationSubscribed = YES;
                        [realm commitWriteTransaction];
                        NSLog(@"Subscribed to Push Notification server successfully.");
                    } else {
                        NSLog(@"Error while subscribing to Push Notification server.");
                    }
                }];
            } else {
                NSLog(@"Error while subscribing to NC server.");
            }
        }];
    }
#endif
}

- (BOOL)generatePushNotificationsKeyPairForAccountId:(NSString *)accountId
{
    EVP_PKEY *pkey;
    NSError *keyError;
    pkey = [self generateRSAKey:&keyError];
    if (keyError) {
        return NO;
    }
    
    // Extract publicKey, privateKey
    int len;
    char *keyBytes;
    
    // PublicKey
    BIO *publicKeyBIO = BIO_new(BIO_s_mem());
    PEM_write_bio_PUBKEY(publicKeyBIO, pkey);
    
    len = BIO_pending(publicKeyBIO);
    keyBytes  = malloc(len);
    
    BIO_read(publicKeyBIO, keyBytes, len);
    NSData *pnPublicKey = [NSData dataWithBytes:keyBytes length:len];
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm beginWriteTransaction];
    NSPredicate *query = [NSPredicate predicateWithFormat:@"accountId = %@", accountId];
    TalkAccount *managedAccount = [TalkAccount objectsWithPredicate:query].firstObject;
    managedAccount.pushNotificationPublicKey = pnPublicKey;
    [realm commitWriteTransaction];
    NSLog(@"Push Notifications Key Pair generated: \n%@", [[NSString alloc] initWithData:pnPublicKey encoding:NSUTF8StringEncoding]);
    
    // PrivateKey
    BIO *privateKeyBIO = BIO_new(BIO_s_mem());
    PEM_write_bio_PKCS8PrivateKey(privateKeyBIO, pkey, NULL, NULL, 0, NULL, NULL);
    
    len = BIO_pending(privateKeyBIO);
    keyBytes = malloc(len);
    
    BIO_read(privateKeyBIO, keyBytes, len);
    NSData *pnPrivateKey = [NSData dataWithBytes:keyBytes length:len];
    [[NCKeyChainController sharedInstance] setPushNotificationPrivateKey:pnPrivateKey forAccountId:accountId];
    EVP_PKEY_free(pkey);
    
    return YES;
}

- (EVP_PKEY *)generateRSAKey:(NSError **)error
{
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!pkey) {
        return NULL;
    }
    
    BIGNUM *bigNumber = BN_new();
    int exponent = RSA_F4;
    RSA *rsa = RSA_new();
    
    if (BN_set_word(bigNumber, exponent) < 0) {
        goto cleanup;
    }
    
    if (RSA_generate_key_ex(rsa, 2048, bigNumber, NULL) < 0) {
        goto cleanup;
    }
    
    if (!EVP_PKEY_set1_RSA(pkey, rsa)) {
        goto cleanup;
    }
    
cleanup:
    RSA_free(rsa);
    BN_free(bigNumber);
    
    return pkey;
}

@end
