//
//  WQProMediaPlayer.m
//  WQ Glass Pro Media Player (PiP, Background Audio, Subtitles, Gestures) & Swipeable Gallery
//  GPL-3.0-or-later.
//

#import "WQProMediaPlayer.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Subtitle Cue Model & Parser (.srt / .vtt)

@interface WQSubtitleCue : NSObject
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval end;
@property (nonatomic, copy) NSString *text;
@end

@implementation WQSubtitleCue
@end

static NSTimeInterval wq_parse_subtitle_timestamp(NSString *raw)
{
    NSString *clean = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 + parts[2].doubleValue;
    }
    if (parts.count == 2) {
        return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    }
    return -1.0;
}

static NSArray<WQSubtitleCue *> *wq_parse_subtitles(NSString *content)
{
    if (!content.length) return @[];
    NSString *norm = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *blocks = [norm componentsSeparatedByString:@"\n\n"];
    NSMutableArray<WQSubtitleCue *> *cues = [NSMutableArray new];
    for (NSString *block in blocks) {
        NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
        NSInteger timeIdx = -1;
        for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
            if ([lines[(NSUInteger)i] containsString:@"-->"]) {
                timeIdx = i;
                break;
            }
        }
        if (timeIdx < 0) continue;
        NSArray<NSString *> *range = [lines[(NSUInteger)timeIdx] componentsSeparatedByString:@"-->"];
        if (range.count < 2) continue;
        NSTimeInterval start = wq_parse_subtitle_timestamp(range[0]);
        NSString *endToken = [[range[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                              componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject ?: @"";
        NSTimeInterval end = wq_parse_subtitle_timestamp(endToken);
        if (start < 0 || end <= start) continue;
        NSMutableArray<NSString *> *textLines = [NSMutableArray new];
        for (NSUInteger i = (NSUInteger)timeIdx + 1; i < lines.count; i++) {
            NSString *l = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (l.length) [textLines addObject:l];
        }
        if (!textLines.count) continue;
        WQSubtitleCue *cue = [WQSubtitleCue new];
        cue.start = start;
        cue.end = end;
        cue.text = [textLines componentsJoinedByString:@"\n"];
        [cues addObject:cue];
    }
    return cues;
}

static NSString *wq_format_time(NSTimeInterval seconds)
{
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

#pragma mark - Pro Media Player

@interface WQProMediaPlayerViewController () <AVPictureInPictureControllerDelegate, UIDocumentPickerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) AVPlayer *player;
@end

@implementation WQProMediaPlayerViewController {
    NSString *_sourcePath;
    AVPlayerLayer *_playerLayer;
    AVPictureInPictureController *_pip;
    id _timeObserver;
    id _endObserver;

    UIView *_videoContainer;
    UIVisualEffectView *_controlsCard;
    UIButton *_playPauseBtn;
    UIButton *_skipBackBtn;
    UIButton *_skipFwdBtn;
    UIButton *_speedBtn;
    UIButton *_loopBtn;
    UIButton *_pipBtn;
    UIButton *_subBtn;
    UIButton *_lockBtn;
    UIButton *_unlockBtn;
    UISlider *_scrubber;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UILabel *_subtitleLabel;
    UIVisualEffectView *_subtitleBox;
    UILabel *_gestureHudLabel;
    UIVisualEffectView *_gestureHudBox;

    float _rate;
    BOOL _looping;
    BOOL _controlsHidden;
    BOOL _screenLocked;
    BOOL _scrubbing;
    NSArray<WQSubtitleCue *> *_subtitles;

    NSInteger _panMode; // 0=none, 1=brightness, 2=volume, 3=seek
    CGFloat _panStartValue;
    NSTimeInterval _panStartTime;
    NSTimeInterval _seekTargetTime;
}

- (instancetype)initWithTitle:(NSString *)title sourcePath:(NSString *)sourcePath
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = title;
        _sourcePath = [sourcePath copy];
        _rate = 1.0f;
        _player = [AVPlayer new];
    }
    return self;
}

