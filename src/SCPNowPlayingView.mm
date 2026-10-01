#import "SCPNowPlayingView.h"
#import "common.h"

// MediaRemote.framework (private) - nap dong
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRUnregisterFn)(void);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*MRSendCommandFn)(unsigned int, id);

enum { MRCmdPlay = 0, MRCmdPause = 1, MRCmdTogglePlayPause = 2, MRCmdNext = 4, MRCmdPrev = 5 };

static MRRegisterFn    fnRegister;
static MRUnregisterFn  fnUnregister;
static MRGetInfoFn     fnGetInfo;
static MRGetIsPlayingFn fnIsPlaying;
static MRSendCommandFn fnSend;

static BOOL loadMediaRemote(void)
{
    static BOOL loaded = NO; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) return;
        fnRegister   = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        fnUnregister = (MRUnregisterFn)dlsym(h, "MRMediaRemoteUnregisterForNowPlayingNotifications");
        fnGetInfo    = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        fnIsPlaying  = (MRGetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        fnSend       = (MRSendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
        loaded = fnGetInfo && fnSend;
    });
    return loaded;
}

@interface SCPNowPlayingView ()
@property (nonatomic, strong) UIImageView *artwork;
@property (nonatomic, strong) UILabel *title, *artist;
@property (nonatomic, strong) UIButton *prev, *play, *next;
@property (nonatomic, strong) id observer;
@property (nonatomic) BOOL playing;
@end

@implementation SCPNowPlayingView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.clipsToBounds = YES;

    _artwork = [[UIImageView alloc] init];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    _artwork.layer.cornerRadius = 10;
    _artwork.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    [self addSubview:_artwork];

    _title = [[UILabel alloc] init];
    _title.textColor = [UIColor whiteColor];
    _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.numberOfLines = 2;
    [self addSubview:_title];

    _artist = [[UILabel alloc] init];
    _artist.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _artist.font = [UIFont systemFontOfSize:13];
    _artist.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_artist];

    _prev = [self button:@"backward.fill" action:@selector(prevTapped)];
    _play = [self button:@"play.fill" action:@selector(playTapped)];
    _next = [self button:@"forward.fill" action:@selector(nextTapped)];
    return self;
}

- (UIButton *)button:(NSString *)symbol action:(SEL)sel
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightBold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGFloat art = MIN(s.width - 24, s.height * 0.45);
    _artwork.frame = CGRectMake((s.width - art) / 2, 12, art, art);
    _title.frame  = CGRectMake(8, CGRectGetMaxY(_artwork.frame) + 8, s.width - 16, 40);
    _artist.frame = CGRectMake(8, CGRectGetMaxY(_title.frame), s.width - 16, 18);
    CGFloat bw = 50, gap = 10, total = bw * 3 + gap * 2, x = (s.width - total) / 2, y = s.height - bw - 10;
    _prev.frame = CGRectMake(x, y, bw, bw);
    _play.frame = CGRectMake(x + bw + gap, y, bw, bw);
    _next.frame = CGRectMake(x + (bw + gap) * 2, y, bw, bw);
}

- (void)start
{
    if (!loadMediaRemote()) { _title.text = @"MediaRemote không khả dụng"; return; }
    if (fnRegister) fnRegister(dispatch_get_main_queue());
    __weak SCPNowPlayingView *weakSelf = self;
    _observer = [[NSNotificationCenter defaultCenter] addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [weakSelf refresh]; }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [weakSelf refresh]; }];
    [self refresh];
}

- (void)stop
{
    if (_observer) [[NSNotificationCenter defaultCenter] removeObserver:_observer];
    _observer = nil;
    if (fnUnregister) fnUnregister();
}

- (void)refresh
{
    if (!fnGetInfo) return;
    __weak SCPNowPlayingView *weakSelf = self;
    fnGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef infoRef) {
        NSDictionary *info = (__bridge NSDictionary *)infoRef;
        SCPNowPlayingView *s = weakSelf; if (!s) return;
        s.title.text  = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"Không phát gì";
        s.artist.text = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        s.artwork.image = art ? [UIImage imageWithData:art] : nil;
    });
    if (fnIsPlaying) {
        fnIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            SCPNowPlayingView *s = weakSelf; if (!s) return;
            s.playing = playing;
            id cfg = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightBold];
            [s.play setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill") withConfiguration:cfg] forState:UIControlStateNormal];
        });
    }
}

- (void)prevTapped { if (fnSend) fnSend(MRCmdPrev, nil); }
- (void)nextTapped { if (fnSend) fnSend(MRCmdNext, nil); }
- (void)playTapped { if (fnSend) fnSend(MRCmdTogglePlayPause, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.5]; }

@end
