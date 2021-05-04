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

#import <AVFoundation/AVFoundation.h>

#import "NCChatViewController.h"

#import "AFImageDownloader.h"
#import "CallKitManager.h"
#import "ChatMessageTableViewCell.h"
#import "DirectoryTableViewController.h"
#import "GroupedChatMessageTableViewCell.h"
#import "FileMessageTableViewCell.h"
#import "LocationMessageTableViewCell.h"
#import "SystemMessageTableViewCell.h"
#import "MapViewController.h"
#import "MessageSeparatorTableViewCell.h"
#import "DateHeaderView.h"
#import "FTPopOverMenu.h"
#import "PlaceholderView.h"
#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCChatController.h"
#import "NCChatMessage.h"
#import "NCDatabaseManager.h"
#import "NCMessageParameter.h"
#import "NCChatTitleView.h"
#import "NCMessageTextView.h"
#import "NCNavigationController.h"
#import "NCImageSessionManager.h"
#import "NCRoomsManager.h"
#import "NCSettingsController.h"
#import "NCUserInterfaceController.h"
#import "NCUtils.h"
#import "NSDate+DateTools.h"
#import "ReplyMessageView.h"
#import "QuotedMessageView.h"
#import "RoomInfoTableViewController.h"
#import "ShareConfirmationViewController.h"
#import "UIImageView+AFNetworking.h"
#import "UIImageView+Letters.h"
#import "UIView+Toast.h"
#import "BarButtonItemWithActivity.h"
#import "ShareItem.h"
#import "NCChatFileController.h"
#import "ShareLocationViewController.h"
#import "GeoLocationRichObject.h"
#import <NCCommunication/NCCommunication.h>
#import <QuickLook/QuickLook.h>

typedef enum NCChatMessageAction {
    kNCChatMessageActionReply = 1,
    kNCChatMessageActionCopy,
    kNCChatMessageActionResend,
    kNCChatMessageActionDelete,
    kNCChatMessageActionReplyPrivately,
    kNCChatMessageActionOpenFileInNextcloud
} NCChatMessageAction;

@interface NCChatViewController () <UIGestureRecognizerDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UIDocumentPickerDelegate, ShareConfirmationViewControllerDelegate, FileMessageTableViewCellDelegate, NCChatFileControllerDelegate, QLPreviewControllerDelegate, QLPreviewControllerDataSource, ChatMessageTableViewCellDelegate, ShareLocationViewControllerDelegate, LocationMessageTableViewCellDelegate>

@property (nonatomic, strong) NCChatController *chatController;
@property (nonatomic, strong) NCChatTitleView *titleView;
@property (nonatomic, strong) PlaceholderView *chatBackgroundView;
@property (nonatomic, strong) NSMutableDictionary *messages;
@property (nonatomic, strong) NSMutableArray *dateSections;
@property (nonatomic, strong) NSMutableArray *mentions;
@property (nonatomic, strong) NSMutableArray *autocompletionUsers;
@property (nonatomic, assign) BOOL hasRequestedInitialHistory;
@property (nonatomic, assign) BOOL hasReceiveInitialHistory;
@property (nonatomic, assign) BOOL hasReceiveNewMessages;
@property (nonatomic, assign) BOOL retrievingHistory;
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, assign) BOOL hasJoinedRoom;
@property (nonatomic, assign) BOOL leftChatWithVisibleChatVC;
@property (nonatomic, assign) BOOL offlineMode;
@property (nonatomic, assign) BOOL hasStoredHistory;
@property (nonatomic, assign) BOOL hasStopped;
@property (nonatomic, assign) NSInteger lastReadMessage;
@property (nonatomic, strong) NCChatMessage *unreadMessagesSeparator;
@property (nonatomic, assign) NSInteger chatViewPresentedTimestamp;
@property (nonatomic, strong) UIActivityIndicatorView *loadingHistoryView;
@property (nonatomic, assign) NSIndexPath *firstUnreadMessageIP;
@property (nonatomic, strong) UIButton *unreadMessageButton;
@property (nonatomic, strong) NSTimer *lobbyCheckTimer;
@property (nonatomic, strong) ReplyMessageView *replyMessageView;
@property (nonatomic, strong) UIImagePickerController *imagePicker;
@property (nonatomic, strong) BarButtonItemWithActivity *videoCallButton;
@property (nonatomic, strong) BarButtonItemWithActivity *voiceCallButton;
@property (nonatomic, assign) BOOL isPreviewControllerShown;
@property (nonatomic, strong) NSString *previewControllerFilePath;

@end

@implementation NCChatViewController

NSString * const NCChatViewControllerReplyPrivatelyNotification = @"NCChatViewControllerReplyPrivatelyNotification";

- (instancetype)initForRoom:(NCRoom *)room
{
    self = [super initWithTableViewStyle:UITableViewStylePlain];
    if (self) {
        self.room = room;
        self.chatController = [[NCChatController alloc] initForRoom:room];
        self.hidesBottomBarWhenPushed = YES;
        // Fixes problem with tableView contentSize on iOS 11
        self.tableView.estimatedRowHeight = 0;
        self.tableView.estimatedSectionHeaderHeight = 0;
        // Register a SLKTextView subclass, if you need any special appearance and/or behavior customisation.
        [self registerClassForTextView:[NCMessageTextView class]];
        // Register ReplyMessageView class, conforming to SLKTypingIndicatorProtocol, as a custom typing indicator view.
        [self registerClassForTypingIndicatorView:[ReplyMessageView class]];
        // Set image downloader to file preview imageviews.
        [FilePreviewImageView setSharedImageDownloader:[[NCAPIController sharedInstance] imageDownloader]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didUpdateRoom:) name:NCRoomsManagerDidUpdateRoomNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didJoinRoom:) name:NCRoomsManagerDidJoinRoomNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didLeaveRoom:) name:NCRoomsManagerDidLeaveRoomNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveInitialChatHistory:) name:NCChatControllerDidReceiveInitialChatHistoryNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveInitialChatHistoryOffline:) name:NCChatControllerDidReceiveInitialChatHistoryOfflineNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveChatHistory:) name:NCChatControllerDidReceiveChatHistoryNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveChatMessages:) name:NCChatControllerDidReceiveChatMessagesNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didSendChatMessage:) name:NCChatControllerDidSendChatMessageNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveChatBlocked:) name:NCChatControllerDidReceiveChatBlockedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveNewerCommonReadMessage:) name:NCChatControllerDidReceiveNewerCommonReadMessageNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveDeletedMessage:) name:NCChatControllerDidReceiveDeletedMessageNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    }
    
    return self;
}
    
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.titleView = [[NCChatTitleView alloc] init];
    self.titleView.frame = CGRectMake(0, 0, 800, 30);
    self.titleView.autoresizingMask=UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.titleView.title addTarget:self action:@selector(titleButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.titleView = _titleView;
    [self setTitleView];
    [self configureActionItems];
    
    // Disable room info, input bar and call buttons until joining the room
    [self disableRoomControls];
    
    self.messages = [[NSMutableDictionary alloc] init];
    self.mentions = [[NSMutableArray alloc] init];
    self.dateSections = [[NSMutableArray alloc] init];
    
    self.bounces = NO;
    self.shakeToClearEnabled = YES;
    self.keyboardPanningEnabled = YES;
    self.shouldScrollToBottomAfterKeyboardShows = NO;
    self.inverted = NO;
    
    [self.rightButton setTitle:@"" forState:UIControlStateNormal];
    [self.rightButton setImage:[UIImage imageNamed:@"send"] forState:UIControlStateNormal];
    self.rightButton.accessibilityLabel = NSLocalizedString(@"Send message", nil);
    self.rightButton.accessibilityHint = NSLocalizedString(@"Double tap to send message", nil);
    [self.leftButton setImage:[UIImage imageNamed:@"attachment"] forState:UIControlStateNormal];
    self.leftButton.accessibilityLabel = NSLocalizedString(@"Share a file from your Nextcloud", nil);
    self.leftButton.accessibilityHint = NSLocalizedString(@"Double tap to open file browser", nil);
    
    self.textInputbar.autoHideRightButton = NO;
    NSInteger chatMaxLength = [[NCSettingsController sharedInstance] chatMaxLengthConfigCapability];
    self.textInputbar.maxCharCount = chatMaxLength;
    self.textInputbar.counterStyle = SLKCounterStyleLimitExceeded;
    self.textInputbar.counterPosition = SLKCounterPositionTop;
    // Only show char counter when chat is limited to 1000 chars
    if (chatMaxLength == kDefaultChatMaxLength) {
        self.textInputbar.counterStyle = SLKCounterStyleCountdownReversed;
    }
    self.textInputbar.translucent = NO;
    self.textInputbar.contentInset = UIEdgeInsetsMake(5, 4, 5, 4);
    
    UIColor *defaultToolbarColor = [UIColor colorWithRed:247.0/255.0 green:247.0/255.0 blue:247.0/255.0 alpha:1.0];
    self.textInputbar.backgroundColor = defaultToolbarColor;
    [self.view setBackgroundColor:defaultToolbarColor];
    
    [self.textInputbar.editorTitle setTextColor:[UIColor darkGrayColor]];
    [self.textInputbar.editorLeftButton setTintColor:[UIColor systemBlueColor]];
    [self.textInputbar.editorRightButton setTintColor:[UIColor systemBlueColor]];
    
    self.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    self.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    self.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];
    
    if (@available(iOS 13.0, *)) {
        UIColor *themeColor = [NCAppBranding themeColor];
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = themeColor;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;
        
        [self.textInputbar setBackgroundColor:[UIColor secondarySystemBackgroundColor]];
        [self.view setBackgroundColor:[UIColor secondarySystemBackgroundColor]];
        [self.textInputbar.editorTitle setTextColor:[UIColor labelColor]];
        [self.textView.layer setBorderColor:[UIColor systemGray4Color].CGColor];
    }
    
    // Add long press gesture recognizer
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPressGesture.delegate = self;
    [self.tableView addGestureRecognizer:longPressGesture];
    self.longPressGesture = longPressGesture;
    
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ChatMessageTableViewCell class] forCellReuseIdentifier:ChatMessageCellIdentifier];
    [self.tableView registerClass:[ChatMessageTableViewCell class] forCellReuseIdentifier:ReplyMessageCellIdentifier];
    [self.tableView registerClass:[GroupedChatMessageTableViewCell class] forCellReuseIdentifier:GroupedChatMessageCellIdentifier];
    [self.tableView registerClass:[FileMessageTableViewCell class] forCellReuseIdentifier:FileMessageCellIdentifier];
    [self.tableView registerClass:[FileMessageTableViewCell class] forCellReuseIdentifier:GroupedFileMessageCellIdentifier];
    [self.tableView registerClass:[LocationMessageTableViewCell class] forCellReuseIdentifier:LocationMessageCellIdentifier];
    [self.tableView registerClass:[LocationMessageTableViewCell class] forCellReuseIdentifier:GroupedLocationMessageCellIdentifier];
    [self.tableView registerClass:[SystemMessageTableViewCell class] forCellReuseIdentifier:SystemMessageCellIdentifier];
    [self.tableView registerClass:[SystemMessageTableViewCell class] forCellReuseIdentifier:InvisibleSystemMessageCellIdentifier];
    [self.tableView registerClass:[MessageSeparatorTableViewCell class] forCellReuseIdentifier:MessageSeparatorCellIdentifier];
    [self.autoCompletionView registerClass:[ChatMessageTableViewCell class] forCellReuseIdentifier:AutoCompletionCellIdentifier];
    [self registerPrefixesForAutoCompletion:@[@"@"]];
    self.autoCompletionView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    if (@available(iOS 13.0, *)) {
        self.autoCompletionView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
    // Align separators to ChatMessageTableViewCell's title label
    self.autoCompletionView.separatorInset = UIEdgeInsetsMake(0, 50, 0, 0);
    
    // Chat placeholder view
    _chatBackgroundView = [[PlaceholderView alloc] init];
    [_chatBackgroundView.placeholderView setHidden:YES];
    [_chatBackgroundView.loadingView startAnimating];
    self.tableView.backgroundView = _chatBackgroundView;
    
    // Unread messages indicator
    _firstUnreadMessageIP = nil;
    _unreadMessageButton = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 126, 24)];
    _unreadMessageButton.backgroundColor = [NCAppBranding themeColor];
    [_unreadMessageButton setTitleColor:[NCAppBranding themeTextColor] forState:UIControlStateNormal];
    _unreadMessageButton.titleLabel.font = [UIFont systemFontOfSize:12];
    _unreadMessageButton.layer.cornerRadius = 12;
    _unreadMessageButton.clipsToBounds = YES;
    _unreadMessageButton.hidden = YES;
    _unreadMessageButton.translatesAutoresizingMaskIntoConstraints = NO;
    _unreadMessageButton.contentEdgeInsets = UIEdgeInsetsMake(0.0f, 10.0f, 0.0f, 10.0f);
    _unreadMessageButton.titleLabel.minimumScaleFactor = 0.9f;
    _unreadMessageButton.titleLabel.numberOfLines = 1;
    _unreadMessageButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    
    NSString *buttonText = NSLocalizedString(@"↓ New messages", nil);
    NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:12]};
    CGRect textSize = [buttonText boundingRectWithSize:CGSizeMake(300, 24) options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:NULL];
    CGFloat buttonWidth = textSize.size.width + 20;

    [_unreadMessageButton addTarget:self action:@selector(unreadMessagesButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    [_unreadMessageButton setTitle:buttonText forState:UIControlStateNormal];
    
    // Unread messages separator
    _unreadMessagesSeparator = [[NCChatMessage alloc] init];
    _unreadMessagesSeparator.messageId = kUnreadMessagesSeparatorIdentifier;
    
    self.hasStoredHistory = YES;
    
    [self.view addSubview:_unreadMessageButton];
    _chatViewPresentedTimestamp = [[NSDate date] timeIntervalSince1970];
    _lastReadMessage = _room.lastReadMessage;
    
    // Check if there's a stored pending message
    if (_room.pendingMessage != nil) {
        [self setChatMessage:self.room.pendingMessage];
    }
    
    NSDictionary *views = @{@"unreadMessagesButton": _unreadMessageButton,
                            @"textInputbar": self.textInputbar};
    NSDictionary *metrics = @{@"buttonWidth": @(buttonWidth)};
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[unreadMessagesButton(24)]-5-[textInputbar]" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(>=0)-[unreadMessagesButton(buttonWidth)]-(>=0)-|" options:0 metrics:metrics views:views]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.view attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual
                                                             toItem:_unreadMessageButton attribute:NSLayoutAttributeCenterX multiplier:1.f constant:0.f]];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self checkRoomControlsAvailability];
    
    if (!_hasReceiveInitialHistory && !_hasRequestedInitialHistory) {
        _hasRequestedInitialHistory = YES;
        [_chatController getInitialChatHistory];
    }
    
    _isVisible = YES;
    
    if (!_offlineMode) {
        [[NCRoomsManager sharedInstance] joinRoom:_room.token];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self savePendingMessage];
    
    _isVisible = NO;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    // Leave chat when the view controller has been removed from its parent view.
    if (self.isMovingFromParentViewController) {
        [self leaveChat];
    }
    
    [_videoCallButton hideActivityIndicator];
    [_voiceCallButton hideActivityIndicator];
}