- (void)dealloc
{
    if (_timeObserver) [_player removeTimeObserver:_timeObserver];
    if (_endObserver) [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
    MPRemoteCommandCenter *rcc = MPRemoteCommandCenter.sharedCommandCenter;
    [rcc.playCommand removeTarget:self];
    [rcc.pauseCommand removeTarget:self];
    [rcc.skipForwardCommand removeTarget:self];
    [rcc.skipBackwardCommand removeTarget:self];
    [rcc.changePlaybackPositionCommand removeTarget:self];
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];

    _videoContainer = [UIView new];
    _videoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _videoContainer.backgroundColor = UIColor.blackColor;
    [self.view addSubview:_videoContainer];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [_videoContainer.layer addSublayer:_playerLayer];

    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        _pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:_playerLayer];
        _pip.delegate = self;
    }

    [self buildOverlayUI];
    [self installGestures];
    [self setupRemoteCommands];
    [self attachPlayerObservers];
    [self autoLoadSiblingSubtitles];

    if (self.onConvert) {
        __weak typeof(self) weakSelf = self;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Convert")
                                image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                           identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf.player pause];
            if (weakSelf.onConvert) weakSelf.onConvert();
        }]];
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _playerLayer.frame = _videoContainer.bounds;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController && !_pip.isPictureInPictureActive) {
        [_player pause];
    }
}

