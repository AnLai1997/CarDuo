#import "../common.h"

// Inject vao app nguoi dung: nhan yeu cau xoay tu SpringBoard
%group APPS

static int orientationOverride = -1;

%hook UIApplication
- (id)init
{
    id _self = %orig;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        addObserver:_self selector:NSSelectorFromString(@"scp_handleRotationRequest:")
               name:SCP_NOTIF_ORIENTATION object:[[NSBundle mainBundle] bundleIdentifier]];
    return _self;
}

%new
- (void)scp_handleRotationRequest:(NSNotification *)note
{
    orientationOverride = [note.userInfo[@"orientation"] intValue];
    int o = orientationOverride;
    if (o == -1) o = MAX(1, (int)[[UIDevice currentDevice] orientation]);
    SCPLog("app xoay -> %d", o);
    UIWindow *key = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    ((void (*)(id, SEL, int, float, int))objc_msgSend)(key,
        NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), o, 0.0f, 1);
}
%end

%hook UIWindow
- (void)_setRotatableViewOrientation:(int)orientation duration:(float)duration force:(int)force
{
    if (orientationOverride > 0) return %orig(orientationOverride, duration, force);
    %orig;
}
%end

%end // APPS

%ctor
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    if ([path containsString:@".app"] && bid && ![bid hasPrefix:@"com.apple."]) {
        %init(APPS);
    }
}