- (void)stopChat
{
    _hasStopped = YES;
    [_chatController stopChatController];
    [self cleanChat];
}

- (void)resumeChat
{
    _hasStopped = NO;
    if (!_hasReceiveInitialHistory && !_hasRequestedInitialHistory) {
        _hasRequestedInitialHistory = YES;
        [_chatController getInitialChatHistory];
    }
}

- (void)leaveChat
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_lobbyCheckTimer invalidate];
    [_chatController stopChatController];
    
    // If this chat view controller is for the same room as the one owned by the rooms manager
    // then we should not try to leave the chat. Since we will leave the chat when the
    // chat view controller owned by rooms manager moves from parent view controller.
    if ([[NCRoomsManager sharedInstance].chatViewController.room.token isEqualToString:_room.token] &&
        [NCRoomsManager sharedInstance].chatViewController != self) {
        return;
    }
    
    [[NCRoomsManager sharedInstance] leaveChatInRoom:_room.token];
    
    // Remove chat view controller pointer if this chat is owned by rooms manager
    // and the chat view is moving from parent view controller
    if ([NCRoomsManager sharedInstance].chatViewController == self) {
        [NCRoomsManager sharedInstance].chatViewController = nil;
    }
}

- (void)setChatMessage:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = message;
    });
}

#pragma mark - App lifecycle notifications

-(void)appDidBecomeActive:(NSNotification*)notification
{
    // Check if new messages were added while the app was inactive (eg. via background-refresh)
    NCChatMessage *lastMessage = [[self->_messages objectForKey:[self->_dateSections lastObject]] lastObject];
    
    if (lastMessage) {
        [self.chatController checkForNewMessagesFromMessageId:lastMessage.messageId];
        [self checkLastCommonReadMessage];
    }
    
    if (!_offlineMode) {
        [[NCRoomsManager sharedInstance] joinRoom:_room.token];
    }
}

-(void)appWillResignActive:(NSNotification*)notification
{
    _hasReceiveNewMessages = NO;
    _leftChatWithVisibleChatVC = YES;
    [self removeUnreadMessagesSeparator];
    [_chatController stopChatController];
    [[NCRoomsManager sharedInstance] leaveChatInRoom:_room.token];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            // We use a CGColor so we loose the automatic color changing of dynamic colors -> update manually
            [self.textView.layer setBorderColor:[UIColor systemGray4Color].CGColor];
        }
    }
}

#pragma mark - Configuration

- (void)setTitleView
{
    [_titleView.title setTitle:_room.displayName forState:UIControlStateNormal];
    
    // Set room image
    switch (_room.type) {
        case kNCRoomTypeOneToOne:
        {
            // Request user avatar to the server and set it if exist
            [_titleView.image setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:_room.name andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                    placeholderImage:nil success:nil failure:nil];
        }
            break;
        case kNCRoomTypeGroup:
            [_titleView.image setImage:[UIImage imageNamed:@"group-15"]];
            [_titleView.image setContentMode:UIViewContentModeCenter];
            break;
        case kNCRoomTypePublic:
            [_titleView.image setImage:[UIImage imageNamed:@"public-15"]];
            [_titleView.image setContentMode:UIViewContentModeCenter];
            break;
        case kNCRoomTypeChangelog:
            [_titleView.image setImage:[UIImage imageNamed:@"changelog"]];
            break;
        default:
            break;
    }
    
    // Set objectType image
    if ([_room.objectType isEqualToString:NCRoomObjectTypeFile]) {
        [_titleView.image setImage:[UIImage imageNamed:@"file-conv-15"]];
        [_titleView.image setContentMode:UIViewContentModeCenter];
    } else if ([_room.objectType isEqualToString:NCRoomObjectTypeSharePassword]) {
        [_titleView.image setImage:[UIImage imageNamed:@"pass-conv-15"]];
        [_titleView.image setContentMode:UIViewContentModeCenter];
    }
    
    _titleView.title.accessibilityHint = NSLocalizedString(@"Double tap to go to conversation information", nil);
}

- (void)configureActionItems
{
    UIImage *videoCallImage = [[UIImage imageNamed:@"video"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage *voiceCallImage = [[UIImage imageNamed:@"phone"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    
    CGFloat buttonWidth = 24.0;
    CGFloat buttonPadding = 30.0;
    
    _videoCallButton = [[BarButtonItemWithActivity alloc] initWithWidth:buttonWidth withImage:videoCallImage];
    [_videoCallButton.innerButton addTarget:self action:@selector(videoCallButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    
    _videoCallButton.accessibilityLabel = NSLocalizedString(@"Video call", nil);
    _videoCallButton.accessibilityHint = NSLocalizedString(@"Double tap to start a video call", nil);
    
    
    _voiceCallButton = [[BarButtonItemWithActivity alloc] initWithWidth:buttonWidth withImage:voiceCallImage];
    [_voiceCallButton.innerButton addTarget:self action:@selector(voiceCallButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    
    _voiceCallButton.accessibilityLabel = NSLocalizedString(@"Voice call", nil);
    _voiceCallButton.accessibilityHint = NSLocalizedString(@"Double tap to start a voice call", nil);
    
    UIBarButtonItem *fixedSpace =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                                                    target:nil
                                                    action:nil];
    fixedSpace.width = buttonPadding;
    
    self.navigationItem.rightBarButtonItems = @[_videoCallButton, fixedSpace, _voiceCallButton];
}

#pragma mark - User Interface

- (void)disableRoomControls
{
    _titleView.userInteractionEnabled = NO;

    [_videoCallButton hideActivityIndicator];
    [_voiceCallButton hideActivityIndicator];
    [_videoCallButton setEnabled:NO];
    [_voiceCallButton setEnabled:NO];
    
    [self.leftButton setEnabled:NO];
    [self.rightButton setEnabled:NO];
    self.textInputbar.userInteractionEnabled = NO;
}

- (void)checkRoomControlsAvailability
{
    if (_hasJoinedRoom) {
        // Enable room info, input bar and call buttons
        _titleView.userInteractionEnabled = YES;
        [_videoCallButton setEnabled:YES];
        [_voiceCallButton setEnabled:YES];
        
        [self.leftButton setEnabled:YES];
        self.textInputbar.userInteractionEnabled = YES;
        
        if ([self.textView.text length] > 0) {
            [self.rightButton setEnabled:YES];
        }
    }
    
    if (![_room userCanStartCall] && !_room.hasCall) {
        // Disable call buttons
        [_videoCallButton setEnabled:NO];
        [_voiceCallButton setEnabled:NO];
    }
    
    if (_room.readOnlyState == NCRoomReadOnlyStateReadOnly || [self shouldPresentLobbyView]) {
        // Hide text input
        self.textInputbarHidden = YES;
        // Disable call buttons
        [_videoCallButton setEnabled:NO];
        [_voiceCallButton setEnabled:NO];
    } else if ([self isTextInputbarHidden]) {
        // Show text input if it was hidden in a previous state
        [self setTextInputbarHidden:NO animated:YES];
    }
    
    if (_presentedInCall) {
        // Remove call buttons
        self.navigationItem.rightBarButtonItems = nil;
    }
}

- (void)checkLobbyState
{
    if ([self shouldPresentLobbyView]) {
        [_chatBackgroundView.placeholderText setText:NSLocalizedString(@"You are currently waiting in the lobby", nil)];
        [_chatBackgroundView setImage:[UIImage imageNamed:@"lobby-placeholder"]];
        if (_room.lobbyTimer > 0) {
            NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:_room.lobbyTimer];
            NSString *meetingStart = [NCUtils readableDateFromDate:date];
            NSString *placeHolderText = [NSString stringWithFormat:NSLocalizedString(@"You are currently waiting in the lobby.\nThis meeting is scheduled for\n%@", nil), meetingStart];
            [_chatBackgroundView.placeholderText setText:placeHolderText];
            [_chatBackgroundView setImage:[UIImage imageNamed:@"lobby-placeholder"]];
        }
        [_chatBackgroundView.placeholderView setHidden:NO];
        [_chatBackgroundView.loadingView stopAnimating];
        [_chatBackgroundView.loadingView setHidden:YES];
        // Clear current chat since chat history will be retrieve when lobby is disabled
        [self cleanChat];
    } else {
        [_chatBackgroundView.placeholderText setText:NSLocalizedString(@"No messages yet, start the conversation!", nil)];
        [_chatBackgroundView setImage:[UIImage imageNamed:@"chat-placeholder"]];
        [_chatBackgroundView.placeholderView setHidden:YES];
        [_chatBackgroundView.loadingView startAnimating];
        [_chatBackgroundView.loadingView setHidden:NO];
        // Stop checking lobby flag
        [_lobbyCheckTimer invalidate];
        // Retrieve initial chat history
        if (!_hasReceiveInitialHistory && !_hasRequestedInitialHistory) {
            _hasRequestedInitialHistory = YES;
            [_chatController getInitialChatHistory];
        }
    }
    [self checkRoomControlsAvailability];
}

- (void)setOfflineFooterView
{
    UILabel *footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 350, 24)];
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.textColor = [UIColor lightGrayColor];
    footerLabel.font = [UIFont systemFontOfSize:12.0];
    footerLabel.backgroundColor = [UIColor clearColor];
    footerLabel.text = NSLocalizedString(@"Offline, only showing downloaded messages", nil);
    self.tableView.tableFooterView = footerLabel;
    self.tableView.tableFooterView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    if (@available(iOS 13.0, *)) {
        footerLabel.textColor = [UIColor secondaryLabelColor];
        self.tableView.tableFooterView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
}

#pragma mark - Utils

- (NSInteger)getLastReadMessage
{
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityChatReadMarker]) {
        return _lastReadMessage;
    }
    return 0;
}

- (NCChatMessage *)getFirstRealMessage
{
    for (int section = 0; section < [_dateSections count]; section++) {
        NSDate *dateSection = [_dateSections objectAtIndex:section];
        NSMutableArray *messagesInSection = [_messages objectForKey:dateSection];
        
        for (int message = 0; message < [messagesInSection count]; message++) {
            NCChatMessage *chatMessage = [messagesInSection objectAtIndex:message];
            
            // Ignore temporary messages
            if (chatMessage && chatMessage.messageId > 0) {
                return chatMessage;
            }
        }
    }
    
    return nil;
}

- (NSString *)getHeaderStringFromDate:(NSDate *)date
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.doesRelativeDateFormatting = YES;
    return [formatter stringFromDate:date];
}

- (NSString *)createSendingMessage:(NSString *)text
{
    NSString *sendingMessage = [text copy];
    for (NCMessageParameter *mention in _mentions) {
        sendingMessage = [sendingMessage stringByReplacingOccurrencesOfString:mention.name withString:mention.parameterId];
    }
    _mentions = [[NSMutableArray alloc] init];
    return sendingMessage;
}

- (void)presentJoinError:(NSString *)alertMessage
{
    NSString *alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Could not join %@", nil), _room.displayName];
    if (_room.type == kNCRoomTypeOneToOne) {
        alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Could not join conversation with %@", nil), _room.displayName];
    }

    UIAlertController * alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                    message:alertMessage
                                                             preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];
    [alert addAction:okButton];
    [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
}

#pragma mark - Temporary messages

- (NCChatMessage *)createTemporaryMessage:(NSString *)text replyToMessage:(NCChatMessage *)parentMessage
{
    NCChatMessage *temporaryMessage = [[NCChatMessage alloc] init];
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    temporaryMessage.accountId = activeAccount.accountId;
    temporaryMessage.actorDisplayName = activeAccount.userDisplayName;
    temporaryMessage.actorId = activeAccount.userId;
    temporaryMessage.timestamp = [[NSDate date] timeIntervalSince1970];
    temporaryMessage.token = _room.token;
    NSString *sendingMessage = [[text copy] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    temporaryMessage.message = sendingMessage;
    NSString * referenceId = [NSString stringWithFormat:@"temp-%f",[[NSDate date] timeIntervalSince1970] * 1000];
    temporaryMessage.referenceId = [NCUtils sha1FromString:referenceId];
    temporaryMessage.internalId = referenceId;
    temporaryMessage.isTemporary = YES;
    temporaryMessage.parentId = parentMessage.internalId;

    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        [realm addObject:temporaryMessage];
    }];
    
    NCChatMessage *unmanagedTemporaryMessage = [[NCChatMessage alloc] initWithValue:temporaryMessage];
    return unmanagedTemporaryMessage;
}

- (void)appendTemporaryMessage:(NCChatMessage *)temporaryMessage
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger lastSectionBeforeUpdate = self->_dateSections.count - 1;
        NSMutableArray *messages = [[NSMutableArray alloc] initWithObjects:temporaryMessage, nil];
        [self appendMessages:messages inDictionary:self->_messages];
        
        NSMutableArray *messagesForLastDate = [self->_messages objectForKey:[self->_dateSections lastObject]];
        NSIndexPath *lastMessageIndexPath = [NSIndexPath indexPathForRow:messagesForLastDate.count - 1 inSection:self->_dateSections.count - 1];
        
        [self.tableView beginUpdates];
        NSInteger newLastSection = self->_dateSections.count - 1;
        BOOL newSection = lastSectionBeforeUpdate != newLastSection;
        if (newSection) {
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:newLastSection] withRowAnimation:UITableViewRowAnimationNone];
        } else {
            [self.tableView insertRowsAtIndexPaths:@[lastMessageIndexPath] withRowAnimation:UITableViewRowAnimationNone];
        }
        [self.tableView endUpdates];
        
        [self.tableView scrollToRowAtIndexPath:lastMessageIndexPath atScrollPosition:UITableViewScrollPositionNone animated:YES];
    });
}