- (void)buildOverlayUI
{
    _subtitleBox = wq_theme_make_glass_card(12, NO);
    _subtitleBox.hidden = YES;
    _subtitleLabel = [UILabel new];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _subtitleLabel.textColor = UIColor.whiteColor;
    [_subtitleBox.contentView addSubview:_subtitleLabel];
    [self.view addSubview:_subtitleBox];

    _gestureHudBox = wq_theme_make_glass_card(14, NO);
    _gestureHudBox.hidden = YES;
    _gestureHudLabel = [UILabel new];
    _gestureHudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _gestureHudLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    _gestureHudLabel.textColor = UIColor.whiteColor;
    _gestureHudLabel.textAlignment = NSTextAlignmentCenter;
    [_gestureHudBox.contentView addSubview:_gestureHudLabel];
    [self.view addSubview:_gestureHudBox];

    _controlsCard = wq_theme_make_glass_card(22, YES);
    [self.view addSubview:_controlsCard];

    _elapsedLabel = [UILabel new];
    _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    _elapsedLabel.textColor = wq_theme_secondary_text();
    _elapsedLabel.text = @"00:00";

    _durationLabel = [UILabel new];
    _durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    _durationLabel.textColor = wq_theme_secondary_text();
    _durationLabel.text = @"00:00";
    _durationLabel.textAlignment = NSTextAlignmentRight;

    _scrubber = [UISlider new];
    _scrubber.minimumTrackTintColor = wq_theme_accent();
    _scrubber.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.25];
    [_scrubber addTarget:self action:@selector(scrubberDown) forControlEvents:UIControlEventTouchDown];
    [_scrubber addTarget:self action:@selector(scrubberChanged) forControlEvents:UIControlEventValueChanged];
    [_scrubber addTarget:self action:@selector(scrubberUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    UIStackView *timeRow = [[UIStackView alloc] initWithArrangedSubviews:@[_elapsedLabel, _scrubber, _durationLabel]];
    timeRow.axis = UILayoutConstraintAxisHorizontal;
    timeRow.alignment = UIStackViewAlignmentCenter;
    timeRow.spacing = 8;

    __weak typeof(self) weakSelf = self;
    _skipBackBtn = [self makeIconBtn:@"gobackward.10" size:19 action:^{ [weakSelf skipBy:-10.0]; }];
    _playPauseBtn = [self makeIconBtn:@"pause.fill" size:24 action:^{ [weakSelf togglePlayPause]; }];
    _skipFwdBtn = [self makeIconBtn:@"goforward.10" size:19 action:^{ [weakSelf skipBy:10.0]; }];
    UIStackView *transportRow = [[UIStackView alloc] initWithArrangedSubviews:@[_skipBackBtn, _playPauseBtn, _skipFwdBtn]];
    transportRow.axis = UILayoutConstraintAxisHorizontal;
    transportRow.distribution = UIStackViewDistributionEqualSpacing;
    transportRow.alignment = UIStackViewAlignmentCenter;
    transportRow.spacing = 28;

    _speedBtn = [self makePillBtn:@"1.0×" symbol:nil action:^{ [weakSelf cycleSpeed]; }];
    _loopBtn = [self makePillBtn:nil symbol:@"repeat" action:^{ [weakSelf toggleLoop]; }];
    _pipBtn = [self makePillBtn:nil symbol:@"pip.enter" action:^{ [weakSelf togglePiP]; }];
    _pipBtn.enabled = (_pip != nil);
    _subBtn = [self makePillBtn:nil symbol:@"captions.bubble" action:^{ [weakSelf pickSubtitles]; }];
    _lockBtn = [self makePillBtn:nil symbol:@"lock.open" action:^{ [weakSelf setScreenLocked:YES]; }];

    UIStackView *toolsRow = [[UIStackView alloc] initWithArrangedSubviews:@[_speedBtn, _loopBtn, _pipBtn, _subBtn, _lockBtn]];
    toolsRow.axis = UILayoutConstraintAxisHorizontal;
    toolsRow.distribution = UIStackViewDistributionEqualSpacing;
    toolsRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *panel = [[UIStackView alloc] initWithArrangedSubviews:@[timeRow, transportRow, toolsRow]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 10;
    [_controlsCard.contentView addSubview:panel];

    _unlockBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _unlockBtn.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_unlockBtn, WQLocalized(@"Unlock"), @"lock.fill");
    _unlockBtn.hidden = YES;
    [_unlockBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf setScreenLocked:NO];
    }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_unlockBtn];

    [NSLayoutConstraint activateConstraints:@[
        [_videoContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_videoContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_videoContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_videoContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_gestureHudBox.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_gestureHudBox.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40],
        [_gestureHudLabel.topAnchor constraintEqualToAnchor:_gestureHudBox.contentView.topAnchor constant:10],
        [_gestureHudLabel.bottomAnchor constraintEqualToAnchor:_gestureHudBox.contentView.bottomAnchor constant:-10],
        [_gestureHudLabel.leadingAnchor constraintEqualToAnchor:_gestureHudBox.contentView.leadingAnchor constant:18],
        [_gestureHudLabel.trailingAnchor constraintEqualToAnchor:_gestureHudBox.contentView.trailingAnchor constant:-18],

        [_controlsCard.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14],
        [_controlsCard.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],
        [_controlsCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [panel.topAnchor constraintEqualToAnchor:_controlsCard.contentView.topAnchor constant:12],
        [panel.bottomAnchor constraintEqualToAnchor:_controlsCard.contentView.bottomAnchor constant:-12],
        [panel.leadingAnchor constraintEqualToAnchor:_controlsCard.contentView.leadingAnchor constant:14],
        [panel.trailingAnchor constraintEqualToAnchor:_controlsCard.contentView.trailingAnchor constant:-14],

        [_subtitleBox.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_subtitleBox.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_subtitleBox.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_subtitleBox.bottomAnchor constraintEqualToAnchor:_controlsCard.topAnchor constant:-12],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_subtitleBox.contentView.topAnchor constant:6],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:_subtitleBox.contentView.bottomAnchor constant:-6],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_subtitleBox.contentView.leadingAnchor constant:12],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_subtitleBox.contentView.trailingAnchor constant:-12],

        [_unlockBtn.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_unlockBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
    ]];
}