- (void)removePermanentlyTemporaryMessage:(NCChatMessage *)temporaryMessage
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm transactionWithBlock:^{
        NCChatMessage *managedTemporaryMessage = [NCChatMessage objectsWhere:@"referenceId = %@ AND isTemporary = true", temporaryMessage.referenceId].firstObject;
        if (managedTemporaryMessage) {
            [realm deleteObject:managedTemporaryMessage];
        }
    }];
    [self removeTemporaryMessages:@[temporaryMessage]];
}

- (void)removeTemporaryMessages:(NSArray *)messages
{
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NCChatMessage *message in messages) {
            NSIndexPath *indexPath = [self indexPathForMessage:message];
            if (indexPath) {
                [self removeMessageAtIndexPath:indexPath];
            }
        }
    });
}

- (void)setFailedStatusToMessageWithReferenceId:(NSString *)referenceId
{
    NSMutableArray *reloadIndexPaths = [NSMutableArray new];
    NSIndexPath *indexPath = [self indexPathForMessageWithReferenceId:referenceId];
    if (indexPath) {
        [reloadIndexPaths addObject:indexPath];
        
        // Set failed status
        NSDate *keyDate = [_dateSections objectAtIndex:indexPath.section];
        NSMutableArray *messages = [_messages objectForKey:keyDate];
        NCChatMessage *failedMessage = [messages objectAtIndex:indexPath.row];
        failedMessage.sendingFailed = YES;
    }
    
    [self.tableView beginUpdates];
    [self.tableView reloadRowsAtIndexPaths:reloadIndexPaths withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView endUpdates];
}

#pragma mark - Message updates

- (void)updateMessageWithReferenceId:(NSString *)referenceId withMessage:(NCChatMessage *)updatedMessage
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *reloadIndexPaths = [NSMutableArray new];
        NSIndexPath *indexPath = [self indexPathForMessageWithReferenceId:referenceId];
        if (indexPath) {
            [reloadIndexPaths addObject:indexPath];
            NSDate *keyDate = [self->_dateSections objectAtIndex:indexPath.section];
            NSMutableArray *messages = [self->_messages objectForKey:keyDate];
            NCChatMessage *currentMessage = messages[indexPath.row];
            updatedMessage.isGroupMessage = currentMessage.isGroupMessage && ![currentMessage.actorType isEqualToString:@"bots"];
            messages[indexPath.row] = updatedMessage;
        }
        
        [self.tableView beginUpdates];
        [self.tableView reloadRowsAtIndexPaths:reloadIndexPaths withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView endUpdates];
    });
}

#pragma mark - Action Methods

- (void)titleButtonPressed:(id)sender
{
    RoomInfoTableViewController *roomInfoVC = [[RoomInfoTableViewController alloc] initForRoom:_room fromChatViewController:self];
    [self.navigationController pushViewController:roomInfoVC animated:YES];
    
    // When returning from RoomInfoTableViewController the default keyboard will be shown, so the height might be wrong -> make sure the keyboard is hidden
    [self dismissKeyboard:YES];
}

- (void)unreadMessagesButtonPressed:(id)sender
{
    if (_firstUnreadMessageIP) {
        [self.tableView scrollToRowAtIndexPath:_firstUnreadMessageIP atScrollPosition:UITableViewScrollPositionNone animated:YES];
    }
}

- (void)videoCallButtonPressed:(id)sender
{
    [_videoCallButton showActivityIndicator];
    [[CallKitManager sharedInstance] startCall:_room.token withVideoEnabled:YES andDisplayName:_room.displayName withAccountId:_room.accountId];
}

- (void)voiceCallButtonPressed:(id)sender
{
    [_voiceCallButton showActivityIndicator];
    [[CallKitManager sharedInstance] startCall:_room.token withVideoEnabled:NO andDisplayName:_room.displayName withAccountId:_room.accountId];
}

- (void)sendChatMessage:(NSString *)message fromInputField:(BOOL)fromInputField
{
    // Create temporary message
    NSString *referenceId = nil;
    NCChatMessage *replyToMessage = (_replyMessageView.isVisible && fromInputField) ? _replyMessageView.message : nil;
    
    if ([[NCSettingsController sharedInstance] serverHasTalkCapability:kCapabilityChatReferenceId]) {
        NCChatMessage *temporaryMessage = [self createTemporaryMessage:message replyToMessage:replyToMessage];
        referenceId = temporaryMessage.referenceId;
        [self appendTemporaryMessage:temporaryMessage];
    }
    
    // Send message
    NSString *sendingText = [self createSendingMessage:message];
    NSInteger replyTo = replyToMessage ? replyToMessage.messageId : -1;
    [_chatController sendChatMessage:sendingText replyTo:replyTo referenceId:referenceId];
}

- (void)didPressRightButton:(id)sender
{
    [self sendChatMessage:self.textView.text fromInputField:YES];
    [_replyMessageView dismiss];
    [super didPressRightButton:sender];
    
    // Input field is empty after send -> this clears a previously saved pending message
    [self savePendingMessage];
}

- (void)didPressLeftButton:(id)sender
{
    [self presentAttachmentsOptions];
    [super didPressLeftButton:sender];
}