- (UIButton *)makeIconBtn:(NSString *)symbol size:(CGFloat)pt action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:symbol
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightBold]];
    cfg.baseForegroundColor = wq_theme_primary_text();
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)makePillBtn:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.baseBackgroundColor = wq_theme_glass_tint();
    if (title.length) cfg.title = title;
    if (symbol.length) {
        cfg.image = [UIImage systemImageNamed:symbol
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
    }
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)installGestures
{
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    tap.delegate = self;
    [_videoContainer addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [_videoContainer addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *__unused)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    return ![touch.view isDescendantOfView:_controlsCard];
}

- (void)handleTap
{
    if (_screenLocked) {
        _unlockBtn.hidden = !_unlockBtn.hidden;
        return;
    }
    _controlsHidden = !_controlsHidden;
    [UIView animateWithDuration:0.22 animations:^{
        self->_controlsCard.alpha = self->_controlsHidden ? 0.0 : 1.0;
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    if (_screenLocked) return;
    CGPoint loc = [pan locationInView:_videoContainer];
    CGPoint trans = [pan translationInView:_videoContainer];
    CGSize size = _videoContainer.bounds.size;

    if (pan.state == UIGestureRecognizerStateBegan) {
        CGPoint vel = [pan velocityInView:_videoContainer];
        if (fabs(vel.x) > fabs(vel.y)) {
            _panMode = 3;
            _panStartTime = CMTimeGetSeconds(_player.currentTime);
            if (!isfinite(_panStartTime)) _panStartTime = 0;
        } else if (loc.x < size.width * 0.45) {
            _panMode = 1;
            UIScreen *scr = self.view.window.windowScene.screen;
            _panStartValue = scr ? scr.brightness : 0.5;
        } else {
            _panMode = 2;
            _panStartValue = _player.volume;
        }
        _gestureHudBox.hidden = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_panMode == 1) {
            CGFloat delta = -trans.y / MAX(160.0, size.height * 0.55);
            CGFloat val = MIN(1.0, MAX(0.0, _panStartValue + delta));
            UIScreen *scr = self.view.window.windowScene.screen;
            if (scr) scr.brightness = val;
            _gestureHudLabel.text = [NSString stringWithFormat:@"☀️ %ld%%", (long)llround(val * 100.0)];
        } else if (_panMode == 2) {
            CGFloat delta = -trans.y / MAX(160.0, size.height * 0.55);
            float val = (float)MIN(1.0, MAX(0.0, _panStartValue + delta));
            _player.volume = val;
            _gestureHudLabel.text = [NSString stringWithFormat:@"🔊 %ld%%", (long)llround(val * 100.0)];
        } else if (_panMode == 3) {
            double dur = CMTimeGetSeconds(_player.currentItem.duration);
            double delta = (trans.x / MAX(200.0, size.width)) * 90.0;
            _seekTargetTime = MAX(0.0, _panStartTime + delta);
            if (isfinite(dur) && dur > 0) _seekTargetTime = MIN(dur, _seekTargetTime);
            _gestureHudLabel.text = [NSString stringWithFormat:@"⏩ %@", wq_format_time(_seekTargetTime)];
        }
    } else {
        if (_panMode == 3) {
            [_player seekToTime:CMTimeMakeWithSeconds(_seekTargetTime, 600)];
        }
        _panMode = 0;
        _gestureHudBox.hidden = YES;
    }
}

- (void)loadPlayerItem:(AVPlayerItem *)item
{
    [_player replaceCurrentItemWithPlayerItem:item];
    [_player play];
    _player.rate = _rate;
    [self updateNowPlaying];
}

- (void)replaceWithLocalURL:(NSURL *)url
{
    [self loadPlayerItem:[AVPlayerItem playerItemWithURL:url]];
}

- (void)attachPlayerObservers
{
    __weak typeof(self) weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf updateProgressForTime:CMTimeGetSeconds(time)];
    }];
    _endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                   object:nil
                                                                    queue:NSOperationQueue.mainQueue
                                                               usingBlock:^(NSNotification *note) {
        WQProMediaPlayerViewController *me = weakSelf;
        if (!me || note.object != me->_player.currentItem) return;
        if (me->_looping) {
            [me->_player seekToTime:kCMTimeZero];
            [me->_player play];
            me->_player.rate = me->_rate;
        } else {
            [me updatePlayPauseIcon:NO];
        }
    }];
}