- (void)presentAttachmentsOptions
{
    UIAlertController *optionsActionSheet = [UIAlertController alertControllerWithTitle:nil
                                                                                message:nil
                                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction *cameraAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Camera", nil)
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^void (UIAlertAction *action) {
        [self checkAndPresentCamera];
    }];
    [cameraAction setValue:[[UIImage imageNamed:@"camera"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *photoLibraryAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Photo Library", nil)
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^void (UIAlertAction *action) {
        [self presentPhotoLibrary];
    }];
    [photoLibraryAction setValue:[[UIImage imageNamed:@"photos"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *shareLocationAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Location", nil)
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^void (UIAlertAction *action) {
        [self presentShareLocation];
    }];
    [shareLocationAction setValue:[[UIImage imageNamed:@"location"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *filesAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Files", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:^void (UIAlertAction *action) {
        [self presentDocumentPicker];
    }];
    [filesAction setValue:[[UIImage imageNamed:@"files"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    UIAlertAction *ncFilesAction = [UIAlertAction actionWithTitle:filesAppName
                                                     style:UIAlertActionStyleDefault
                                                   handler:^void (UIAlertAction *action) {
        [self presentNextcloudFilesBrowser];
    }];
    [ncFilesAction setValue:[[UIImage imageNamed:@"logo-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forKey:@"image"];
    
    if ([UIImagePickerController isSourceTypeAvailable: UIImagePickerControllerSourceTypeCamera]) {
        [optionsActionSheet addAction:cameraAction];
    }
    
    [optionsActionSheet addAction:photoLibraryAction];
    [optionsActionSheet addAction:shareLocationAction];
    [optionsActionSheet addAction:filesAction];
    [optionsActionSheet addAction:ncFilesAction];
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = self.leftButton;
    optionsActionSheet.popoverPresentationController.sourceRect = self.leftButton.frame;
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (void)presentNextcloudFilesBrowser
{
    DirectoryTableViewController *directoryVC = [[DirectoryTableViewController alloc] initWithPath:@"" inRoom:_room.token];
    NCNavigationController *fileSharingNC = [[NCNavigationController alloc] initWithRootViewController:directoryVC];
    [self presentViewController:fileSharingNC animated:YES completion:nil];
}

- (void)checkAndPresentCamera
{
    // https://stackoverflow.com/a/20464727/2512312
    NSString *mediaType = AVMediaTypeVideo;
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    
    if(authStatus == AVAuthorizationStatusAuthorized) {
        [self presentCamera];
        return;
    } else if(authStatus == AVAuthorizationStatusNotDetermined){
        [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
            if(granted){
                [self presentCamera];
            }
        }];
        return;
    }
    
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:NSLocalizedString(@"Could not access camera", nil)
                                 message:NSLocalizedString(@"Camera access is not allowed. Check your settings.", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", nil)
                               style:UIAlertActionStyleDefault
                               handler:nil];
    
    [alert addAction:okButton];
    [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
}

- (void)presentCamera
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentPhotoLibrary
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentShareLocation
{
    ShareLocationViewController *shareLocationVC = [[ShareLocationViewController alloc] init];
    shareLocationVC.delegate = self;
    NCNavigationController *shareLocationNC = [[NCNavigationController alloc] initWithRootViewController:shareLocationVC];
    [self presentViewController:shareLocationNC animated:YES completion:nil];
}

- (void)presentDocumentPicker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
        documentPicker.delegate = self;
        [self presentViewController:documentPicker animated:YES completion:nil];
    });
}

- (void)didPressReply:(NCChatMessage *)message {
    // Make sure we get a smooth animation after dismissing the context menu
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL isAtBottom = [self shouldScrollOnNewMessages];
        
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        self.replyMessageView = (ReplyMessageView *)self.typingIndicatorProxyView;
        [self.replyMessageView presentReplyViewWithMessage:message withUserId:activeAccount.userId];
        [self presentKeyboard:YES];

        // Make sure we're really at the bottom after showing the replyMessageView
        if (isAtBottom) {
            [self.tableView slk_scrollToBottomAnimated:NO];
        }
    });
}

- (void)didPressReplyPrivately:(NCChatMessage *)message {
    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
    [userInfo setObject:message.actorId forKey:@"actorId"];
    [[NSNotificationCenter defaultCenter] postNotificationName:NCChatViewControllerReplyPrivatelyNotification
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)didPressResend:(NCChatMessage *)message {
    // Make sure there's no unread message separator, as the indexpath could be invalid after removing a message
    [self removeUnreadMessagesSeparator];
    
    [self removePermanentlyTemporaryMessage:message];
    [self sendChatMessage:message.message fromInputField:NO];
}

- (void)didPressCopy:(NCChatMessage *)message {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = message.parsedMessage.string;
    [self.view makeToast:NSLocalizedString(@"Message copied", nil) duration:1.5 position:CSToastPositionCenter];
}

- (void)didPressDelete:(NCChatMessage *)message {
    if (message.sendingFailed) {
        [self removePermanentlyTemporaryMessage:message];
    } else {
        // Set deleting state
        NCChatMessage *deletingMessage = [message copy];
        deletingMessage.message = NSLocalizedString(@"Deleting message", nil);
        deletingMessage.isDeleting = YES;
        [self updateMessageWithReferenceId:deletingMessage.referenceId withMessage:deletingMessage];
        // Delete message
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        [[NCAPIController sharedInstance] deleteChatMessageInRoom:self->_room.token withMessageId:message.messageId forAccount:activeAccount withCompletionBlock:^(NSDictionary *messageDict, NSError *error, NSInteger statusCode) {
            if (!error && messageDict) {
                if (statusCode == 202) {
                    [self.view makeToast:NSLocalizedString(@"Message deleted successfully, but Matterbridge is configured and the message might already be distributed to other services", nil) duration:5 position:CSToastPositionCenter];
                } else if (statusCode == 200) {
                    [self.view makeToast:NSLocalizedString(@"Message deleted successfully", nil) duration:3 position:CSToastPositionCenter];
                }
                NCChatMessage *deleteMessage = [NCChatMessage messageWithDictionary:[messageDict objectForKey:@"parent"] andAccountId:activeAccount.accountId];
                if (deleteMessage) {
                    [self updateMessageWithReferenceId:deleteMessage.referenceId withMessage:deleteMessage];
                }
            } else if (error) {
                if (statusCode == 400) {
                    [self.view makeToast:NSLocalizedString(@"Message could not be deleted because it is too old", nil) duration:5 position:CSToastPositionCenter];
                } else if (statusCode == 405) {
                    [self.view makeToast:NSLocalizedString(@"Only normal chat messages can be deleted", nil) duration:5 position:CSToastPositionCenter];
                } else {
                    [self.view makeToast:NSLocalizedString(@"An error occurred while deleting the message", nil) duration:5 position:CSToastPositionCenter];
                }
                // Set back original message on failure
                [self updateMessageWithReferenceId:message.referenceId withMessage:message];
            }
        }];
    }
}

- (void)didPressOpenInNextcloud:(NCChatMessage *)message {
    if (message.file) {
        [NCUtils openFileInNextcloudAppOrBrowser:message.file.path withFileLink:message.file.link];
    }
}

#pragma mark - UIImagePickerController Delegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    ShareConfirmationViewController *shareConfirmationVC = [[ShareConfirmationViewController alloc] initWithRoom:_room account:activeAccount serverCapabilities:serverCapabilities];
    shareConfirmationVC.delegate = self;
    shareConfirmationVC.isModal = YES;
    NCNavigationController *navigationController = [[NCNavigationController alloc] initWithRootViewController:shareConfirmationVC];
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self presentViewController:navigationController animated:YES completion:^{
                [shareConfirmationVC.shareItemController addItemWithImage:image];
            }];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = [info objectForKey:UIImagePickerControllerMediaURL];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self presentViewController:navigationController animated:YES completion:^{
                [shareConfirmationVC.shareItemController addItemWithURL:videoURL];
            }];
        }];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UIDocumentPickerViewController Delegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url
{
    [self shareDocumentsWithURLs:@[url] fromController:controller];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    [self shareDocumentsWithURLs:urls fromController:controller];
}

- (void)shareDocumentsWithURLs:(NSArray<NSURL *> *)urls fromController:(UIDocumentPickerViewController *)controller {
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    ShareConfirmationViewController *shareConfirmationVC = [[ShareConfirmationViewController alloc] initWithRoom:_room account:activeAccount serverCapabilities:serverCapabilities];
    shareConfirmationVC.delegate = self;
    shareConfirmationVC.isModal = YES;
    NCNavigationController *navigationController = [[NCNavigationController alloc] initWithRootViewController:shareConfirmationVC];
    
    if (controller.documentPickerMode == UIDocumentPickerModeImport) {
        [self presentViewController:navigationController animated:YES completion:^{
            for (NSURL* url in urls) {
                [shareConfirmationVC.shareItemController addItemWithURL:url];
            }
        }];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    
}

#pragma mark - ShareConfirmationViewController Delegate

- (void)shareConfirmationViewControllerDidFailed:(ShareConfirmationViewController *)viewController
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)shareConfirmationViewControllerDidFinish:(ShareConfirmationViewController *)viewController
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - ShareLocationViewController Delegate

-(void)shareLocationViewController:(ShareLocationViewController *)viewController didSelectLocationWithLatitude:(double)latitude longitude:(double)longitude andName:(NSString *)name
{
    GeoLocationRichObject *richObject = [GeoLocationRichObject geoLocationRichObjectWithLatitude:latitude longitude:longitude name:name];
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    [[NCAPIController sharedInstance] shareRichObject:richObject.richObjectDictionary inRoom:_room.token forAccount:activeAccount withCompletionBlock:^(NSError *error) {
        if (error) {
            NSLog(@"Error sharing rich object: %@", error);
        }
    }];
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Gesture recognizer

-(void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer
{
    if (@available(iOS 13.0, *)) {
        // Use native contextmenus on iOS >= 13
        return;
    }
    
    CGPoint point = [gestureRecognizer locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (indexPath != nil && gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
        NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
        if (!message.isSystemMessage) {
            // Select cell
            [self.tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
            
            // Create menu
            FTPopOverMenuConfiguration *menuConfiguration = [[FTPopOverMenuConfiguration alloc] init];
            menuConfiguration.menuIconMargin = 12;
            menuConfiguration.menuTextMargin = 12;
            menuConfiguration.imageSize = CGSizeMake(20, 20);
            menuConfiguration.separatorInset = UIEdgeInsetsMake(0, 44, 0, 0);
            menuConfiguration.menuRowHeight = 44;
            menuConfiguration.autoMenuWidth = YES;
            menuConfiguration.textFont = [UIFont systemFontOfSize:15];
            menuConfiguration.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
            menuConfiguration.borderWidth = 0;
            menuConfiguration.shadowOpacity = 0;
            menuConfiguration.roundedImage = NO;
            menuConfiguration.defaultSelection = YES;
            
            NSMutableArray *menuArray = [NSMutableArray new];
            // Reply option
            if (message.isReplyable && !message.isDeleting && !_offlineMode) {
                NSDictionary *replyInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionReply) forKey:@"action"];
                FTPopOverMenuModel *replyModel = [[FTPopOverMenuModel alloc] initWithTitle:NSLocalizedString(@"Reply", nil) image:[UIImage imageNamed:@"reply"] userInfo:replyInfo];
                [menuArray addObject:replyModel];
                
                // Reply-privately option (only to other users and not in one-to-one)
                TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
                if (_room.type != kNCRoomTypeOneToOne && [message.actorType isEqualToString:@"users"] && ![message.actorId isEqualToString:activeAccount.userId] )
                {
                    NSDictionary *replyPrivatInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionReplyPrivately) forKey:@"action"];
                    FTPopOverMenuModel *replyPrivatModel = [[FTPopOverMenuModel alloc] initWithTitle:NSLocalizedString(@"Reply Privately", nil) image:[UIImage imageNamed:@"reply"] userInfo:replyPrivatInfo];
                    [menuArray addObject:replyPrivatModel];
                }
            }

            // Re-send option
            if (message.sendingFailed && !_offlineMode) {
                NSDictionary *replyInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionResend) forKey:@"action"];
                FTPopOverMenuModel *replyModel = [[FTPopOverMenuModel alloc] initWithTitle:NSLocalizedString(@"Resend", nil) image:[UIImage imageNamed:@"refresh"] userInfo:replyInfo];
                [menuArray addObject:replyModel];
            }
            
            // Copy option
            NSDictionary *copyInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionCopy) forKey:@"action"];
            FTPopOverMenuModel *copyModel = [[FTPopOverMenuModel alloc] initWithTitle:NSLocalizedString(@"Copy", nil) image:[UIImage imageNamed:@"clippy"] userInfo:copyInfo];
            [menuArray addObject:copyModel];
            
            // Open in nextcloud option
            if (message.file && !_offlineMode) {
                NSDictionary *openInNextcloudInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionOpenFileInNextcloud) forKey:@"action"];
                NSString *openInNextcloudTitle = [NSString stringWithFormat:NSLocalizedString(@"Open in %@", nil), filesAppName];
                FTPopOverMenuModel *openInNextcloudModel = [[FTPopOverMenuModel alloc] initWithTitle:openInNextcloudTitle image:[[UIImage imageNamed:@"logo-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] userInfo:openInNextcloudInfo];
                [menuArray addObject:openInNextcloudModel];
            }
            
            // Delete option
            if (message.sendingFailed || [message isDeletableForAccount:[[NCDatabaseManager sharedInstance] activeAccount] andParticipantType:_room.participantType]) {
                NSDictionary *replyInfo = [NSDictionary dictionaryWithObject:@(kNCChatMessageActionDelete) forKey:@"action"];
                FTPopOverMenuModel *replyModel = [[FTPopOverMenuModel alloc] initWithTitle:NSLocalizedString(@"Delete", nil) image:[UIImage imageNamed:@"delete"] userInfo:replyInfo];
                [menuArray addObject:replyModel];
            }
            
            CGRect frame = [self.tableView rectForRowAtIndexPath:indexPath];
            CGPoint yOffset = self.tableView.contentOffset;
            CGRect cellRect = CGRectMake(frame.origin.x, (frame.origin.y - yOffset.y), frame.size.width, frame.size.height);
            
            __weak NCChatViewController *weakSelf = self;
            [FTPopOverMenu showFromSenderFrame:cellRect withMenuArray:menuArray imageArray:nil configuration:menuConfiguration doneBlock:^(NSInteger selectedIndex) {
                [weakSelf.tableView deselectRowAtIndexPath:indexPath animated:YES];
                FTPopOverMenuModel *model = [menuArray objectAtIndex:selectedIndex];
                NCChatMessageAction action = (NCChatMessageAction)[[model.userInfo objectForKey:@"action"] integerValue];
                switch (action) {
                    case kNCChatMessageActionReply:
                    {
                        [weakSelf didPressReply:message];
                    }
                        break;
                    case kNCChatMessageActionReplyPrivately:
                    {
                        [weakSelf didPressReplyPrivately:message];
                    }
                        break;
                    case kNCChatMessageActionCopy:
                    {
                        [weakSelf didPressCopy:message];
                    }
                        break;
                    case kNCChatMessageActionResend:
                    {
                        [weakSelf didPressResend:message];
                    }
                        break;
                    case kNCChatMessageActionOpenFileInNextcloud:
                    {
                        [weakSelf didPressOpenInNextcloud:message];
                    }
                        break;
                    case kNCChatMessageActionDelete:
                    {
                        [weakSelf didPressDelete:message];
                    }
                        break;
                    default:
                        break;
                }
            } dismissBlock:^{
                [weakSelf.tableView deselectRowAtIndexPath:indexPath animated:YES];
            }];
        }
    }
}

#pragma mark - UIScrollViewDelegate Methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [super scrollViewDidScroll:scrollView];
    
    if ([scrollView isEqual:self.tableView] && scrollView.contentOffset.y < 0) {
        if ([self couldRetireveHistory]) {
            NCChatMessage *firstMessage = [self getFirstRealMessage];
            if (firstMessage && [_chatController hasHistoryFromMessageId:firstMessage.messageId]) {
                _retrievingHistory = YES;
                [self showLoadingHistoryView];
                if (_offlineMode) {
                    [_chatController getHistoryBatchOfflineFromMessagesId:firstMessage.messageId];
                } else {
                    [_chatController getHistoryBatchFromMessagesId:firstMessage.messageId];
                }
            }
        }
    }
    
    if (_firstUnreadMessageIP) {
        [self checkUnreadMessagesVisibility];
    }
}