- (void)updateProgressForTime:(NSTimeInterval)now
{
    if (!isfinite(now) || now < 0) now = 0;
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (!isfinite(dur) || dur < 0) dur = 0;
    if (!_scrubbing) {
        _elapsedLabel.text = wq_format_time(now);
        _durationLabel.text = wq_format_time(dur);
        _scrubber.value = dur > 0 ? (float)(now / dur) : 0.0f;
    }
    [self updatePlayPauseIcon:_player.rate > 0.01f];
    [self updateSubtitleForTime:now];
    [self updateNowPlaying];
}

- (void)updatePlayPauseIcon:(BOOL)playing
{
    UIButtonConfiguration *cfg = [_playPauseBtn.configuration copy];
    cfg.image = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold]];
    _playPauseBtn.configuration = cfg;
}

- (void)togglePlayPause
{
    if (_player.rate > 0.01f) {
        [_player pause];
        [self updatePlayPauseIcon:NO];
    } else {
        [_player play];
        _player.rate = _rate;
        [self updatePlayPauseIcon:YES];
    }
    [self updateNowPlaying];
}

- (void)skipBy:(NSTimeInterval)delta
{
    NSTimeInterval now = CMTimeGetSeconds(_player.currentTime);
    if (!isfinite(now)) now = 0;
    NSTimeInterval target = MAX(0.0, now + delta);
    [_player seekToTime:CMTimeMakeWithSeconds(target, 600)];
}

- (void)cycleSpeed
{
    static const float speeds[] = { 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f };
    NSInteger nextIdx = 0;
    for (NSInteger i = 0; i < 6; i++) {
        if (fabsf(_rate - speeds[i]) < 0.05f) {
            nextIdx = (i + 1) % 6;
            break;
        }
    }
    _rate = speeds[nextIdx];
    if (_player.rate > 0.01f) _player.rate = _rate;
    UIButtonConfiguration *cfg = [_speedBtn.configuration copy];
    cfg.title = [NSString stringWithFormat:@"%g×", _rate];
    _speedBtn.configuration = cfg;
    [self updateNowPlaying];
}

- (void)toggleLoop
{
    _looping = !_looping;
    UIButtonConfiguration *cfg = [_loopBtn.configuration copy];
    cfg.baseForegroundColor = _looping ? wq_theme_accent() : wq_theme_primary_text();
    _loopBtn.configuration = cfg;
}

- (void)togglePiP
{
    if (!_pip) return;
    if (_pip.isPictureInPictureActive) [_pip stopPictureInPicture];
    else [_pip startPictureInPicture];
}

- (void)setScreenLocked:(BOOL)locked
{
    _screenLocked = locked;
    _controlsCard.hidden = locked;
    _unlockBtn.hidden = !locked;
}

- (void)scrubberDown { _scrubbing = YES; }
- (void)scrubberChanged
{
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (isfinite(dur) && dur > 0) {
        _elapsedLabel.text = wq_format_time(dur * _scrubber.value);
    }
}
- (void)scrubberUp
{
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (isfinite(dur) && dur > 0) {
        [_player seekToTime:CMTimeMakeWithSeconds(dur * _scrubber.value, 600)];
    }
    _scrubbing = NO;
}

#pragma mark - Subtitles

- (void)autoLoadSiblingSubtitles
{
    if (!_sourcePath.length) return;
    NSString *base = _sourcePath.stringByDeletingPathExtension;
    for (NSString *ext in @[@"srt", @"vtt"]) {
        NSString *candidate = [base stringByAppendingPathExtension:ext];
        NSData *data = wq_read(candidate, 4 * 1024 * 1024, nil);
        if (data.length) {
            NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (txt.length) {
                _subtitles = wq_parse_subtitles(txt);
                UIButtonConfiguration *cfg = [_subBtn.configuration copy];
                cfg.baseForegroundColor = wq_theme_accent();
                _subBtn.configuration = cfg;
                break;
            }
        }
    }
}

- (void)pickSubtitles
{
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    UTType *srt = [UTType typeWithFilenameExtension:@"srt"];
    UTType *vtt = [UTType typeWithFilenameExtension:@"vtt"];
    if (srt) [types addObject:srt];
    if (vtt) [types addObject:vtt];
    if (!types.count) [types addObject:UTTypePlainText];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *txt = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (txt.length) {
        _subtitles = wq_parse_subtitles(txt);
        UIButtonConfiguration *cfg = [_subBtn.configuration copy];
        cfg.baseForegroundColor = wq_theme_accent();
        _subBtn.configuration = cfg;
    }
}

- (void)updateSubtitleForTime:(NSTimeInterval)now
{
    if (!_subtitles.count) {
        _subtitleBox.hidden = YES;
        return;
    }
    NSString *active = nil;
    for (WQSubtitleCue *cue in _subtitles) {
        if (now >= cue.start && now <= cue.end) {
            active = cue.text;
            break;
        }
    }
    _subtitleBox.hidden = (active.length == 0);
    _subtitleLabel.text = active;
}

#pragma mark - Lock Screen Controls

- (void)setupRemoteCommands
{
    MPRemoteCommandCenter *rcc = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;
    [rcc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        typeof(self) me = weakSelf;
        if (!me) return MPRemoteCommandHandlerStatusCommandFailed;
        [me.player play];
        me.player.rate = me->_rate;
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf.player pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    rcc.skipForwardCommand.preferredIntervals = @[@10];
    [rcc.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf skipBy:10.0];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    rcc.skipBackwardCommand.preferredIntervals = @[@10];
    [rcc.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf skipBy:-10.0];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        MPChangePlaybackPositionCommandEvent *pos = (MPChangePlaybackPositionCommandEvent *)event;
        [weakSelf.player seekToTime:CMTimeMakeWithSeconds(pos.positionTime, 600)];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateNowPlaying
{
    NSMutableDictionary *info = [NSMutableDictionary new];
    info[MPMediaItemPropertyTitle] = self.title ?: @"WQ Glass";
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    NSTimeInterval now = CMTimeGetSeconds(_player.currentTime);
    if (isfinite(dur) && dur > 0) info[MPMediaItemPropertyPlaybackDuration] = @(dur);
    if (isfinite(now) && now >= 0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(now);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

@end

#pragma mark - Swipeable Gallery & Image Studio

BOOL wq_is_gallery_image_path(NSString *path)
{
    NSString *ext = path.pathExtension.lowercaseString;
    return [@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp", @"tif", @"tiff"] containsObject:ext];
}

@interface WQGalleryPageViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) NSUInteger pageIndex;
@property (nonatomic, strong, readonly) UIImage *loadedImage;
@property (nonatomic, strong, readonly) NSData *loadedData;
@end

@implementation WQGalleryPageViewController {
    UIScrollView *_scroll;
    UIImageView *_imageView;
    UILabel *_errorLabel;
}

- (instancetype)initWithPath:(NSString *)path index:(NSUInteger)index
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _pageIndex = index;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 5.0;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imageView];

    _errorLabel = [UILabel new];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.textColor = wq_theme_secondary_text();
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_imageView.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor],
        [_imageView.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],
        [_imageView.centerXAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.centerXAnchor],
        [_imageView.centerYAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.centerYAnchor],
        [_errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
    ]];

    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleZoom)];
    dbl.numberOfTapsRequired = 2;
    [_scroll addGestureRecognizer:dbl];

    NSString *p = _path;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *err = nil;
        NSData *data = wq_read(p, 48 * 1024 * 1024, &err);
        UIImage *img = nil;
        if (data.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                size_t cnt = CGImageSourceGetCount(src);
                if (cnt > 1) {
                    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:MIN(cnt, (size_t)90)];
                    NSTimeInterval duration = 0;
                    for (size_t i = 0; i < cnt && i < 90; i++) {
                        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                        if (cg) {
                            [frames addObject:[UIImage imageWithCGImage:cg]];
                            CGImageRelease(cg);
                        }
                        duration += 0.08;
                    }
                    if (frames.count) img = [UIImage animatedImageWithImages:frames duration:MAX(0.4, duration)];
                }
                CFRelease(src);
            }
            if (!img) img = [UIImage imageWithData:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGalleryPageViewController *me = weakSelf;
            if (!me) return;
            me->_loadedData = data;
            me->_loadedImage = img;
            if (img) {
                me->_imageView.image = img;
            } else {
                me->_errorLabel.text = err ?: WQLocalized(@"Cannot display image");
                me->_errorLabel.hidden = NO;
            }
        });
    });
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *__unused)scrollView
{
    return _imageView;
}