#pragma mark - UITextViewDelegate Methods

- (BOOL)textView:(SLKTextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text
{
    if ([text isEqualToString:@""]) {
        UITextRange *selectedRange = [textView selectedTextRange];
        NSInteger cursorOffset = [textView offsetFromPosition:textView.beginningOfDocument toPosition:selectedRange.start];
        NSString *text = textView.text;
        NSString *substring = [text substringToIndex:cursorOffset];
        NSMutableString *lastPossibleMention = [[[substring componentsSeparatedByString:@"@"] lastObject] mutableCopy];
        [lastPossibleMention insertString:@"@" atIndex:0];
        for (NCMessageParameter *mention in _mentions) {
            if ([lastPossibleMention isEqualToString:mention.name]) {
                // Delete mention
                textView.text =  [[self.textView text] stringByReplacingOccurrencesOfString:lastPossibleMention withString:@""];
                [_mentions removeObject:mention];
                return NO;
            }
        }
    }
    
    return [super textView:textView shouldChangeTextInRange:range replacementText:text];
}

#pragma mark - Room Manager notifications

- (void)didUpdateRoom:(NSNotification *)notification
{
    NCRoom *room = [notification.userInfo objectForKey:@"room"];
    if (!room || ![room.token isEqualToString:_room.token]) {
        return;
    }
    
    _room = room;
    [self setTitleView];
    
    if (!_hasStopped) {
        [self checkLobbyState];
    }
}

- (void)didJoinRoom:(NSNotification *)notification
{
    NSString *token = [notification.userInfo objectForKey:@"token"];
    if (![token isEqualToString:_room.token]) {
        return;
    }
    
    NSError *error = [notification.userInfo objectForKey:@"error"];
    if (error && _isVisible) {
        _offlineMode = YES;
        [self setOfflineFooterView];
        [_chatController stopReceivingNewChatMessages];
        [self presentJoinError:[notification.userInfo objectForKey:@"errorReason"]];
        return;
    }
    
    _hasJoinedRoom = YES;
    [self checkRoomControlsAvailability];
    
    if (_hasStopped) {
        return;
    }
    
    if (_leftChatWithVisibleChatVC && _hasReceiveInitialHistory) {
        _leftChatWithVisibleChatVC = NO;
        [_chatController startReceivingNewChatMessages];
    } else if (!_hasReceiveInitialHistory && !_hasRequestedInitialHistory) {
        _hasRequestedInitialHistory = YES;
        [_chatController getInitialChatHistory];
    }
}

- (void)didLeaveRoom:(NSNotification *)notification
{
    [self disableRoomControls];
}

#pragma mark - Chat Controller notifications

- (void)didReceiveInitialChatHistory:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self->_chatController) {
            return;
        }
        
        NSMutableArray *messages = [notification.userInfo objectForKey:@"messages"];
        if (messages.count > 0) {
            NSIndexPath *indexPathUnreadMessageSeparator;
            int lastMessageIndex = (int)[messages count] - 1;
            NCChatMessage *lastMessage = [messages objectAtIndex:lastMessageIndex];
            
            [self appendMessages:messages inDictionary:self->_messages];
            
            if (lastMessage && lastMessage.messageId > self->_lastReadMessage) {
                // Iterate backwards to find the correct location for the unread message separator
                for (NSInteger sectionIndex = (self->_dateSections.count - 1); sectionIndex >= 0; sectionIndex--) {
                    NSDate *dateSection = [self->_dateSections objectAtIndex:sectionIndex];
                    NSMutableArray *messagesInSection = [self->_messages objectForKey:dateSection];
                    
                    for (NSInteger messageIndex = (messagesInSection.count - 1); messageIndex >= 0; messageIndex--) {
                        NCChatMessage *chatMessage = [messagesInSection objectAtIndex:messageIndex];
                        
                        if (chatMessage && chatMessage.messageId <= self->_lastReadMessage) {
                            // Insert unread message separator after the current message
                            [messagesInSection insertObject:self->_unreadMessagesSeparator atIndex:(messageIndex + 1)];
                            [self->_messages setObject:messagesInSection forKey:dateSection];
                            indexPathUnreadMessageSeparator = [NSIndexPath indexPathForRow:(messageIndex + 1) inSection:sectionIndex];
                            
                            break;
                        }
                    }
                    
                    if (indexPathUnreadMessageSeparator) {
                        break;
                    }
                }
                
                // Set last received message as last read message
                self->_lastReadMessage = lastMessage.messageId;
            }
            
            NSMutableArray *storedTemporaryMessages = [self->_chatController getTemporaryMessages];
            if (storedTemporaryMessages.count > 0) {
                [self insertMessages:storedTemporaryMessages];
                
                if (indexPathUnreadMessageSeparator) {
                    // It is possible that temporary messages are added which add new sections
                    // In this case the indexPath of the unreadMessageSeparator would be invalid and could lead to a crash
                    // Therefore we need to make sure we got the correct indexPath here
                    indexPathUnreadMessageSeparator = [self getIndexPathOfUnreadMessageSeparator];
                }
            }
            
            [self.tableView reloadData];
            
            if (indexPathUnreadMessageSeparator) {
                [self.tableView scrollToRowAtIndexPath:indexPathUnreadMessageSeparator atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
            } else {
                [self.tableView slk_scrollToBottomAnimated:NO];
            }
        } else {
            [self->_chatBackgroundView.placeholderView setHidden:NO];
        }
                
        self->_hasReceiveInitialHistory = YES;
        
        NSError *error = [notification.userInfo objectForKey:@"error"];
        if (!error) {
            [self->_chatController startReceivingNewChatMessages];
        } else {
            self->_offlineMode = YES;
            [self->_chatController getInitialChatHistoryForOfflineMode];
        }
    });
}

- (void)didReceiveInitialChatHistoryOffline:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self->_chatController) {
            return;
        }
        
        NSMutableArray *messages = [notification.userInfo objectForKey:@"messages"];
        if (messages.count > 0) {
            [self appendMessages:messages inDictionary:self->_messages];
            [self setOfflineFooterView];
            [self.tableView reloadData];
            [self.tableView slk_scrollToBottomAnimated:NO];
        } else {
            [self->_chatBackgroundView.placeholderView setHidden:NO];
        }
        
        NSMutableArray *storedTemporaryMessages = [self->_chatController getTemporaryMessages];
        if (storedTemporaryMessages.count > 0) {
            [self insertMessages:storedTemporaryMessages];
            [self.tableView reloadData];
            [self.tableView slk_scrollToBottomAnimated:NO];
        }
    });
}

- (void)didReceiveChatHistory:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self->_chatController) {
            return;
        }
        
        NSMutableArray *messages = [notification.userInfo objectForKey:@"messages"];
        BOOL shouldAddBlockSeparator = [[notification.userInfo objectForKey:@"shouldAddBlockSeparator"] boolValue];
        if (messages.count > 0) {
            NSIndexPath *lastHistoryMessageIP = [self prependMessages:messages addingBlockSeparator:shouldAddBlockSeparator];
            [self.tableView reloadData];
            
            if ([NCUtils isValidIndexPath:lastHistoryMessageIP forTableView:self.tableView]) {
                [self.tableView scrollToRowAtIndexPath:lastHistoryMessageIP atScrollPosition:UITableViewScrollPositionTop animated:NO];
            }
        }
        
        BOOL noMoreStoredHistory = [[notification.userInfo objectForKey:@"noMoreStoredHistory"] boolValue];
        if (noMoreStoredHistory) {
            self->_hasStoredHistory = NO;
        }
        self->_retrievingHistory = NO;
        [self hideLoadingHistoryView];
    });
}

- (void)didReceiveChatMessages:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = [notification.userInfo objectForKey:@"error"];
        if (notification.object != self->_chatController || error) {
            return;
        }
        
        BOOL firstNewMessagesAfterHistory = !self->_hasReceiveNewMessages;
        self->_hasReceiveNewMessages = YES;
        
        NSMutableArray *messages = [notification.userInfo objectForKey:@"messages"];
        if (messages.count > 0) {
            // Detect if we should scroll to new messages before we issue a reloadData
            // Otherwise longer messages will prevent scrolling
            BOOL shouldScrollOnNewMessages = [self shouldScrollOnNewMessages] ;
            
            // Check if unread messages separator should be added (only if it's not already shown)
            NSIndexPath *indexPathUnreadMessageSeparator;
            if (firstNewMessagesAfterHistory && [self getLastReadMessage] > 0 && ![self getIndexPathOfUnreadMessageSeparator]) {
                NSMutableArray *messagesForLastDateBeforeUpdate = [self->_messages objectForKey:[self->_dateSections lastObject]];
                [messagesForLastDateBeforeUpdate addObject:self->_unreadMessagesSeparator];
                indexPathUnreadMessageSeparator = [NSIndexPath indexPathForRow:messagesForLastDateBeforeUpdate.count - 1 inSection: self->_dateSections.count - 1];
                [self->_messages setObject:messagesForLastDateBeforeUpdate forKey:[self->_dateSections lastObject]];
            }
            
            // Sort received messages
            [self appendMessages:messages inDictionary:self->_messages];
            
            NSMutableArray *messagesForLastDate = [self->_messages objectForKey:[self->_dateSections lastObject]];
            NSIndexPath *lastMessageIndexPath = [NSIndexPath indexPathForRow:messagesForLastDate.count - 1 inSection:self->_dateSections.count - 1];
            
            // Load messages in chat view
            [self.tableView reloadData];
            
            BOOL newMessagesContainUserMessage = [self newMessagesContainUserMessage:messages];
            // Remove unread messages separator when user writes a message
            if (newMessagesContainUserMessage) {
                [self removeUnreadMessagesSeparator];
                // Update last message index path
                lastMessageIndexPath = [NSIndexPath indexPathForRow:messagesForLastDate.count - 1 inSection:self->_dateSections.count - 1];
            }
            
            NCChatMessage *firstNewMessage = [messages objectAtIndex:0];
            NSIndexPath *firstMessageIndexPath = [self indexPathForMessage:firstNewMessage];
            // This variable is needed since several calls to receiveMessages API might be needed
            // (if the number of unread messages is bigger than the "limit" in receiveMessages request)
            // to receive all the unread messages.
            BOOL areReallyNewMessages = firstNewMessage.timestamp >= self->_chatViewPresentedTimestamp;
            
            // Position chat view
            if (indexPathUnreadMessageSeparator) {
                // Dispatch it in the next cycle so reloadData is always completed.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.tableView scrollToRowAtIndexPath:indexPathUnreadMessageSeparator atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                });
            } else if (shouldScrollOnNewMessages || newMessagesContainUserMessage) {
                [self.tableView scrollToRowAtIndexPath:lastMessageIndexPath atScrollPosition:UITableViewScrollPositionNone animated:YES];
            } else if (!self->_firstUnreadMessageIP && areReallyNewMessages) {
                [self showNewMessagesViewUntilIndexPath:firstMessageIndexPath];
            }
            
            // Set last received message as last read message
            NCChatMessage *lastReceivedMessage = [messages objectAtIndex:messages.count - 1];
            self->_lastReadMessage = lastReceivedMessage.messageId;
        }
        
        if (firstNewMessagesAfterHistory) {
            [self->_chatBackgroundView.loadingView stopAnimating];
            [self->_chatBackgroundView.loadingView setHidden:YES];
        }
    });
}