- (void)toggleZoom
{
    [_scroll setZoomScale:(_scroll.zoomScale > 1.2 ? 1.0 : 2.5) animated:YES];
}

@end

@interface WQGalleryViewController () <UIPageViewControllerDataSource, UIPageViewControllerDelegate>
@end

@implementation WQGalleryViewController {
    NSArray<NSString *> *_paths;
    NSUInteger _currentIndex;
    UIPageViewController *_pager;
    UIVisualEffectView *_bottomBar;
}

- (instancetype)initWithImagePaths:(NSArray<NSString *> *)paths initialIndex:(NSUInteger)index
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _paths = [paths copy];
        _currentIndex = index < paths.count ? index : 0;
        self.title = _paths.count ? _paths[_currentIndex].lastPathComponent : WQLocalized(@"Gallery");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);

    _pager = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
                                             navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                                                           options:@{UIPageViewControllerOptionInterPageSpacingKey: @16}];
    _pager.dataSource = self;
    _pager.delegate = self;
    [self addChildViewController:_pager];
    _pager.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_pager.view];
    [_pager didMoveToParentViewController:self];

    WQGalleryPageViewController *first = [[WQGalleryPageViewController alloc] initWithPath:_paths[_currentIndex] index:_currentIndex];
    [_pager setViewControllers:@[first] direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];

    _bottomBar = wq_theme_make_glass_card(20, YES);
    [self.view addSubview:_bottomBar];

    __weak typeof(self) weakSelf = self;
    UIButton *exifBtn = [self barBtn:@"info.circle" label:WQLocalized(@"EXIF") action:^{ [weakSelf showExif]; }];
    UIButton *saveBtn = [self barBtn:@"square.and.arrow.down" label:WQLocalized(@"Save") action:^{ [weakSelf saveToPhotos]; }];
    UIButton *convBtn = [self barBtn:@"arrow.triangle.2.circlepath" label:WQLocalized(@"Convert") action:^{ [weakSelf convertImage]; }];
    UIButton *shareBtn = [self barBtn:@"square.and.arrow.up" label:WQLocalized(@"Share") action:^{ [weakSelf shareCurrent]; }];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[exifBtn, saveBtn, convBtn, shareBtn]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    [_bottomBar.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_pager.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_pager.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_pager.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_pager.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_bottomBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_bottomBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [_bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:_bottomBar.contentView.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:_bottomBar.contentView.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:_bottomBar.contentView.leadingAnchor constant:8],
        [row.trailingAnchor constraintEqualToAnchor:_bottomBar.contentView.trailingAnchor constant:-8],
    ]];
}

- (UIButton *)barBtn:(NSString *)symbol label:(NSString *)title action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:symbol
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    cfg.title = title;
    cfg.imagePlacement = NSDirectionalRectEdgeTop;
    cfg.imagePadding = 3;
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *in) {
        NSMutableDictionary *out = [in mutableCopy] ?: [NSMutableDictionary new];
        out[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        return out;
    };
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIViewController *)pageViewController:(UIPageViewController *__unused)pvc viewControllerBeforeViewController:(UIViewController *)vc
{
    NSUInteger idx = ((WQGalleryPageViewController *)vc).pageIndex;
    if (idx == 0) return nil;
    return [[WQGalleryPageViewController alloc] initWithPath:_paths[idx - 1] index:idx - 1];
}

- (UIViewController *)pageViewController:(UIPageViewController *__unused)pvc viewControllerAfterViewController:(UIViewController *)vc
{
    NSUInteger idx = ((WQGalleryPageViewController *)vc).pageIndex;
    if (idx + 1 >= _paths.count) return nil;
    return [[WQGalleryPageViewController alloc] initWithPath:_paths[idx + 1] index:idx + 1];
}

- (void)pageViewController:(UIPageViewController *__unused)pvc didFinishAnimating:(BOOL)finished
    previousViewControllers:(NSArray<UIViewController *> *__unused)prev transitionCompleted:(BOOL)completed
{
    if (!finished || !completed) return;
    WQGalleryPageViewController *cur = (WQGalleryPageViewController *)_pager.viewControllers.firstObject;
    _currentIndex = cur.pageIndex;
    self.title = _paths[_currentIndex].lastPathComponent;
}

- (WQGalleryPageViewController *)currentPage
{
    return (WQGalleryPageViewController *)_pager.viewControllers.firstObject;
}

- (void)showExif
{
    NSData *data = [self currentPage].loadedData;
    if (!data.length) return;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSDictionary *props = src ? (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL) : nil;
    if (src) CFRelease(src);
    NSMutableString *msg = [NSMutableString new];
    [msg appendFormat:@"%@ × %@ px\n", props[(NSString *)kCGImagePropertyPixelWidth] ?: @"?", props[(NSString *)kCGImagePropertyPixelHeight] ?: @"?"];
    if (props[(NSString *)kCGImagePropertyColorModel]) [msg appendFormat:@"Color: %@\n", props[(NSString *)kCGImagePropertyColorModel]];
    if (props[(NSString *)kCGImagePropertyProfileName]) [msg appendFormat:@"Profile: %@\n", props[(NSString *)kCGImagePropertyProfileName]];
    NSDictionary *exif = props[(NSString *)kCGImagePropertyExifDictionary];
    if (exif) [msg appendFormat:@"\nEXIF:\n%@", exif];
    wq_alert(self, _paths[_currentIndex].lastPathComponent, msg);
}

- (void)saveToPhotos
{
    UIImage *img = [self currentPage].loadedImage;
    if (!img) return;
    UIImageWriteToSavedPhotosAlbum(img, self, @selector(savedImage:error:ctx:), NULL);
}

- (void)savedImage:(UIImage *__unused)img error:(NSError *)error ctx:(void *__unused)ctx
{
    wq_alert(self, error ? WQLocalized(@"Save Failed") : WQLocalized(@"Saved to Photos"), error.localizedDescription);
}

- (void)convertImage
{
    UIImage *img = [self currentPage].loadedImage;
    NSString *srcPath = _paths[_currentIndex];
    if (!img) return;
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Convert Image"), srcPath.lastPathComponent, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(@"Convert to JPEG", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSData *out = UIImageJPEGRepresentation(img, 0.92);
        [self writeConvertedData:out ext:@"jpg" from:srcPath];
    })];
    [sheet addAction:wq_alert_action(@"Convert to PNG", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSData *out = UIImagePNGRepresentation(img);
        [self writeConvertedData:out ext:@"png" from:srcPath];
    })];
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _bottomBar;
    sheet.popoverPresentationController.sourceRect = _bottomBar.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)writeConvertedData:(NSData *)data ext:(NSString *)ext from:(NSString *)srcPath
{
    if (!data.length) return;
    NSString *base = srcPath.stringByDeletingPathExtension;
    NSString *dest = [base stringByAppendingPathExtension:ext];
    NSString *err = nil;
    if (!wq_create_file(dest, data, &err)) {
        NSString *dl = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject;
        if (dl.length) {
            [NSFileManager.defaultManager createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:nil error:nil];
            dest = [dl stringByAppendingPathComponent:[srcPath.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:ext]];
            [data writeToFile:dest atomically:YES];
            wq_alert(self, WQLocalized(@"Converted"), dest.lastPathComponent);
            return;
        }
        wq_alert(self, WQLocalized(@"Convert Failed"), err);
        return;
    }
    wq_alert(self, WQLocalized(@"Converted"), dest.lastPathComponent);
}

- (void)shareCurrent
{
    UIImage *img = [self currentPage].loadedImage;
    if (!img) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[img] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _bottomBar;
    avc.popoverPresentationController.sourceRect = _bottomBar.bounds;
    [self presentViewController:avc animated:YES completion:nil];
}

@end