- (void)didSendChatMessage:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self->_chatController) {
            return;
        }
        
        NSError *error = [notification.userInfo objectForKey:@"error"];
        NSString *message = [notification.userInfo objectForKey:@"message"];
        NSString *referenceId = [notification.userInfo objectForKey:@"referenceId"];
        if (error) {
            if (referenceId) {
                [self setFailedStatusToMessageWithReferenceId:referenceId];
            } else {
                self.textView.text = message;
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:NSLocalizedString(@"Could not send the message", nil)
                                             message:NSLocalizedString(@"An error occurred while sending the message", nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"OK", nil)
                                           style:UIAlertActionStyleDefault
                                           handler:nil];
                
                [alert addAction:okButton];
                [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
            }
        }
    });
}

- (void)didReceiveChatBlocked:(NSNotification *)notification
{
    if (notification.object != _chatController) {
        return;
    }
    
    [self startObservingRoomLobbyFlag];
}

- (void)didReceiveNewerCommonReadMessage:(NSNotification *)notification
{
    if (notification.object != _chatController) {
        return;
    }
    
    [self checkLastCommonReadMessage];
}

- (void)didReceiveDeletedMessage:(NSNotification *)notification
{
    if (notification.object != _chatController) {
        return;
    }
    
    NCChatMessage *message = [notification.userInfo objectForKey:@"deleteMessage"];
    NCChatMessage *deleteMessage = message.parent;
    if (deleteMessage) {
        [self updateMessageWithReferenceId:deleteMessage.referenceId withMessage:deleteMessage];
    }
}

#pragma mark - Lobby functions

- (void)startObservingRoomLobbyFlag
{
    [self updateRoomInformation];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lobbyCheckTimer invalidate];
        self->_lobbyCheckTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(updateRoomInformation) userInfo:nil repeats:YES];
    });
}

- (void)updateRoomInformation
{
    [[NCRoomsManager sharedInstance] updateRoom:_room.token];
}

- (BOOL)shouldPresentLobbyView
{
    return _room.lobbyState == NCRoomLobbyStateModeratorsOnly && !_room.canModerate;
}

#pragma mark - Chat functions

- (NSDate *)getKeyForDate:(NSDate *)date inDictionary:(NSDictionary *)dictionary
{
    NSDate *keyDate = nil;
    for (NSDate *key in dictionary.allKeys) {
        if ([[NSCalendar currentCalendar] isDate:date inSameDayAsDate:key]) {
            keyDate = key;
        }
    }
    return keyDate;
}

- (NSIndexPath *)prependMessages:(NSMutableArray *)historyMessages addingBlockSeparator:(BOOL)shouldAddBlockSeparator
{
    NSMutableDictionary *historyDict = [[NSMutableDictionary alloc] init];
    [self appendMessages:historyMessages inDictionary:historyDict];
    
    NSDate *chatSection = nil;
    NSMutableArray *historyMessagesForSection = nil;
    // Sort history sections
    NSMutableArray *historySections = [NSMutableArray arrayWithArray:historyDict.allKeys];
    [historySections sortUsingSelector:@selector(compare:)];
    
    // Add every section in history that can't be merged with current chat messages
    for (NSDate *historySection in historySections) {
        historyMessagesForSection = [historyDict objectForKey:historySection];
        chatSection = [self getKeyForDate:historySection inDictionary:_messages];
        if (!chatSection) {
            [_messages setObject:historyMessagesForSection forKey:historySection];
        }
    }
    
    [self sortDateSections];
    
    if (shouldAddBlockSeparator) {
        // Chat block separator
        NCChatMessage *blockSeparatorMessage = [[NCChatMessage alloc] init];
        blockSeparatorMessage.messageId = kChatBlockSeparatorIdentifier;
        [historyMessagesForSection addObject:blockSeparatorMessage];
    }
    
    NSMutableArray *lastHistoryMessages = [historyDict objectForKey:[historySections lastObject]];
    NSIndexPath *lastHistoryMessageIP = [NSIndexPath indexPathForRow:lastHistoryMessages.count - 1 inSection:historySections.count - 1];
    
    // Merge last section of history messages with first section in current chat
    if (chatSection) {
        NSMutableArray *chatMessages = [_messages objectForKey:chatSection];
        NCChatMessage *lastHistoryMessage = [historyMessagesForSection lastObject];
        NCChatMessage *firstChatMessage = [chatMessages firstObject];
        firstChatMessage.isGroupMessage = [self shouldGroupMessage:firstChatMessage withMessage:lastHistoryMessage];
        [historyMessagesForSection addObjectsFromArray:chatMessages];
        [_messages setObject:historyMessagesForSection forKey:chatSection];
    }
    
    return lastHistoryMessageIP;
}

- (void)appendMessages:(NSMutableArray *)messages inDictionary:(NSMutableDictionary *)dictionary
{
    for (NCChatMessage *newMessage in messages) {
        NSDate *newMessageDate = [NSDate dateWithTimeIntervalSince1970: newMessage.timestamp];
        NSDate *keyDate = [self getKeyForDate:newMessageDate inDictionary:dictionary];
        NSMutableArray *messagesForDate = [dictionary objectForKey:keyDate];

        if (messagesForDate) {
            BOOL messageUpdated = NO;
            
            // Check if we can update the message instead of adding a new one
            for (int i = 0; i < messagesForDate.count; i++) {
                NCChatMessage *currentMessage = messagesForDate[i];
                if ((!currentMessage.isTemporary && currentMessage.messageId == newMessage.messageId) ||
                    (currentMessage.isTemporary && [currentMessage.referenceId isEqualToString:newMessage.referenceId])) {
                    // The newly received message either already exists or its temporary counterpart exists -> update
                    // If the user type a command the newMessage.actorType will be "bots", then we should not group those messages
                    // even if the original message was grouped.
                    newMessage.isGroupMessage = currentMessage.isGroupMessage && ![newMessage.actorType isEqualToString:@"bots"];
                    messagesForDate[i] = newMessage;
                    messageUpdated = YES;
                    break;
                }
            }
            
            if (!messageUpdated) {
                NCChatMessage *lastMessage = [messagesForDate lastObject];
                newMessage.isGroupMessage = [self shouldGroupMessage:newMessage withMessage:lastMessage];
                [messagesForDate addObject:newMessage];
            }
        } else {
            NSMutableArray *newMessagesInDate = [NSMutableArray new];
            [dictionary setObject:newMessagesInDate forKey:newMessageDate];
            [newMessagesInDate addObject:newMessage];
        }
    }
    
    [self sortDateSections];
}

- (void)insertMessages:(NSMutableArray *)messages
{
    for (NCChatMessage *newMessage in messages) {
        NSDate *newMessageDate = [NSDate dateWithTimeIntervalSince1970: newMessage.timestamp];
        NSDate *keyDate = [self getKeyForDate:newMessageDate inDictionary:_messages];
        NSMutableArray *messagesForDate = [_messages objectForKey:keyDate];
        if (messagesForDate) {
            for (int i = 0; i < messagesForDate.count; i++) {
                NCChatMessage *currentMessage = [messagesForDate objectAtIndex:i];
                if (currentMessage.timestamp > newMessage.timestamp) {
                    // Message inserted in between other messages
                    if (i > 0) {
                        NCChatMessage *previousMessage = [messagesForDate objectAtIndex:i-1];
                        newMessage.isGroupMessage = [self shouldGroupMessage:newMessage withMessage:previousMessage];
                    }
                    currentMessage.isGroupMessage = [self shouldGroupMessage:currentMessage withMessage:newMessage];
                    [messagesForDate insertObject:newMessage atIndex:i];
                    break;
                // Message inserted at the end of a date section
                } else if (i == messagesForDate.count - 1) {
                    newMessage.isGroupMessage = [self shouldGroupMessage:newMessage withMessage:currentMessage];
                    [messagesForDate addObject:newMessage];
                    break;
                }
            }
        } else {
            NSMutableArray *newMessagesInDate = [NSMutableArray new];
            [_messages setObject:newMessagesInDate forKey:newMessageDate];
            [newMessagesInDate addObject:newMessage];
        }
    }
    
    [self sortDateSections];
}

- (NSIndexPath *)indexPathForMessage:(NCChatMessage *)message
{
    NSDate *messageDate = [NSDate dateWithTimeIntervalSince1970: message.timestamp];
    NSDate *keyDate = [self getKeyForDate:messageDate inDictionary:_messages];
    NSInteger section = [_dateSections indexOfObject:keyDate];
    if (NSNotFound != section) {
        NSMutableArray *messages = [_messages objectForKey:keyDate];
        for (int i = 0; i < messages.count; i++) {
            NCChatMessage *currentMessage = messages[i];
            if ((!currentMessage.isTemporary && currentMessage.messageId == message.messageId) ||
                (currentMessage.isTemporary && [currentMessage.referenceId isEqualToString:message.referenceId])) {
                return [NSIndexPath indexPathForRow:i inSection:section];
            }
        }
    }
    
    return nil;
}

- (NSIndexPath *)indexPathForMessageWithReferenceId:(NSString *)referenceId
{
    for (NSInteger i = _dateSections.count - 1; i >= 0; i--) {
        NSDate *keyDate = [_dateSections objectAtIndex:i];
        NSMutableArray *messages = [_messages objectForKey:keyDate];
        for (int j = 0; j < messages.count; j++) {
            NCChatMessage *currentMessage = messages[j];
            if ([currentMessage.referenceId isEqualToString:referenceId]) {
                return [NSIndexPath indexPathForRow:j inSection:i];
            }
        }
    }
    
    return nil;
}

- (NSIndexPath *)removeMessageAtIndexPath:(NSIndexPath *)indexPath
{
    NSDate *sectionKey = [_dateSections objectAtIndex:indexPath.section];
    if (sectionKey) {
        NSMutableArray *messages = [_messages objectForKey:sectionKey];
        if (indexPath.row < messages.count) {
            if (messages.count == 1) {
                // Remove section
                [_messages removeObjectForKey:sectionKey];
                [self sortDateSections];
                [self.tableView beginUpdates];
                [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationNone];
                [self.tableView endUpdates];
            } else {
                // Remove message
                BOOL isLastMessage = indexPath.row == messages.count - 1;
                [messages removeObjectAtIndex:indexPath.row];
                [self.tableView beginUpdates];
                [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                [self.tableView endUpdates];
                if (!isLastMessage) {
                    // Update the message next to removed message
                    NCChatMessage *nextMessage = [messages objectAtIndex:indexPath.row];
                    nextMessage.isGroupMessage = NO;
                    if (indexPath.row > 0) {
                        NCChatMessage *previousMessage = [messages objectAtIndex:indexPath.row - 1];
                        nextMessage.isGroupMessage = [self shouldGroupMessage:nextMessage withMessage:previousMessage];
                    }
                    [self.tableView beginUpdates];
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                    [self.tableView endUpdates];
                }
            }
        }
    }
    
    return nil;
}

- (void)sortDateSections
{
    _dateSections = [NSMutableArray arrayWithArray:_messages.allKeys];
    [_dateSections sortUsingSelector:@selector(compare:)];
}

- (BOOL)shouldGroupMessage:(NCChatMessage *)newMessage withMessage:(NCChatMessage *)lastMessage
{
    BOOL sameActor = [newMessage.actorId isEqualToString:lastMessage.actorId];
    BOOL sameType = ([newMessage isSystemMessage] == [lastMessage isSystemMessage]);
    BOOL timeDiff = (newMessage.timestamp - lastMessage.timestamp) < kChatMessageGroupTimeDifference;
    
    return sameActor & sameType & timeDiff;
}

- (BOOL)couldRetireveHistory
{
    return _hasReceiveInitialHistory && !_retrievingHistory && _dateSections.count > 0 && _hasStoredHistory;
}

- (void)showLoadingHistoryView
{
    _loadingHistoryView = [[UIActivityIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    _loadingHistoryView.color = [UIColor darkGrayColor];
    [_loadingHistoryView startAnimating];
    self.tableView.tableHeaderView = _loadingHistoryView;
}

- (void)hideLoadingHistoryView
{
    _loadingHistoryView = nil;
    self.tableView.tableHeaderView = nil;
}

- (BOOL)shouldScrollOnNewMessages
{
    if (_isVisible) {
        // Scroll if table view is at the bottom (or 80px up)
        CGFloat minimumOffset = (self.tableView.contentSize.height - self.tableView.frame.size.height) - 80;
        if (self.tableView.contentOffset.y >= minimumOffset) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)newMessagesContainUserMessage:(NSMutableArray *)messages
{
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    for (NCChatMessage *message in messages) {
        if ([message.actorId isEqualToString:activeAccount.userId] && !message.isSystemMessage) {
            return YES;
        }
    }
    return NO;
}

- (void)showNewMessagesViewUntilIndexPath:(NSIndexPath *)messageIP
{
    _firstUnreadMessageIP = messageIP;
    _unreadMessageButton.hidden = NO;
    // Check if unread messages are already visible
    [self checkUnreadMessagesVisibility];
}

- (void)hideNewMessagesView
{
    _firstUnreadMessageIP = nil;
    _unreadMessageButton.hidden = YES;
}

- (NSIndexPath *)getIndexPathOfUnreadMessageSeparator
{
    // Most likely the unreadMessageSeparator is somewhere near the bottom of the chat, so we look for it from bottom up
    for (NSInteger sectionIndex = (self->_dateSections.count - 1); sectionIndex >= 0; sectionIndex--) {
        NSDate *dateSection = [self->_dateSections objectAtIndex:sectionIndex];
        NSMutableArray *messagesInSection = [self->_messages objectForKey:dateSection];
        
        for (NSInteger messageIndex = (messagesInSection.count - 1); messageIndex >= 0; messageIndex--) {
            NCChatMessage *chatMessage = [messagesInSection objectAtIndex:messageIndex];
            
            if (chatMessage && chatMessage.messageId == kUnreadMessagesSeparatorIdentifier) {
                return [NSIndexPath indexPathForRow:messageIndex inSection:sectionIndex];
            }
        }
    }
    
    return nil;
}

- (void)removeUnreadMessagesSeparator
{
    NSIndexPath *indexPath = [self getIndexPathOfUnreadMessageSeparator];
    
    if (indexPath) {
        NSDate *separatorDate = [_dateSections objectAtIndex:indexPath.section];
        NSMutableArray *messages = [_messages objectForKey:separatorDate];
        [messages removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationTop];
    }
}

- (void)checkUnreadMessagesVisibility
{
    NSArray* visibleCellsIPs = [self.tableView indexPathsForVisibleRows];
    if ([visibleCellsIPs containsObject:_firstUnreadMessageIP]) {
         [self hideNewMessagesView];
    }
}

- (void)checkLastCommonReadMessage
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *reloadCells = [NSMutableArray new];
        for (NSIndexPath *visibleIndexPath in self.tableView.indexPathsForVisibleRows) {
            NSDate *sectionDate = [self->_dateSections objectAtIndex:visibleIndexPath.section];
            NCChatMessage *message = [[self->_messages objectForKey:sectionDate] objectAtIndex:visibleIndexPath.row];
            if (message.messageId > 0 && message.messageId <= self->_room.lastCommonReadMessage) {
                [reloadCells addObject:visibleIndexPath];
            }
        }
        
        if (reloadCells.count > 0) {
            [self.tableView beginUpdates];
            [self.tableView reloadRowsAtIndexPaths:reloadCells withRowAnimation:UITableViewRowAnimationNone];
            [self.tableView endUpdates];
        }
    });
}

- (void)cleanChat
{
    _messages = [[NSMutableDictionary alloc] init];
    _dateSections = [[NSMutableArray alloc] init];
    _hasReceiveInitialHistory = NO;
    _hasRequestedInitialHistory = NO;
    _hasReceiveNewMessages = NO;
    [self hideNewMessagesView];
    [self.tableView reloadData];
}

- (void)savePendingMessage
{
    _room.pendingMessage = self.textView.text;
    [[NCRoomsManager sharedInstance] updatePendingMessage:_room.pendingMessage forRoom:_room];
}

#pragma mark - Autocompletion

- (void)didChangeAutoCompletionPrefix:(NSString *)prefix andWord:(NSString *)word
{
    if ([prefix isEqualToString:@"@"]) {
        [self showSuggestionsForString:word];
    }
}

- (CGFloat)heightForAutoCompletionView
{
    return kChatMessageCellMinimumHeight * self.autocompletionUsers.count;
}

- (void)showSuggestionsForString:(NSString *)string
{
    self.autocompletionUsers = nil;
    [[NCAPIController sharedInstance] getMentionSuggestionsInRoom:_room.token forString:string forAccount:[[NCDatabaseManager sharedInstance] activeAccount] withCompletionBlock:^(NSMutableArray *mentions, NSError *error) {
        if (!error) {
            self.autocompletionUsers = [[NSMutableArray alloc] initWithArray:mentions];
            BOOL show = (self.autocompletionUsers.count > 0);
            // Check if the '@' is still there
            [self.textView lookForPrefixes:self.registeredPrefixes completion:^(NSString *prefix, NSString *word, NSRange wordRange) {
                if (prefix.length > 0 && word.length > 0) {
                    [self showAutoCompletionView:show];
                } else {
                    [self cancelAutoCompletion];
                }
            }];
        }
    }];
}

#pragma mark - UITableViewDataSource Methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return 1;
    }
    
    if ([tableView isEqual:self.tableView] && _dateSections.count > 0) {
        self.tableView.backgroundView = nil;
    } else {
        self.tableView.backgroundView = _chatBackgroundView;
    }
    
    return _dateSections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return _autocompletionUsers.count;
    }
    
    NSDate *date = [_dateSections objectAtIndex:section];
    NSMutableArray *messages = [_messages objectForKey:date];
    
    return messages.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return nil;
    }
    
    NSDate *date = [_dateSections objectAtIndex:section];
    return [self getHeaderStringFromDate:date];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return 0;
    }
    
    return kDateHeaderViewHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return nil;
    }
    
    DateHeaderView *headerView = [[DateHeaderView alloc] init];
    headerView.dateLabel.text = [self tableView:tableView titleForHeaderInSection:section];
    headerView.dateLabel.layer.cornerRadius = 12;
    headerView.dateLabel.clipsToBounds = YES;
    
    return headerView;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([tableView isEqual:self.autoCompletionView]) {
        NSDictionary *suggestion = [_autocompletionUsers objectAtIndex:indexPath.row];
        NSString *suggestionId = [suggestion objectForKey:@"id"];
        NSString *suggestionName = [suggestion objectForKey:@"label"];
        NSString *suggestionSource = [suggestion objectForKey:@"source"];
        NSString *suggestionUserStatus = [suggestion objectForKey:@"status"];
        ChatMessageTableViewCell *suggestionCell = (ChatMessageTableViewCell *)[self.autoCompletionView dequeueReusableCellWithIdentifier:AutoCompletionCellIdentifier];
        suggestionCell.titleLabel.text = suggestionName;
        [suggestionCell setUserStatus:suggestionUserStatus];
        if ([suggestionId isEqualToString:@"all"]) {
            [suggestionCell.avatarView setImage:[UIImage imageNamed:@"group-15"]];
            [suggestionCell.avatarView setContentMode:UIViewContentModeCenter];
        } else if ([suggestionSource isEqualToString:@"guests"]) {
            UIColor *guestAvatarColor = [NCAppBranding placeholderColor];
            NSString *name = ([suggestionName isEqualToString:@"Guest"]) ? @"?" : suggestionName;
            [suggestionCell.avatarView setImageWithString:name color:guestAvatarColor circular:true];
        } else {
            [suggestionCell.avatarView setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:suggestionId andSize:96 usingAccount:[[NCDatabaseManager sharedInstance] activeAccount]]
                                             placeholderImage:nil success:nil failure:nil];
        }
        return suggestionCell;
    }
    
    NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
    NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
    
    return [self getCellForMessage:message];
}

- (UITableViewCell *)getCellForMessage:(NCChatMessage *) message
{
    UITableViewCell *cell = [UITableViewCell new];
    if (message.messageId == kUnreadMessagesSeparatorIdentifier) {
        MessageSeparatorTableViewCell *separatorCell = (MessageSeparatorTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:MessageSeparatorCellIdentifier];
        separatorCell.messageId = message.messageId;
        separatorCell.separatorLabel.text = NSLocalizedString(@"Unread messages", nil);
        return separatorCell;
    }
    if (message.messageId == kChatBlockSeparatorIdentifier) {
        MessageSeparatorTableViewCell *separatorCell = (MessageSeparatorTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:MessageSeparatorCellIdentifier];
        separatorCell.messageId = message.messageId;
        separatorCell.separatorLabel.text = NSLocalizedString(@"Some messages not shown, will be downloaded when online", nil);
        return separatorCell;
    }
    if (message.isSystemMessage) {
        if ([message.systemMessage isEqualToString:@"message_deleted"]) {
            return (SystemMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:InvisibleSystemMessageCellIdentifier];
        }
        SystemMessageTableViewCell *systemCell = (SystemMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:SystemMessageCellIdentifier];
        [systemCell setupForMessage:message];
        return systemCell;
    }
    if (message.file) {
        NSString *fileCellIdentifier = (message.isGroupMessage) ? GroupedFileMessageCellIdentifier : FileMessageCellIdentifier;
        FileMessageTableViewCell *fileCell = (FileMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:fileCellIdentifier];
        fileCell.delegate = self;
        
        [fileCell setupForMessage:message withLastCommonReadMessage:_room.lastCommonReadMessage];

        return fileCell;
    }
    if (message.geoLocation) {
        NSString *locationCellIdentifier = (message.isGroupMessage) ? GroupedLocationMessageCellIdentifier : LocationMessageCellIdentifier;
        LocationMessageTableViewCell *locationCell = (LocationMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:locationCellIdentifier];
        locationCell.delegate = self;
        
        [locationCell setupForMessage:message withLastCommonReadMessage:_room.lastCommonReadMessage];

        return locationCell;
    }
    if (message.parent) {
        ChatMessageTableViewCell *replyCell = (ChatMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:ReplyMessageCellIdentifier];
        replyCell.delegate = self;
        
        [replyCell setupForMessage:message withLastCommonReadMessage:_room.lastCommonReadMessage];
        
        return replyCell;
    }
    if (message.isGroupMessage) {
        GroupedChatMessageTableViewCell *groupedCell = (GroupedChatMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:GroupedChatMessageCellIdentifier];
        [groupedCell setupForMessage:message withLastCommonReadMessage:_room.lastCommonReadMessage];
        
        return groupedCell;
    } else {
        ChatMessageTableViewCell *normalCell = (ChatMessageTableViewCell *)[self.tableView dequeueReusableCellWithIdentifier:ChatMessageCellIdentifier];
        [normalCell setupForMessage:message withLastCommonReadMessage:_room.lastCommonReadMessage];
        
        return normalCell;
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([tableView isEqual:self.tableView]) {
        NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
        NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
        
        CGFloat width = CGRectGetWidth(tableView.frame) - kChatMessageCellAvatarHeight;
        if (@available(iOS 11.0, *)) {
            width -= tableView.safeAreaInsets.left + tableView.safeAreaInsets.right;
        }
        
        return [self getCellHeightForMessage:message withWidth:width];
    }
    else {
        return kChatMessageCellMinimumHeight;
    }
}

- (CGFloat)getCellHeightForMessage:(NCChatMessage *)message withWidth:(CGFloat)width
{
    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    paragraphStyle.alignment = NSTextAlignmentLeft;
    
    if (message.messageId == kUnreadMessagesSeparatorIdentifier ||
        message.messageId == kChatBlockSeparatorIdentifier) {
        return kMessageSeparatorCellHeight;
    }
    
    CGFloat pointSize = [ChatMessageTableViewCell defaultFontSize];
    
    NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:pointSize],
                                 NSParagraphStyleAttributeName: paragraphStyle};
    
    
    width -= (message.isSystemMessage)? 80.0 : 30.0; // 4*right(10) + dateLabel(40) : 3*right(10)
    
    CGRect titleBounds = [message.actorDisplayName boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:NULL];
    CGRect bodyBounds = [message.parsedMessage boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:(NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading) context:NULL];
    
    if (message.message.length == 0 || [message.systemMessage isEqualToString:@"message_deleted"]) {
        return 0.0;
    }
    
    CGFloat height = CGRectGetHeight(titleBounds);
    height += CGRectGetHeight(bodyBounds);
    height += 40.0;
    
    if (height < kChatMessageCellMinimumHeight) {
        height = kChatMessageCellMinimumHeight;
    }
    
    if (message.parent) {
        height += 60;
        return height;
    }
    
    if (message.isGroupMessage || message.isSystemMessage) {
        height = CGRectGetHeight(bodyBounds) + 20;
        
        if (height < kGroupedChatMessageCellMinimumHeight) {
            height = kGroupedChatMessageCellMinimumHeight;
        }
    }
    
    if (message.file) {
        height += kFileMessageCellFilePreviewHeight + 15;
    }
    
    if (message.geoLocation) {
        height += kLocationMessageCellPreviewHeight + 15;
    }
    
    return height;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([tableView isEqual:self.autoCompletionView]) {
        NCMessageParameter *mention = [[NCMessageParameter alloc] init];
        mention.parameterId = [NSString stringWithFormat:@"@%@", [self.autocompletionUsers[indexPath.row] objectForKey:@"id"]];
        mention.name = [NSString stringWithFormat:@"@%@", [self.autocompletionUsers[indexPath.row] objectForKey:@"label"]];
        // Guest mentions are wrapped with double quotes @"guest/<sha1(webrtc session id)>"
        if ([[self.autocompletionUsers[indexPath.row] objectForKey:@"source"] isEqualToString:@"guests"]) {
            mention.parameterId = [NSString stringWithFormat:@"@\"%@\"", [self.autocompletionUsers[indexPath.row] objectForKey:@"id"]];
        }
        // User-ids with a space should be wrapped in double quoutes
        NSRange whiteSpaceRange = [mention.parameterId rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (whiteSpaceRange.location != NSNotFound) {
            mention.parameterId = [NSString stringWithFormat:@"@\"%@\"", [self.autocompletionUsers[indexPath.row] objectForKey:@"id"]];
        }
        [_mentions addObject:mention];
        
        NSMutableString *mentionString = [[self.autocompletionUsers[indexPath.row] objectForKey:@"label"] mutableCopy];
        [mentionString appendString:@" "];
        [self acceptAutoCompletionWithString:mentionString keepPrefix:YES];
    } else {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point API_AVAILABLE(ios(13.0))
{
    if ([tableView isEqual:self.autoCompletionView]) {
        return nil;
    }
    
    NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
    NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
    
    if (message.isSystemMessage || message.messageId == kUnreadMessagesSeparatorIdentifier) {
        return nil;
    }
        
    NSMutableArray *actions = [[NSMutableArray alloc] init];
    
    // Reply option
    if (message.isReplyable && !message.isDeleting && !_offlineMode) {
        UIImage *replyImage = [[UIImage imageNamed:@"reply"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIAction *replyAction = [UIAction actionWithTitle:NSLocalizedString(@"Reply", nil) image:replyImage identifier:nil handler:^(UIAction *action){
            
            [self didPressReply:message];
        }];
        
        [actions addObject:replyAction];
        
        // Reply-privately option (only to other users and not in one-to-one)
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        if (_room.type != kNCRoomTypeOneToOne && [message.actorType isEqualToString:@"users"] && ![message.actorId isEqualToString:activeAccount.userId] )
        {
            UIImage *replyPrivateImage = [[UIImage imageNamed:@"reply"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            UIAction *replyPrivateAction = [UIAction actionWithTitle:NSLocalizedString(@"Reply Privately", nil) image:replyPrivateImage identifier:nil handler:^(UIAction *action){
                
                [self didPressReplyPrivately:message];
            }];
            
            [actions addObject:replyPrivateAction];
        }
    }

    // Re-send option
    if (message.sendingFailed && !_offlineMode) {
        UIImage *resendImage = [[UIImage imageNamed:@"refresh"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIAction *resendAction = [UIAction actionWithTitle:NSLocalizedString(@"Resend", nil) image:resendImage identifier:nil handler:^(UIAction *action){
            
            [self didPressResend:message];
        }];
        
        [actions addObject:resendAction];
    }
    
    // Copy option
    UIImage *copyImage = [[UIImage imageNamed:@"clippy"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIAction *copyAction = [UIAction actionWithTitle:NSLocalizedString(@"Copy", nil) image:copyImage identifier:nil handler:^(UIAction *action){
        
        [self didPressCopy:message];
    }];
    
    [actions addObject:copyAction];
    
    // Open in nextcloud option
    if (message.file && !_offlineMode) {
        NSString *openInNextcloudTitle = [NSString stringWithFormat:NSLocalizedString(@"Open in %@", nil), filesAppName];
        UIImage *nextcloudActionImage = [[UIImage imageNamed:@"logo-action"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIAction *openInNextcloudAction = [UIAction actionWithTitle:openInNextcloudTitle image:nextcloudActionImage identifier:nil handler:^(UIAction *action){
            
            [self didPressOpenInNextcloud:message];
        }];

        [actions addObject:openInNextcloudAction];
    }
    

    // Delete option
    if (message.sendingFailed || [message isDeletableForAccount:[[NCDatabaseManager sharedInstance] activeAccount] andParticipantType:_room.participantType]) {
        UIImage *deleteImage = [[UIImage imageNamed:@"delete"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIAction *deleteAction = [UIAction actionWithTitle:NSLocalizedString(@"Delete", nil) image:deleteImage identifier:nil handler:^(UIAction *action){
            
            [self didPressDelete:message];
        }];
    
        deleteAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:deleteAction];
    }
    
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:actions];
    
    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController * _Nullable{
        return [self getPreviewViewControllerForTableView:tableView withIndexPath:indexPath];
    } actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return menu;
    }];

    return configuration;
}

- (UIViewController *)getPreviewViewControllerForTableView:(UITableView *)tableView withIndexPath:(NSIndexPath *)indexPath
{
    if (SLK_IS_IPAD) {
        return nil;
    }
    
    NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
    NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
    
    // Remember grouped-status -> Create a previewView which always is a non-grouped-message
    BOOL isGroupMessage = message.isGroupMessage;
    message.isGroupMessage = NO;
    
    CGFloat maxPreviewWidth = self.view.bounds.size.width;
    CGFloat maxPreviewHeight = self.view.bounds.size.height * 0.6;
    
    if (SLK_IS_IPHONE && SLK_IS_LANDSCAPE) {
        maxPreviewWidth = self.view.bounds.size.width / 3;
    }
    
    UITableViewCell *previewView = [self getCellForMessage:message];
    CGFloat maxTextWidth = maxPreviewWidth - kChatMessageCellAvatarHeight;
    CGFloat cellHeight = [self getCellHeightForMessage:message withWidth:maxTextWidth];
    
    // Cut the height if bigger than max height
    if (cellHeight > maxPreviewHeight) {
        cellHeight = maxPreviewHeight;
    }
    
    // Make sure the previewView has the correct size
    previewView.contentView.frame = CGRectMake(0,0, maxPreviewWidth, cellHeight);
    
    // Restore grouped-status
    message.isGroupMessage = isGroupMessage;
    
    UIViewController *previewController = [[UIViewController alloc] init];
    [previewController.view addSubview:previewView.contentView];
    previewController.preferredContentSize = previewView.contentView.frame.size;
    
    return previewController;
}

#pragma mark - FileMessageTableViewCellDelegate

- (void)cellWantsToDownloadFile:(NCMessageFileParameter *)fileParameter
{
    if (fileParameter.fileStatus && fileParameter.fileStatus.isDownloading) {
        NSLog(@"File already downloading -> skipping new download");
        return;
    }
    
    NCChatFileController *downloader = [[NCChatFileController alloc] init];
    downloader.delegate = self;
    [downloader downloadFileFromMessage:fileParameter];
}

#pragma mark - LocationMessageTableViewCellDelegate

- (void)cellWantsToOpenLocation:(GeoLocationRichObject *)geoLocationRichObject
{
    MapViewController *mapVC = [[MapViewController alloc] initWithGeoLocationRichObject:geoLocationRichObject];
    NCNavigationController *mapNC = [[NCNavigationController alloc] initWithRootViewController:mapVC];
    [self presentViewController:mapNC animated:YES completion:nil];
}

#pragma mark - ChatMessageTableViewCellDelegate

- (void)cellWantsToScrollToMessage:(NCChatMessage *)message {
    NSIndexPath *indexPath = [self indexPathForMessage:message];
    if (indexPath) {
        [self.tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionTop];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        });
    }
}

#pragma mark - NCChatFileControllerDelegate

- (void)fileControllerDidLoadFile:(NCChatFileController *)fileController withFileStatus:(NCChatFileStatus *)fileStatus
{
    if (_isPreviewControllerShown) {
        // We are showing a file already, no need to open another one
        return;
    }
    
    BOOL isFileCellStillVisible = NO;
    
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        NSDate *sectionDate = [_dateSections objectAtIndex:indexPath.section];
        NCChatMessage *message = [[_messages objectForKey:sectionDate] objectAtIndex:indexPath.row];
        
        if (message.file && [message.file.parameterId isEqualToString:fileStatus.fileId] && [message.file.path isEqualToString:fileStatus.filePath]) {
            isFileCellStillVisible = YES;
            break;
        }
    }
    
    if (!isFileCellStillVisible) {
        // Only open file when the corresponding cell is still visible on the screen
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_isPreviewControllerShown = YES;
        self->_previewControllerFilePath = fileStatus.fileLocalPath;
        
        // When the keyboard is not dismissed, dismissing the previewController might result in a corrupted keyboardView
        [self dismissKeyboard:NO];

        QLPreviewController * preview = [[QLPreviewController alloc] init];
        UIColor *themeColor = [NCAppBranding themeColor];
        
        preview.dataSource = self;
        preview.delegate = self;

        preview.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
        preview.navigationController.navigationBar.barTintColor = themeColor;
        preview.tabBarController.tabBar.tintColor = themeColor;

        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
            [appearance configureWithOpaqueBackground];
            appearance.backgroundColor = themeColor;
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
            preview.navigationItem.standardAppearance = appearance;
            preview.navigationItem.compactAppearance = appearance;
            preview.navigationItem.scrollEdgeAppearance = appearance;
        }

        [self presentViewController:preview animated:YES completion:nil];
    });
}

- (void)fileControllerDidFailLoadingFile:(NCChatFileController *)fileController withErrorDescription:(NSString *)errorDescription
{
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:NSLocalizedString(@"Unable to load file", nil)
                                 message:errorDescription
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", nil)
                               style:UIAlertActionStyleDefault
                               handler:nil];
    
    [alert addAction:okButton];
    
    [[NCUserInterfaceController sharedInstance] presentAlertViewController:alert];
}

#pragma mark - QLPreviewControllerDelegate/DataSource

- (NSInteger)numberOfPreviewItemsInPreviewController:(nonnull QLPreviewController *)controller {
    return 1;
}

- (nonnull id<QLPreviewItem>)previewController:(nonnull QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return [NSURL fileURLWithPath:_previewControllerFilePath];
}

- (void)previewControllerDidDismiss:(QLPreviewController *)controller
{
    _isPreviewControllerShown = NO;
}

@end
