#import "SCPCarSplit.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPCarSplit - split CarPlay "that": moi ngan la scene CarPlay cua app (giao dien CarPlay/template),
//  chay trong process CarPlay (DashBoard.framework, iOS 16.5).
//
//  Luong mo 1 app vao ngan:
//    1. Ghi nho bundle -> ngan (pending), gui [DBDashboard handleEvent:[DBEvent eventWithType:4 context:launchInfo]]
//       = dung duong DashBoard mo app khi cham icon.
//    2. DashBoard tao DBApplicationSceneViewController (app template: proxy qua CarPlayTemplateUIHost),
//       foreground scene. Kich thuoc scene lay tu -[DBDashboard sceneFrameForAppInfo:proxyAppInfo:]
//       -> hook tra ve kich thuoc ngan.
//    3. DashBoard goi -[DBDashboardRootViewController presentBaseViewController:...] -> hook dua VC vao ngan.
//  Scene cua ngan duoc giu foreground: hook chan backgroundScene/deactivateScene cho VC dang nam trong ngan.
// =====================================================================

#define SCPC_GAP          4.0     // khe giua 2 o (thanh keo nam gon trong khe; vung cham van rong SCPC_DIVIDER_HIT)
#define SCPC_INSET        0.0     // o sat dock va mep man nhu app toan man -> khong phi cho
#define SCPC_RADIUS       8.0     // chi bo goc giap o ben canh; goc sat mep man de vuong
#define SCPC_BTN          34.0    // nut trong thanh vien thuoc
#define SCPC_PILL         40.0    // be day thanh vien thuoc
#define SCPC_HANDLE_W     36.0
#define SCPC_HANDLE_H     4.0
// Nut keo kieu HyperOS: vien thuoc toi 12 x 40 co 3 cham (vach ngang: nam ngang); 1 lon + 2: o vuong 22 co 4 cham.
// Vung cham rong SCPC_DIVIDER_HIT quanh nut.
#define SCPC_DIVIDER_HIT  26.0
#define SCPC_PENDING_TTL  12.0    // giay: qua thoi gian ma DashBoard chua trinh bay app thi bo pending
#define SCPC_HOME_SETTLE  0.5     // giay: cho DashBoard ve Home truoc khi mo app vao ngan
#define SCPC_LAUNCH_GAP   1.2     // giay: khoang cach toi thieu giua 2 lan mo app
#define SCPC_MAX_PANES    3       // bo cuc toi da 3 o
// Bo cuc: 2 = 2 o, 3 = 3 o deu theo 1 chieu, 13 = 1 o lon + 2 o nho xep chong (o lon ben trai / tren)
#define SCPC_LAYOUT_MAIN_STACK 13
typedef NS_ENUM(NSInteger, SCPCLayoutKind) { SCPCLayoutColumns = 0, SCPCLayoutMainStack = 1 };

@interface UIImage (SCPCarPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

NSString *SCPRealBundleForInfos(id info, id proxyInfo)
{
    NSString *a = info ? objcInvoke(info, @"bundleIdentifier") : nil;
    NSString *b = proxyInfo ? objcInvoke(proxyInfo, @"bundleIdentifier") : nil;
    if (a.length && ![a isEqualToString:SCP_TEMPLATE_HOST]) return a;
    if (b.length && ![b isEqualToString:SCP_TEMPLATE_HOST]) return b;
    return a ?: b;
}

static id SCPCDashboard(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:NSSelectorFromString(@"_currentDashboard")]) return nil;
    return objcInvoke(app, @"_currentDashboard");
}

static UIViewController *SCPCRootVC(void)
{
    id d = SCPCDashboard();
    return d ? objcInvoke(d, @"rootViewController") : nil;
}

static id SCPCLibrary(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:NSSelectorFromString(@"sharedApplicationLibrary")]) return nil;
    return objcInvoke(app, @"sharedApplicationLibrary");
}

static id SCPCAppInfo(NSString *bid)
{
    id lib = SCPCLibrary();
    return (lib && bid) ? objcInvoke_1(lib, @"applicationInfoForBundleIdentifier:", bid) : nil;
}

static BOOL SCPCBool(id obj, NSString *sel)
{
    return obj && [obj respondsToSelector:NSSelectorFromString(sel)] && objcInvokeT(obj, sel, BOOL);
}

// App co giao dien CarPlay (DashBoard hien duoc) va khong phai app he thong cua chinh CarPlay
static BOOL SCPCInfoIsCarPlayApp(id info)
{
    if (!info) return NO;
    NSString *bid = objcInvoke(info, @"bundleIdentifier");
    if (!bid.length || [bid isEqualToString:SCP_TEMPLATE_HOST] || [bid isEqualToString:@"com.apple.CarPlayApp"]
        || [bid isEqualToString:@"com.apple.CarPlaySettings"]
        || [bid isEqualToString:@"com.apple.InCallService"]) return NO;   // man goi dien: DashBoard khong tao scene VC -> khong vao ngan duoc
    if (![info respondsToSelector:NSSelectorFromString(@"carPlayDeclaration")]) return NO;
    if (!objcInvoke(info, @"carPlayDeclaration")) return NO;
    if (SCPCBool(info, @"isHidden") || SCPCBool(info, @"presentsFullScreen")) return NO;
    return YES;
}

static void SCPCSendEvent(unsigned long long type, id context)
{
    id d = SCPCDashboard();
    if (!d) return;
    id ev = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", type, context);
    if (ev) objcCall_1(d, @"handleEvent:", ev);
}

static id SCPCTry(id obj, NSString *sel)
{
    if (!obj || ![obj respondsToSelector:NSSelectorFromString(sel)]) return nil;
    @try { return objcInvoke(obj, sel); } @catch (NSException *e) { return nil; }
}

static NSString *SCPCIconBundle(id icon)
{
    for (NSString *k in @[@"applicationBundleID", @"leafIdentifier"]) {
        id v = SCPCTry(icon, k);
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return nil;
}

static void SCPCAddIcons(NSArray *icons, NSMutableOrderedSet *out)
{
    if (![icons isKindOfClass:[NSArray class]]) return;
    for (id icon in icons) { NSString *b = SCPCIconBundle(icon); if (b) [out addObject:b]; }
}

// Tim cac SBIconListView (man chinh, co the ca dock) -> moi cai lay icon cua ca thu muc chua no (moi trang).
// Giu bo lon nhat = man chinh.
static void SCPCCollectHomeIcons(UIView *v, NSMutableOrderedSet *__strong *best, int depth)
{
    if (!v || depth > 14) return;
    if ([NSStringFromClass([v class]) hasSuffix:@"IconListView"]) {
        NSMutableOrderedSet *got = [NSMutableOrderedSet orderedSet];
        id model = SCPCTry(v, @"model");
        NSArray *lists = SCPCTry(SCPCTry(model, @"folder"), @"lists");
        if ([lists isKindOfClass:[NSArray class]] && lists.count) for (id l in lists) SCPCAddIcons(SCPCTry(l, @"icons"), got);
        else SCPCAddIcons(SCPCTry(model, @"icons"), got);   // khong lay duoc thu muc: it nhat trang nay
        if (got.count > (*best).count) *best = got;
    }
    for (UIView *c in v.subviews) SCPCCollectHomeIcons(c, best, depth + 1);
}

// Bundle cua cac app dang hien tren man chinh CarPlay (theo thu tu), nho lai lan doc duoc gan nhat
// (man chinh co the khong nam trong cay view khi app dang mo). nil = chua doc duoc lan nao.
static NSArray<NSString *> *SCPCHomeScreenBundles(void)
{
    static NSArray<NSString *> *cached;
    NSMutableOrderedSet *found = [NSMutableOrderedSet orderedSet];
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) SCPCCollectHomeIcons(w, &found, 0);
    }
    if (found.count >= 2 && ![found.array isEqualToArray:cached]) {
        cached = found.array;
        SCPLog("CarSplit: man chinh CarPlay co %lu app: %@", (unsigned long)cached.count, [cached componentsJoinedByString:@", "]);
    }
    return cached;
}

// Danh sach app CarPlay: @{ id, name } - chi app dang hien tren man chinh CarPlay (bo app da an trong
// Cai dat > CarPlay > Tuy chinh), cung thu tu nhu man chinh
static NSArray<NSDictionary *> *SCPCCarPlayApps(void)
{
    NSMutableArray *out = [NSMutableArray array];
    id lib = SCPCLibrary();
    NSArray *all = lib ? objcInvoke(lib, @"allInstalledApplications") : nil;
    NSArray<NSString *> *home = SCPCHomeScreenBundles();
    for (id info in all) {
        if (!SCPCInfoIsCarPlayApp(info)) continue;
        NSString *name = objcInvoke(info, @"displayName");
        NSString *bid = objcInvoke(info, @"bundleIdentifier");
        if (home && ![home containsObject:bid]) continue;
        [out addObject:@{@"id": bid, @"name": name.length ? name : bid}];
    }
    if (home) {
        [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSUInteger ia = [home indexOfObject:a[@"id"]], ib = [home indexOfObject:b[@"id"]];
            return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
        }];
    } else {
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
    }
    return out;
}

static UIImage *SCPCAppIcon(NSString *bid)
{
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:2.0];
    }
    return nil;
}

// ---------------------------------------------------------------------
//  Kieu HarmonyOS: icon net manh bo tron tu ve (khong can asset), nen "kinh toi" bo goc lien tuc,
//  nut gom trong thanh vien thuoc, cham thi nut lun nhe.
// ---------------------------------------------------------------------
static UIColor *SCPCInk(void) { return [UIColor colorWithWhite:1 alpha:0.92]; }
static UIColor *SCPCAccent(void) { return [UIColor colorWithRed:0.19 green:0.48 blue:0.97 alpha:1]; }   // #317AF7

// Icon kieu HarmonyOS Symbol: ve tren luoi 24x24, net 1.6 deu, dau net va goc bo tron, roi phong len pt.
// rot: xoay 90 do (trai -> tren) cho kieu chia tren/duoi
static UIImage *SCPCDraw(CGFloat pt, BOOL rot, void (^draw)(UIBezierPath *p))
{
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pt, pt)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGContextScaleCTM(c, pt / 24.0, pt / 24.0);
        if (rot) { CGContextTranslateCTM(c, 24, 0); CGContextRotateCTM(c, M_PI_2); }
        [[UIColor blackColor] set];
        UIBezierPath *p = [UIBezierPath bezierPath];
        p.lineWidth = 1.6; p.lineCapStyle = kCGLineCapRound; p.lineJoinStyle = kCGLineJoinRound;
        draw(p);
        [p stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#define SCPC_M(x, y) [p moveToPoint:CGPointMake(x, y)]
#define SCPC_L(x, y) [p addLineToPoint:CGPointMake(x, y)]
#define SCPC_Q(cx, cy, x, y) [p addQuadCurveToPoint:CGPointMake(x, y) controlPoint:CGPointMake(cx, cy)]
#define SCPC_RR(x, y, w, h, r) [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h) cornerRadius:r]]

// solo (chi mo app nay) / expand / collapse / close / grid (chon app) / swap / split (nut mo split)
static UIImage *SCPCGlyph(NSString *name, CGFloat pt, BOOL rot)
{
    // relayout (ca luc keo duong ranh) dat lai icon -> cache, khong ve lai moi lan
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@/%.0f/%d", name, pt, rot];
    UIImage *hit = cache[key];
    if (hit) return hit;
    UIImage *img = SCPCDraw(pt, rot, ^(UIBezierPath *p) {
        if ([name isEqualToString:@"solo"]) {            // 1 cua so co thanh tieu de
            SCPC_RR(3, 4.5, 18, 15, 3.2);
            SCPC_M(3, 9); SCPC_L(21, 9);
        } else if ([name isEqualToString:@"expand"]) {   // 4 goc huong ra ngoai
            SCPC_M(4, 9); SCPC_L(4, 6.2); SCPC_Q(4, 4, 6.2, 4); SCPC_L(9, 4);
            SCPC_M(15, 4); SCPC_L(17.8, 4); SCPC_Q(20, 4, 20, 6.2); SCPC_L(20, 9);
            SCPC_M(20, 15); SCPC_L(20, 17.8); SCPC_Q(20, 20, 17.8, 20); SCPC_L(15, 20);
            SCPC_M(9, 20); SCPC_L(6.2, 20); SCPC_Q(4, 20, 4, 17.8); SCPC_L(4, 15);
        } else if ([name isEqualToString:@"collapse"]) { // 4 goc huong vao trong
            SCPC_M(9, 4); SCPC_L(9, 7); SCPC_Q(9, 9, 7, 9); SCPC_L(4, 9);
            SCPC_M(15, 4); SCPC_L(15, 7); SCPC_Q(15, 9, 17, 9); SCPC_L(20, 9);
            SCPC_M(20, 15); SCPC_L(17, 15); SCPC_Q(15, 15, 15, 17); SCPC_L(15, 20);
            SCPC_M(4, 15); SCPC_L(7, 15); SCPC_Q(9, 15, 9, 17); SCPC_L(9, 20);
        } else if ([name isEqualToString:@"close"]) {
            SCPC_M(6.5, 6.5); SCPC_L(17.5, 17.5); SCPC_M(17.5, 6.5); SCPC_L(6.5, 17.5);
        } else if ([name isEqualToString:@"grid"]) {     // 4 o bo goc
            SCPC_RR(3.5, 3.5, 7, 7, 2); SCPC_RR(13.5, 3.5, 7, 7, 2);
            SCPC_RR(3.5, 13.5, 7, 7, 2); SCPC_RR(13.5, 13.5, 7, 7, 2);
        } else if ([name isEqualToString:@"swap"]) {     // 2 mui ten nguoc chieu
            SCPC_M(4, 8.5); SCPC_L(19, 8.5); SCPC_M(15.5, 5); SCPC_L(19, 8.5); SCPC_L(15.5, 12);
            SCPC_M(20, 15.5); SCPC_L(5, 15.5); SCPC_M(8.5, 12); SCPC_L(5, 15.5); SCPC_L(8.5, 19);
        } else if ([name isEqualToString:@"split"]) {    // 2 khung canh nhau
            SCPC_RR(3, 4.5, 10, 15, 2.6); SCPC_RR(15, 4.5, 6, 15, 2.6);
        }
    });
    cache[key] = img;
    return img;
}

// Khung cac o cua 1 bo cuc (2 o / 3 o / 1 lon + 2 nho) trong hinh minh hoa co kich thuoc size
static NSArray<NSValue *> *SCPCLayoutBoxes(int layoutID, BOOL vertical, CGSize size)
{
    CGFloat gap = 3;
    NSMutableArray<NSValue *> *boxes = [NSMutableArray array];
    if (layoutID == SCPC_LAYOUT_MAIN_STACK) {
        if (vertical) {
            CGFloat mh = floor((size.height - gap) / 2), bw = floor((size.width - gap) / 2);
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(0, 0, size.width, mh)]];
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(0, mh + gap, bw, size.height - mh - gap)]];
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(bw + gap, mh + gap, size.width - bw - gap, size.height - mh - gap)]];
        } else {
            CGFloat mw = floor((size.width - gap) / 2), th = floor((size.height - gap) / 2);
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(0, 0, mw, size.height)]];
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(mw + gap, 0, size.width - mw - gap, th)]];
            [boxes addObject:[NSValue valueWithCGRect:CGRectMake(mw + gap, th + gap, size.width - mw - gap, size.height - th - gap)]];
        }
        return boxes;
    }
    int n = MAX(1, layoutID);
    CGFloat len = (vertical ? size.height : size.width) - gap * (n - 1), pos = 0;
    for (int i = 0; i < n; i++) {
        CGFloat w = (i == n - 1) ? len - floor(len / n) * (n - 1) : floor(len / n);
        [boxes addObject:[NSValue valueWithCGRect:vertical ? CGRectMake(0, pos, size.width, w) : CGRectMake(pos, 0, w, size.height)]];
        pos += w + gap;
    }
    return boxes;
}

// apps = nil: hinh bo cuc mac dinh (o dau xanh = cho app dang mo). apps != nil: hinh "gan day / yeu thich",
// moi o la icon cua app trong o do.
static UIImage *SCPCLayoutImage(int layoutID, BOOL vertical, CGSize size, NSArray *apps)
{
    NSArray<NSValue *> *boxes = SCPCLayoutBoxes(layoutID, vertical, size);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        for (NSUInteger i = 0; i < boxes.count; i++) {
            CGRect b = boxes[i].CGRectValue;
            if (!apps) {
                [(i == 0 ? SCPCAccent() : [UIColor colorWithWhite:1 alpha:0.85]) setFill];
                [[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:4] fill];
                continue;
            }
            [[UIColor colorWithWhite:1 alpha:0.14] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:4] fill];
            NSString *bid = (i < apps.count && [apps[i] isKindOfClass:[NSString class]]) ? apps[i] : nil;
            UIImage *icon = bid ? SCPCAppIcon(bid) : nil;
            if (!icon) continue;
            CGFloat side = floor(MIN(b.size.width, b.size.height) - 4);
            CGRect ir = CGRectMake(CGRectGetMidX(b) - side / 2, CGRectGetMidY(b) - side / 2, side, side);
            CGContextSaveGState(rc.CGContext);
            [[UIBezierPath bezierPathWithRoundedRect:ir cornerRadius:side * 0.27] addClip];
            [icon drawInRect:ir];
            CGContextRestoreGState(rc.CGContext);
        }
    }];
}

// Cac o bo goc theo mang ti le (icon nut ti le trong menu)
static UIImage *SCPCBoxesGlyph(NSArray<NSNumber *> *fr, BOOL rot, CGFloat pt)
{
    return SCPCDraw(pt, rot, ^(UIBezierPath *p) {
        CGFloat total = 18, gap = 1.6, x = 3;
        CGFloat len = total - gap * (fr.count - 1);
        CGFloat radius = fr.count > 2 ? 1.8 : 2.2;
        for (NSUInteger i = 0; i < fr.count; i++) {
            CGFloat w = (i + 1 == fr.count) ? (3 + total - x) : floor(len * fr[i].doubleValue * 5) / 5;
            SCPC_RR(x, 5, w, 14, radius);
            x += w + gap;
        }
    });
}

// Nen "kinh toi": vien sang manh, bo goc lien tuc (squircle), bong mem
static void SCPCChrome(UIView *v, CGFloat radius)
{
    v.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.94];
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.5;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.35; v.layer.shadowRadius = 8; v.layer.shadowOffset = CGSizeMake(0, 2);
}

// Icon app: squircle kieu HarmonyOS
static void SCPCStyleIcon(UIImageView *iv)
{
    iv.layer.cornerRadius = iv.bounds.size.width * 0.27;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.25 alpha:1];
}

// Nut cham thi lun nhe
@interface SCPCButton : UIButton
@end
@implementation SCPCButton
- (void)setHighlighted:(BOOL)h
{
    BOOL changed = (h != self.highlighted);
    [super setHighlighted:h];
    if (!changed) return;
    [UIView animateWithDuration:h ? 0.12 : 0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.transform = h ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity; }
                     completion:nil];
}
@end

// Nut trong suot, dat trong thanh vien thuoc
static UIButton *SCPCRoundButton(UIImage *img, id target, SEL action)
{
    UIButton *b = [SCPCButton buttonWithType:UIButtonTypeCustom];
    b.bounds = CGRectMake(0, 0, SCPC_BTN, SCPC_BTN);
    b.layer.cornerRadius = SCPC_BTN / 2;
    b.tintColor = SCPCInk();
    [b setImage:img forState:UIControlStateNormal];
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Nut tron dung rieng (co nen kinh toi)
static UIButton *SCPCCircleButton(UIImage *img, CGFloat size, id target, SEL action)
{
    UIButton *b = SCPCRoundButton(img, target, action);
    b.bounds = CGRectMake(0, 0, size, size);
    SCPCChrome(b, size / 2);
    return b;
}

// Thanh vien thuoc chua cac nut (ngang hoac doc). [NSNull null] = vach ngan cach (truoc nut tat / dong)
static UIView *SCPCPill(NSArray *items, BOOL vertical)
{
    CGFloat pad = (SCPC_PILL - SCPC_BTN) / 2, step = SCPC_BTN + 2, sep = 9;
    CGFloat len = pad * 2 - 2;
    for (id it in items) len += [it isKindOfClass:[UIButton class]] ? step : sep;
    UIView *v = [[UIView alloc] initWithFrame:vertical ? CGRectMake(0, 0, SCPC_PILL, len) : CGRectMake(0, 0, len, SCPC_PILL)];
    SCPCChrome(v, SCPC_PILL / 2);
    CGFloat o = pad;
    for (id it in items) {
        if (![it isKindOfClass:[UIButton class]]) {
            UIView *line = [[UIView alloc] init];
            line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
            line.userInteractionEnabled = NO;
            CGFloat c = o - 1 + sep / 2;   // giua khe (2pt sau nut truoc + sep)
            line.frame = vertical ? CGRectMake((SCPC_PILL - 18) / 2, c, 18, 1) : CGRectMake(c, (SCPC_PILL - 18) / 2, 1, 18);
            [v addSubview:line];
            o += sep;
            continue;
        }
        UIButton *b = it;
        b.center = vertical ? CGPointMake(SCPC_PILL / 2, o + SCPC_BTN / 2) : CGPointMake(o + SCPC_BTN / 2, SCPC_PILL / 2);
        o += step;
        [v addSubview:b];
    }
    return v;
}

static void SCPCSetOn(UIButton *b, BOOL on)
{
    b.tintColor = on ? SCPCAccent() : SCPCInk();
    b.backgroundColor = on ? [SCPCAccent() colorWithAlphaComponent:0.22] : [UIColor clearColor];
}

// Hien nhe: mo dan + phong tu 0.85
static void SCPCDropIn(UIView *v)
{
    CGAffineTransform target = v.transform;   // giu ti le thu nho (thanh nut trong o hep)
    v.alpha = 0; v.transform = CGAffineTransformScale(target, 0.85, 0.85);
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ v.alpha = 1; v.transform = target; } completion:nil];
}

static void SCPCPopIn(NSArray<UIView *> *views)
{
    NSInteger i = 0;
    for (UIView *v in views) {
        if (v.hidden) continue;
        v.alpha = 0; v.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [UIView animateWithDuration:0.5 delay:i * 0.04 usingSpringWithDamping:0.6 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ v.alpha = 1; v.transform = CGAffineTransformIdentity; } completion:nil];
        i++;
    }
}

// ---------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------
@interface SCPCarSplitView : UIView
@property (nonatomic, copy) void (^touched)(CGPoint p);
@end
@implementation SCPCarSplitView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (v && self.touched && e.type == UIEventTypeTouches) self.touched(p);
    return v;
}
@end

// Duong ranh mong nhung vung cham rong. Vach thu `index` nam giua o index va index + 1.
@interface SCPCarDividerView : UIView
@property (nonatomic) int index;
@property (nonatomic, strong) UIView *knob;
@end
@implementation SCPCarDividerView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    // Quanh num: vung cham rong de de keo / cham. Doc phan con lai cua vach: hep (+-10) de khong che
    // the trang cua o ngay sat vach (vach ngang nam ngay tren the cua o duoi).
    if (self.knob && !self.knob.hidden && CGRectContainsPoint(CGRectInset(self.knob.frame, -SCPC_DIVIDER_HIT, -SCPC_DIVIDER_HIT), p)) return YES;
    return CGRectContainsPoint(CGRectInset(self.bounds, -10, -10), p);
}
@end

@interface SCPCarTabView : UIView
@end
@implementation SCPCarTabView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -18, -14), p); }
@end

@interface SCPCarPane : NSObject
@property (nonatomic) int slot;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIViewController *vc;   // DBApplicationSceneViewController
@property (nonatomic, strong) UIView *view;           // khung ngan (bo goc)
@property (nonatomic, strong) UIView *host;           // chua view cua app
@property (nonatomic, strong) UIView *handle;         // the trang giua mep tren
@property (nonatomic, strong) UIView *bar;            // hang nut cua ngan
@property (nonatomic, strong) UIButton *fullscreenButton;
@property (nonatomic, strong) NSTimer *barTimer;
@property (nonatomic, strong) UIView *picker;         // bang chon app cho ngan nay
@property (nonatomic, strong) UILabel *bridgeHint;    // "Cham de hien ..." khi app CarBridge cua ngan chua duoc chieu
@property (nonatomic) CGSize sceneSize;               // kich thuoc da bao cho scene lan cuoi
@end
@implementation SCPCarPane
@end

static BOOL SCPCIsBridgedApp(NSString *bid);

@interface SCPCarSplit ()
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, strong) SCPCarSplitView *container;
@property (nonatomic, strong) NSMutableArray<SCPCarPane *> *slots;        // cac o theo thu tu (1..3)
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fractions;      // ti le tung o, tong = 1
                                                                          // (1 lon + 2 nho: [ti le o lon, ti le o nho tren])
@property (nonatomic) NSInteger layoutKind;                              // SCPCLayoutColumns / SCPCLayoutMainStack
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *pending;   // bundle -> @[slot, NSDate]
@property (nonatomic) int fullscreenSlot;
@property (nonatomic) int focusedSlot;
@property (nonatomic) NSInteger allowBackground;
@property (nonatomic, strong) NSMutableArray<SCPCarDividerView *> *dividers;   // vach giua o i va i + 1
@property (nonatomic, strong) UIView *menu;
@property (nonatomic) int menuDivider;               // vach dang mo menu
@property (nonatomic, strong) NSTimer *menuTimer;
@property (nonatomic) BOOL loggedArea;
@property (nonatomic) CFAbsoluteTime nextLaunchAt;   // lan mo app ke tiep som nhat (DashBoard can xong lan truoc)
@property (nonatomic, copy) NSString *bridgedBundle;  // app CarBridge dang duoc chieu vao ngan
@property (nonatomic, readwrite) BOOL bridgeStarting; // CarBridge dang khoi dong chieu (bo qua Home / dismiss cua no)
@property (nonatomic) CGRect lastBridgeFrame;
// Tab tren app CarPlay dang mo toan man (chua split): cham / vuot xuong -> hang icon app CarPlay
@property (nonatomic, strong) UIView *tray;
@property (nonatomic, strong) UIView *trayShield;
@property (nonatomic, strong) NSTimer *trayTimer;
@property (nonatomic, copy) NSString *layoutApp;      // app vao o 1 khi chon bo cuc (nil = cap lan truoc)
@property (nonatomic, strong) NSArray<NSDictionary *> *panelChoices;   // cac lua chon trong bang (tag nut = chi so)
@property (nonatomic) BOOL suppressReopen;           // bat split ma KHONG mo lai app dang toan man vao o 1
// Chua split: nut CarDuo tren dock CarPlay (tren nut Home) + giu icon app tren man chinh de chia man
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, weak) UIView *launcherHost;      // view dang chua nut CarDuo (view dai dock hoac tabParent)
@property (nonatomic) BOOL dockTreeLogged;             // da ghi cay view dai dock (1 lan / tien trinh)
@property (nonatomic, copy) NSString *launcherWhere;  // vi tri nut CarDuo lan truoc (chi de ghi log khi doi)
@property (nonatomic) CFAbsoluteTime lastLauncherCalc;  // lan do dock gan nhat (do lai toi da 1 lan / giay)
@property (nonatomic) CFAbsoluteTime lastIconScan;
@property (nonatomic) BOOL autoLaunchDone;           // da tu mo split cho lan cam xe nay
@end

@implementation SCPCarSplit

+ (instancetype)shared
{
    static SCPCarSplit *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SCPCarSplit new]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _pending = [NSMutableDictionary dictionary];
        _fullscreenSlot = -1;
    }
    return self;
}

- (BOOL)isCarPlayApp:(NSString *)bundleID { return SCPCInfoIsCarPlayApp(SCPCAppInfo(bundleID)) || SCPCIsBridgedApp(bundleID); }

- (NSString *)displayNameFor:(NSString *)bid
{
    id info = SCPCAppInfo(bid);
    NSString *n = info ? objcInvoke(info, @"displayName") : nil;
    return n.length ? n : bid;
}

// Huong chia tu theo man xe: man ngang -> trai / phai, man doc (cao hon rong) -> tren / duoi
- (BOOL)vertical
{
    CGSize sz = self.container ? self.container.bounds.size : CGSizeZero;
    if (sz.width < 1) {
        UIView *parent = [self tabParent];
        if (parent) sz = [self appAreaInParent:parent].size;
    }
    return sz.width > 1 && sz.height > sz.width;
}

- (SCPCarPane *)paneForBundle:(NSString *)bid
{
    if (!bid) return nil;
    for (SCPCarPane *p in self.slots) if (p.vc && [p.bundleID isEqualToString:bid]) return p;
    return nil;
}

- (void)purgePending
{
    NSDate *now = [NSDate date];
    for (NSString *bid in self.pending.allKeys) {
        if ([now timeIntervalSinceDate:self.pending[bid][1]] > SCPC_PENDING_TTL) {
            SCPLog("CarSplit: het han cho %@ (DashBoard khong trinh bay app)", bid);
            [self.pending removeObjectForKey:bid];
        }
    }
}

- (int)pendingSlotForBundle:(NSString *)bid
{
    NSArray *v = bid ? self.pending[bid] : nil;
    if (!v || [[NSDate date] timeIntervalSinceDate:v[1]] > SCPC_PENDING_TTL) return -1;
    return [v[0] intValue];
}

- (BOOL)slotOccupied:(int)s
{
    if (s < 0 || s >= (int)self.slots.count) return NO;
    SCPCarPane *p = self.slots[s];
    if (p.vc || p.picker) return YES;
    for (NSString *bid in self.pending) if ([self pendingSlotForBundle:bid] == s) return YES;
    return NO;
}

- (int)paneCount { return (int)self.slots.count; }

- (BOOL)mainStack { return self.layoutKind == SCPCLayoutMainStack && [self paneCount] == 3; }

// Ma bo cuc hien tai (2 / 3 / 13)
- (int)layoutID { return [self mainStack] ? SCPC_LAYOUT_MAIN_STACK : [self paneCount]; }

// Vach i nam ngang (chia theo chieu doc)? 3 cot: theo kieu chia; 1 lon + 2 nho: vach 1 vuong goc vach 0
- (BOOL)dividerRunsHorizontally:(int)i
{
    BOOL v = [self vertical];
    return ([self mainStack] && i == 1) ? !v : v;
}

// 1 lon + 2 nho. Ngang: o lon ben trai, 2 o nho chong len nhau ben phai. Doc: o lon tren, 2 o nho canh nhau duoi.
- (CGRect)mainStackFrameForSlot:(int)s inArea:(CGRect)a
{
    BOOL v = [self vertical];
    CGFloat mainLen = floor(((v ? a.size.height : a.size.width) - SCPC_GAP) * [self fractionAt:0]);
    CGRect main = v ? CGRectMake(a.origin.x, a.origin.y, a.size.width, mainLen)
                    : CGRectMake(a.origin.x, a.origin.y, mainLen, a.size.height);
    if (s == 0) return main;
    CGRect rest = v ? CGRectMake(a.origin.x, a.origin.y + mainLen + SCPC_GAP, a.size.width, a.size.height - mainLen - SCPC_GAP)
                    : CGRectMake(a.origin.x + mainLen + SCPC_GAP, a.origin.y, a.size.width - mainLen - SCPC_GAP, a.size.height);
    CGFloat first = floor(((v ? rest.size.width : rest.size.height) - SCPC_GAP) * [self fractionAt:1]);
    if (v) {
        if (s == 1) return CGRectMake(rest.origin.x, rest.origin.y, first, rest.size.height);
        return CGRectMake(rest.origin.x + first + SCPC_GAP, rest.origin.y, rest.size.width - first - SCPC_GAP, rest.size.height);
    }
    if (s == 1) return CGRectMake(rest.origin.x, rest.origin.y, rest.size.width, first);
    return CGRectMake(rest.origin.x, rest.origin.y + first + SCPC_GAP, rest.size.width, rest.size.height - first - SCPC_GAP);
}

- (CGFloat)fractionAt:(int)i
{
    int n = [self paneCount];
    if (i < 0 || i >= (int)self.fractions.count || n <= 0) return n > 0 ? 1.0 / n : 1;
    return self.fractions[i].doubleValue;
}

// Ngan cho app moi khi khong chi dinh: ngan trong truoc, het cho thi ngan dang duoc cham gan nhat
- (int)autoSlot
{
    for (int s = 0; s < [self paneCount]; s++) if (![self slotOccupied:s]) return s;
    return MIN(self.focusedSlot, MAX(0, [self paneCount] - 1));
}

// ---------------------------------------------------------------------
//  Hinh hoc
// ---------------------------------------------------------------------
- (CGRect)frameForSlot:(int)s
{
    CGRect b = self.container.bounds;
    CGRect a = CGRectInset(b, SCPC_INSET, SCPC_INSET);
    CGRect none = CGRectMake(a.origin.x, a.origin.y, 0, 0);
    int n = [self paneCount];
    if (s < 0 || s >= n) return none;
    if (self.fullscreenSlot >= 0) return (s == self.fullscreenSlot) ? b : none;
    if (n == 1) return a;
    if ([self mainStack]) return [self mainStackFrameForSlot:s inArea:a];
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCPC_GAP * (n - 1);
    CGFloat used = 0, size = 0;
    for (int i = 0; i <= s; i++) {
        size = (i == n - 1) ? len - used : floor(len * [self fractionAt:i]);
        if (i < s) used += size;
    }
    CGFloat start = used + SCPC_GAP * s;
    return v ? CGRectMake(a.origin.x, a.origin.y + start, a.size.width, size)
             : CGRectMake(a.origin.x + start, a.origin.y, size, a.size.height);
}

// Goc cua o giap o ben canh (duoc bo tron); goc sat mep man / phong to / con 1 o thi vuong
- (CACornerMask)innerCornersForSlot:(int)s
{
    int n = [self paneCount];
    if (self.fullscreenSlot >= 0 || n < 2 || s < 0 || s >= n) return 0;
    BOOL v = [self vertical];
    CACornerMask top = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner, bottom = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    CACornerMask left = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner, right = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    if ([self mainStack]) {
        // O lon: canh giap 2 o nho. O nho: canh giap o lon + canh giap nhau.
        if (s == 0) return v ? bottom : right;
        CACornerMask m = v ? top : left;
        if (s == 1) m |= v ? right : bottom;
        else m |= v ? left : top;
        return m;
    }
    CACornerMask before = v ? top : left, after = v ? bottom : right;
    CACornerMask m = 0;
    if (s > 0) m |= before;
    if (s < n - 1) m |= after;
    return m;
}

- (BOOL)dividersVisible
{
    return self.fullscreenSlot < 0 && [self paneCount] >= 2;
}

- (CGRect)dividerFrameAt:(int)i
{
    CGRect a = CGRectInset(self.container.bounds, SCPC_INSET, SCPC_INSET);
    if ([self mainStack] && i == 1) {
        CGRect t = [self frameForSlot:1];   // vach giua 2 o nho
        if ([self dividerRunsHorizontally:1]) return CGRectMake(t.origin.x, CGRectGetMaxY(t), t.size.width, SCPC_GAP);
        return CGRectMake(CGRectGetMaxX(t), t.origin.y, SCPC_GAP, t.size.height);
    }
    CGRect l = [self frameForSlot:i];
    if ([self vertical]) return CGRectMake(a.origin.x, CGRectGetMaxY(l), a.size.width, SCPC_GAP);
    return CGRectMake(CGRectGetMaxX(l), a.origin.y, SCPC_GAP, a.size.height);
}

// Vung danh cho app tren man xe (toa do cua view cha cua container): contentView cua DashBoard
// tru phan dock/status bar (o canh tai xe). Tim thay view dock thi cat dung phan dock; khong thi dung statusBarInsets.
- (CGRect)appAreaInParent:(UIView *)parent
{
    UIViewController *root = SCPCRootVC();
    UIView *content = objcInvoke(root, @"contentView") ?: root.view;
    CGRect area = [parent convertRect:content.bounds fromView:content];

    UIView *dock = nil;
    @try { id dockVC = objcInvoke(root, @"appDockViewController"); dock = dockVC ? objcInvoke(dockVC, @"view") : nil; } @catch (NSException *e) {}
    CGRect dockRect = CGRectNull;
    if (dock.window && !dock.hidden && parent.window) {
        UIScreen *screen = parent.window.screen ?: dock.window.screen;
        if (screen) {
            CGRect inScreen = [dock convertRect:dock.bounds toCoordinateSpace:screen.coordinateSpace];
            dockRect = [parent convertRect:inScreen fromCoordinateSpace:screen.coordinateSpace];
        }
    }
    CGRect inter = CGRectIsNull(dockRect) ? CGRectNull : CGRectIntersection(area, dockRect);
    UIEdgeInsets ins = UIEdgeInsetsZero;
    id d = SCPCDashboard();
    if ([d respondsToSelector:NSSelectorFromString(@"statusBarInsets")]) {
        ins = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"statusBarInsets"));
    }
    // View dock chi bao khung cum icon (vd {{0,64.5},{45,111}}), khong phai ca thanh dock cao het man.
    // Xac dinh huong dock theo hinh dang cua chinh no va mep no bam vao, roi cat het chieu doc/ngang
    // o mep do. Gop voi statusBarInsets (lay max tung canh) de khong cat trung 2 lan.
    UIEdgeInsets cut = ins;
    if (!CGRectIsNull(inter) && inter.size.width > 1 && inter.size.height > 1) {
        if (inter.size.height >= inter.size.width) {          // dock doc o mep trai/phai
            CGFloat leftGap = inter.origin.x - area.origin.x, rightGap = CGRectGetMaxX(area) - CGRectGetMaxX(inter);
            if (leftGap <= rightGap) cut.left = MAX(cut.left, CGRectGetMaxX(inter) - area.origin.x);
            else cut.right = MAX(cut.right, CGRectGetMaxX(area) - inter.origin.x);
        } else {                                              // dock ngang o mep tren/duoi
            CGFloat topGap = inter.origin.y - area.origin.y, botGap = CGRectGetMaxY(area) - CGRectGetMaxY(inter);
            if (topGap <= botGap) cut.top = MAX(cut.top, CGRectGetMaxY(inter) - area.origin.y);
            else cut.bottom = MAX(cut.bottom, CGRectGetMaxY(area) - inter.origin.y);
        }
    }
    CGRect result = UIEdgeInsetsInsetRect(area, cut);
    if (result.size.width < area.size.width * 0.5 || result.size.height < area.size.height * 0.5) {
        result = UIEdgeInsetsInsetRect(area, ins);            // cat qua tay -> chi dung statusBarInsets
    }
    if (!self.loggedArea) {
        self.loggedArea = YES;
        SCPLog("CarSplit: content=%@ dock=%@ statusBarInsets={%.0f,%.0f,%.0f,%.0f} -> vung app=%@",
               NSStringFromCGRect(area), NSStringFromCGRect(dockRect), ins.top, ins.left, ins.bottom, ins.right, NSStringFromCGRect(result));
    }
    return result;
}

// ---------------------------------------------------------------------
//  Tao / dat container vao cay view cua DashBoard
// ---------------------------------------------------------------------
- (BOOL)ensureContainer
{
    if (self.container.superview) return YES;
    UIViewController *root = SCPCRootVC();
    if (!root) { SCPLog("CarSplit: chua co DBDashboardRootViewController (xe chua ket noi?)"); return NO; }
    UIView *base = objcInvoke(root, @"baseContainerView");
    UIView *parent = base.superview ?: root.view;

    SCPCarSplitView *c = [[SCPCarSplitView alloc] initWithFrame:parent.bounds];
    c.backgroundColor = [UIColor blackColor];
    c.clipsToBounds = YES;
    __weak SCPCarSplit *weakSelf = self;
    c.touched = ^(CGPoint p) {
        SCPCarSplit *me = weakSelf;
        for (SCPCarPane *pane in me.slots) {
            if (pane.view.alpha <= 0 || !CGRectContainsPoint(pane.view.frame, p)) continue;
            me.focusedSlot = pane.slot;
            // Ngan app CarBridge dang trang (CarBridge chi chieu duoc 1 app) -> cham vao thi chieu app nay
            if ([me bridgeWaitingInPane:pane])
                dispatch_async(dispatch_get_main_queue(), ^{ if ([me bridgeWaitingInPane:pane]) [me startBridgeForPane:pane]; });
        }
    };
    self.container = c;
    self.slots = [NSMutableArray array];
    self.fractions = [NSMutableArray array];
    self.dividers = [NSMutableArray array];

    [parent addSubview:c];
    [self raise];
    self.loggedArea = NO;
    c.frame = [self appAreaInParent:parent];
    SCPLog("CarSplit: container trong %@ frame=%@", NSStringFromClass([parent class]), NSStringFromCGRect(c.frame));
    return YES;
}

- (SCPCarPane *)newPane
{
    SCPCarPane *p = [SCPCarPane new];
    p.view = [[UIView alloc] initWithFrame:CGRectZero];
    p.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    p.view.layer.cornerRadius = SCPC_RADIUS;
    p.view.layer.cornerCurve = kCACornerCurveContinuous;
    p.view.clipsToBounds = YES;
    p.host = [[UIView alloc] initWithFrame:CGRectZero];
    p.host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [p.view addSubview:p.host];
    [self setupBarForPane:p];
    return p;
}

// Danh lai so o sau khi them / bot / doi cho
- (void)reindexPanes
{
    for (int i = 0; i < [self paneCount]; i++) self.slots[i].slot = i;
}

- (void)resetFractions
{
    int n = [self paneCount];
    if (self.layoutKind == SCPCLayoutMainStack && n == 3) {
        self.fractions = [NSMutableArray arrayWithObjects:@0.5, @0.5, nil];   // o lon 1/2, 2 o nho chia doi
        return;
    }
    self.fractions = [NSMutableArray array];
    for (int i = 0; i < n; i++) [self.fractions addObject:@(1.0 / MAX(1, n))];
}

- (void)normalizeFractions
{
    double sum = 0;
    for (NSNumber *f in self.fractions) sum += f.doubleValue;
    if ((int)self.fractions.count != [self paneCount] || sum <= 0.01) { [self resetFractions]; return; }
    for (NSUInteger i = 0; i < self.fractions.count; i++) self.fractions[i] = @(self.fractions[i].doubleValue / sum);
}

// Moi cap o ke nhau co 1 vach (keo doi ti le, cham mo menu)
- (void)rebuildDividers
{
    [self hideMenu];
    for (SCPCarDividerView *d in self.dividers) [d removeFromSuperview];
    self.dividers = [NSMutableArray array];
    for (int i = 0; i + 1 < [self paneCount]; i++) [self.dividers addObject:[self newDividerAt:i]];
}

// Dat so o cua bo cuc (1..3): them o trong o cuoi, hoac bo o cuoi (app trong do ve nen)
- (void)setPaneCount:(int)n
{
    n = MAX(1, MIN(SCPC_MAX_PANES, n));
    if (n != 3) self.layoutKind = SCPCLayoutColumns;
    if (n == [self paneCount]) return;
    while ([self paneCount] > n) [self removePaneAt:[self paneCount] - 1 background:YES];
    while ([self paneCount] < n) {
        SCPCarPane *p = [self newPane];
        [self.container addSubview:p.view];
        [self.slots addObject:p];
    }
    [self reindexPanes];
    [self resetFractions];
    [self rebuildDividers];
    SCPLog("CarSplit: bo cuc %d o", n);
}

// Go 1 o khoi bo cuc: app trong o ve nen, o phia sau don len, cac app dang cho mo doi so o theo
- (void)removePaneAt:(int)i background:(BOOL)background
{
    if (i < 0 || i >= [self paneCount]) return;
    SCPCarPane *p = self.slots[i];
    if (p.bundleID && [p.bundleID isEqualToString:self.bridgedBundle]) [self stopBridge];
    [p.barTimer invalidate]; p.barTimer = nil;
    [self removePickerFromPane:p];
    if (p.vc) [self detachVC:p.vc background:background];
    p.vc = nil; p.bundleID = nil;
    [p.view removeFromSuperview];
    if (self.layoutKind == SCPCLayoutMainStack) {   // ti le cua 1 lon + 2 nho khong theo tung o -> chia deu lai
        self.layoutKind = SCPCLayoutColumns;
        [self.fractions removeAllObjects];
    }
    [self.slots removeObjectAtIndex:i];
    if (i < (int)self.fractions.count) [self.fractions removeObjectAtIndex:i];
    [self normalizeFractions];
    for (NSString *bid in self.pending.allKeys) {
        NSArray *v = self.pending[bid];
        int ps = [v[0] intValue];
        if (ps == i) [self.pending removeObjectForKey:bid];
        else if (ps > i) self.pending[bid] = @[@(ps - 1), v[1]];
    }
    if (self.fullscreenSlot == i) self.fullscreenSlot = -1;
    else if (self.fullscreenSlot > i) self.fullscreenSlot--;
    if (self.focusedSlot > i) self.focusedSlot--;
    if (self.focusedSlot >= [self paneCount]) self.focusedSlot = MAX(0, [self paneCount] - 1);
    [self reindexPanes];
    [self rebuildDividers];
}

// Doi bo cuc khi dang chia: giu app theo thu tu o; nhieu o hon -> o moi hien bang chon,
// it o hon -> app o cac o cuoi ve nen
- (void)switchToLayout:(int)layoutID
{
    int n = (layoutID == SCPC_LAYOUT_MAIN_STACK) ? 3 : MAX(2, MIN(SCPC_MAX_PANES, layoutID));
    NSInteger kind = (layoutID == SCPC_LAYOUT_MAIN_STACK) ? SCPCLayoutMainStack : SCPCLayoutColumns;
    if (n == [self paneCount] && kind == self.layoutKind) return;
    SCPLog("CarSplit: doi bo cuc %d -> %d", [self layoutID], layoutID);
    [self setPaneCount:n];
    self.layoutKind = kind;
    self.fullscreenSlot = -1;
    [self resetFractions];
    [self rebuildDividers];
    [self showPickersForEmptySlots];
    [self relayoutAnimated:YES];
}

// Hien bang chon app o moi o con trong
- (void)showPickersForEmptySlots
{
    for (int s = 0; s < [self paneCount]; s++) if (![self slotOccupied:s]) [self showPickerForSlot:s];
}

// Container nam tren app/home cua DashBoard nhung duoi Siri (stackedContainerView)
- (void)raise
{
    UIView *parent = self.container.superview;
    if (!parent) return;
    [parent bringSubviewToFront:self.container];
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    if (stacked.superview == parent) [parent insertSubview:self.container belowSubview:stacked];
}

- (void)rootDidLayout
{
    if (!self.active) { [self refreshAppTab]; return; }
    if (!self.container.superview) return;
    [self refreshHomeButton];   // nut CarDuo tren dock van hien khi dang chia (doi bo cuc)
    CGRect f = [self appAreaInParent:self.container.superview];
    if (!CGRectEqualToRect(f, self.container.frame)) {
        SCPLog("CarSplit: vung app doi %@ -> %@", NSStringFromCGRect(self.container.frame), NSStringFromCGRect(f));
        self.container.frame = f;
        [self relayoutAnimated:NO];
    }
}

- (BOOL)activate
{
    return [self activateWithCount:2];
}

// Bat split theo ma bo cuc (2 / 3 / 13)
- (BOOL)activateWithLayout:(int)layoutID
{
    if (self.active) { [self switchToLayout:layoutID]; return YES; }
    if (![self activateWithCount:(layoutID == SCPC_LAYOUT_MAIN_STACK) ? 3 : layoutID]) return NO;
    if (layoutID == SCPC_LAYOUT_MAIN_STACK) {
        self.layoutKind = SCPCLayoutMainStack;
        [self resetFractions];
        [self rebuildDividers];
        [self relayoutAnimated:NO];
    }
    return YES;
}

// Bat split voi n o (dang bat thi giu bo cuc hien tai)
- (BOOL)activateWithCount:(int)n
{
    if (![SCPPrefs enabled]) return NO;
    [self removeAppTab];
    if (self.active && self.container.superview) { [self raise]; return YES; }
    UIViewController *root = SCPCRootVC();
    UIViewController *cur = objcInvoke(root, @"currentBaseViewController");
    // App dang mo toan man: KHONG nhet VC cua no vao ngan tai cho (DashBoard van tuong app dang toan man
    // -> scene khong doi kich thuoc, nut Home ve man chinh bi ket). Ve Home truoc roi mo lai app do vao
    // ngan trai qua duong mo app binh thuong.
    NSString *reopen = (!self.suppressReopen && cur && [self isAdoptableViewController:cur])
        ? SCPRealBundleForInfos(objcInvoke(cur, @"applicationInfo"), objcInvoke(cur, @"proxyApplicationInfo")) : nil;
    if (cur) {
        SCPLog("CarSplit: dang mo %@ toan man -> ve man chinh truoc%@", cur, reopen ? [NSString stringWithFormat:@", mo lai %@ vao ngan trai", reopen] : @"");
        SCPCSendEvent(1, @"CarDuo: mo split");
        self.nextLaunchAt = CFAbsoluteTimeGetCurrent() + SCPC_HOME_SETTLE;   // cho DashBoard ve Home xong
    }
    if (![self ensureContainer]) return NO;
    self.active = YES;
    self.fullscreenSlot = -1;
    self.focusedSlot = 0;
    [self.pending removeAllObjects];
    self.layoutKind = SCPCLayoutColumns;
    [self setPaneCount:n];   // moi lan chia luon bat dau chia deu (keo vach chia van doi duoc)
    SCPLog("CarSplit: bat split CarPlay (%d o)", [self paneCount]);

    [self relayoutAnimated:NO];
    self.container.alpha = 0;
    self.container.transform = CGAffineTransformMakeScale(0.97, 0.97);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3 options:0
                     animations:^{ self.container.alpha = 1; self.container.transform = CGAffineTransformIdentity; } completion:nil];
    if (reopen) [self openApp:reopen slot:0];
    return YES;
}

// ---------------------------------------------------------------------
//  Mo app
// ---------------------------------------------------------------------
- (void)openApp:(NSString *)bid slot:(int)slot
{
    if (!bid.length) return;
    if (![self isCarPlayApp:bid]) {
        SCPLog("CarSplit: %@ khong co giao dien CarPlay -> bo qua", bid);
        [self toast:@"App này không hỗ trợ CarPlay"];
        return;
    }
    BOOL wasActive = self.active;
    if (![self activate]) return;
    [self purgePending];
    BOOL autoSlotRequested = (slot < 0 || slot >= [self paneCount]);

    SCPCarPane *existing = [self paneForBundle:bid];
    if (autoSlotRequested) slot = existing ? existing.slot : [self autoSlot];
    SCPCarPane *target = self.slots[slot];
    [self removePickerFromPane:target];

    if (existing) {
        if (existing.slot != slot) [self swapSlot:existing.slot with:slot];
        if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
        if (!wasActive && autoSlotRequested) [self showPickersForEmptySlots];
        [self relayoutAnimated:YES];
        // Chon lai app CarBridge dang nam trong ngan: chieu lai neu chua chieu, khong thi kiem tra CBWindow con song
        if (SCPCIsBridgedApp(bid)) {
            if (![self.bridgedBundle isEqualToString:bid]) [self startBridgeForPane:self.slots[slot]];
            else { self.lastBridgeFrame = CGRectNull; [self pushBridgeFrameSoon]; }
        }
        return;
    }

    // Dang cho chinh app nay vao dung ngan nay (vd activate vua mo lai app toan man) -> khong mo lan nua
    if ([self pendingSlotForBundle:bid] == slot) { [self relayoutAnimated:YES]; return; }

    self.pending[bid] = @[@(slot), [NSDate date]];
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
    // Vua mo split tu 1 app: cac o con lai hien bang chon app CarPlay.
    // Dat bang chon TRUOC khi DashBoard tao scene de scene nhan ngay kich thuoc o.
    if (!wasActive && autoSlotRequested) [self showPickersForEmptySlots];
    [self relayoutAnimated:YES];

    id info = SCPCAppInfo(bid);
    id launchInfo = objcInvoke_1(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:", info);
    // Gian cach cac lan mo: DashBoard phai xong phien doi workspace cua lan truoc (va lan ve Home)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double delay = MAX(0, self.nextLaunchAt - now);
    self.nextLaunchAt = now + delay + SCPC_LAUNCH_GAP;
    SCPLog("CarSplit: mo %@ vao ngan %d sau %.1fs (launchInfo=%@)", bid, slot, delay, launchInfo);
    if (!launchInfo) {
        [self.pending removeObjectForKey:bid];
        [self relayoutAnimated:YES];
        [self toast:[NSString stringWithFormat:@"Không mở được %@ trong ngăn", [self displayNameFor:bid]]];
        return;
    }
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPCarSplit *me = weakSelf;
        if (!me.active || [me pendingSlotForBundle:bid] < 0) return;
        SCPCSendEvent(4, launchInfo);
        // App da la app chinh cua workspace (khong nam trong ngan) -> DashBoard khong trinh bay lai -> tu lay VC
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf recoverPending:bid attempt:1];
        });
    });
}

// App mo cham (TikTok, YouTube qua tweak CarPlay khac mat ~4s): thu lai o giay 2, 4, 6 roi moi bao loi
- (void)recoverPending:(NSString *)bid attempt:(int)attempt
{
    if (!self.active || [self pendingSlotForBundle:bid] < 0) return;
    id owner = objcInvoke(SCPCDashboard(), @"workspaceOwner");
    NSDictionary *map = nil;
    @try { map = [owner valueForKey:@"_entityIdentifierToViewControllerMap"]; } @catch (NSException *e) {}
    NSArray *vcs = [map isKindOfClass:[NSDictionary class]] ? map.allValues : @[];
    for (id vc in vcs) {
        if (![self wantsViewController:vc]) continue;
        NSString *b = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
        if (![b isEqualToString:bid]) continue;
        SCPLog("CarSplit: DashBoard khong trinh bay %@ -> lay VC co san", bid);
        [self adoptViewController:vc];
        return;
    }
    if (attempt < 3) {
        SCPLog("CarSplit: %@ chua toi sau %ds, doi them", bid, attempt * 2);
        __weak SCPCarSplit *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf recoverPending:bid attempt:attempt + 1];
        });
        return;
    }
    // Ghi lai cac VC DashBoard dang giu de biet vi sao app (vd YouTube qua tweak CarPlay khac) khong vao ngan
    NSMutableArray *seen = [NSMutableArray array];
    for (id vc in vcs) {
        id info = [vc respondsToSelector:NSSelectorFromString(@"applicationInfo")] ? objcInvoke(vc, @"applicationInfo") : nil;
        NSString *b = info ? SCPRealBundleForInfos(info, [vc respondsToSelector:NSSelectorFromString(@"proxyApplicationInfo")] ? objcInvoke(vc, @"proxyApplicationInfo") : nil) : nil;
        [seen addObject:[NSString stringWithFormat:@"%@(%@ fullScreen=%d)", NSStringFromClass([vc class]), b ?: @"?", SCPCBool(info, @"presentsFullScreen")]];
    }
    SCPLog("CarSplit: khong tim thay VC cua %@ sau khi mo; DashBoard dang giu: %@", bid, [seen componentsJoinedByString:@", "]);
    [self toast:[NSString stringWithFormat:@"%@ chưa chia màn hình được", [self displayNameFor:bid]]];
    [self.pending removeObjectForKey:bid];
    [self relayoutAnimated:YES];
}

- (void)openPairLeft:(NSString *)left right:(NSString *)right
{
    SCPLog("CarSplit: mo cap left=%@ right=%@", left, right);
    if (self.active) [self setPaneCount:2];
    else if (![self activateWithCount:2]) return;
    CGFloat saved = (left && right) ? [SCPPrefs ratioForPairLeft:left right:right] : 0;
    if (saved >= 0.2 && saved <= 0.8) self.fractions = [NSMutableArray arrayWithObjects:@(saved), @(1 - saved), nil];
    [self openAppsInOrder:@[left ?: [NSNull null], right ?: [NSNull null]]];
}

// Mo lan luot cac app vao o 0, 1, ... (NSNull = de trong, hien bang chon). Cach nhau de DashBoard xong
// phien doi workspace cua app truoc.
- (void)openAppsInOrder:(NSArray *)apps
{
    double delay = 0;
    for (int s = 0; s < [self paneCount]; s++) {
        NSString *bid = (s < (int)apps.count && [apps[s] isKindOfClass:[NSString class]]) ? apps[s] : nil;
        if (!bid) { [self showPickerForSlot:s]; continue; }
        if (delay <= 0) { [self openApp:bid slot:s]; delay = 1.2; continue; }
        __weak SCPCarSplit *weakSelf = self;
        int slot = s;
        self.pending[bid] = @[@(slot), [NSDate date]];   // giu cho o nay (khong hien bang chon) trong luc doi
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPCarSplit *me = weakSelf;
            if (!me.active || slot >= [me paneCount]) return;
            [me.pending removeObjectForKey:bid];
            [me openApp:bid slot:slot];
        });
        delay += 1.2;
    }
    [self relayoutAnimated:YES];
}

// ---------------------------------------------------------------------
//  Nhan VC tu DashBoard
// ---------------------------------------------------------------------
- (BOOL)wantsViewController:(UIViewController *)vc
{
    return self.active && [self isAdoptableViewController:vc];
}

- (BOOL)isAdoptableViewController:(UIViewController *)vc
{
    Class cls = objc_getClass("DBApplicationSceneViewController");
    if (!cls || ![vc isKindOfClass:cls]) return NO;
    id info = objcInvoke(vc, @"applicationInfo");
    if (SCPCBool(info, @"presentsFullScreen")) return NO;
    return SCPRealBundleForInfos(info, objcInvoke(vc, @"proxyApplicationInfo")) != nil;
}

- (void)adoptViewController:(UIViewController *)vc
{
    NSString *bid = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
    int slot = [self pendingSlotForBundle:bid];
    SCPCarPane *existing = nil;
    for (SCPCarPane *p in self.slots) if ([p.bundleID isEqualToString:bid]) existing = p;
    if (slot < 0 || slot >= [self paneCount]) slot = existing ? existing.slot : [self autoSlot];
    if (bid) [self.pending removeObjectForKey:bid];
    [self adopt:vc slot:slot];
}

- (void)adopt:(UIViewController *)vc slot:(int)slot
{
    SCPCarPane *p = self.slots[slot];
    NSString *bid = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
    [self removePickerFromPane:p];
    if (p.vc == vc) { [self relayoutAnimated:YES]; return; }

    // Cung app dang nam o o khac (VC cu) -> go VC cu (khong background vi van la scene do), o do chon app khac
    SCPCarPane *vacated = nil;
    for (SCPCarPane *other in self.slots) {
        if (other == p || !other.vc || ![other.bundleID isEqualToString:bid]) continue;
        [self detachVC:other.vc background:NO];
        other.vc = nil; other.bundleID = nil; other.sceneSize = CGSizeZero;
        vacated = other;
    }
    if (p.vc) [self detachVC:p.vc background:![p.bundleID isEqualToString:bid]];

    UIViewController *root = SCPCRootVC();
    BOOL moved = NO;
    if (vc.parentViewController != root) {
        if (vc.parentViewController) { [vc willMoveToParentViewController:nil]; [vc removeFromParentViewController]; }
        [root addChildViewController:vc];
        moved = YES;
    }
    [vc.view removeFromSuperview];
    vc.view.hidden = NO;
    vc.view.alpha = 1;
    vc.view.transform = CGAffineTransformIdentity;
    vc.view.frame = p.host.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [p.host addSubview:vc.view];
    if (moved) [vc didMoveToParentViewController:root];
    vc.additionalSafeAreaInsets = UIEdgeInsetsZero;

    p.vc = vc; p.bundleID = bid; p.sceneSize = CGSizeZero;
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
    self.focusedSlot = slot;
    SCPLog("CarSplit: dua %@ (%@) vao o %d", bid, NSStringFromClass([vc class]), slot);
    [self rememberPair];
    [self rememberRecent];
    [self raise];
    if (vacated) [self showPickerForSlot:vacated.slot];
    [self relayoutAnimated:YES];
    // App iPhone qua CarBridge: scene DashBoard rong -> nho CarBridge chieu app vao dung ngan nay
    if (SCPCIsBridgedApp(bid)) {
        __weak SCPCarSplit *weakSelf = self;
        __weak SCPCarPane *weakPane = p;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPCarPane *pp = weakPane;
            if (weakSelf.active && [pp.bundleID isEqualToString:bid]) [weakSelf startBridgeForPane:pp];
        });
    } else if (self.bridgedBundle) {
        // Mo app khac co the lam CarBridge dong CBWindow cua app dang chieu -> dat lai khung de SpringBoard
        // kiem tra, mat thi bao ve (SCP_NOTIF_CBLOST) va chieu lai
        __weak SCPCarSplit *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.lastBridgeFrame = CGRectNull;
            [weakSelf pushBridgeFrame];
        });
    }
}

// Day scene vao nen ngoai luong cua DashBoard lam no an view cua app (hidden / alpha 0). Lan sau mo app,
// DashBoard dung lai dung VC do ma khong hien lai -> app len man den, cham khong vao. Tra view (va chuoi
// view trinh bay scene ben duoi) ve trang thai hien. Tra ve YES neu co sua.
static BOOL SCPCRevealSceneView(UIView *v, int depth)
{
    if (!v || depth > 4) return NO;
    BOOL fixed = NO;
    if (v.hidden) { v.hidden = NO; fixed = YES; }
    if (v.alpha < 0.99) { v.alpha = 1; fixed = YES; }
    for (UIView *c in v.subviews) {
        NSString *cls = NSStringFromClass([c class]);
        if ([cls hasPrefix:@"_UIScene"] || [cls hasPrefix:@"_UITouchPassthrough"]) {
            if (SCPCRevealSceneView(c, depth + 1)) fixed = YES;
        }
    }
    return fixed;
}

- (void)repairPresentedViewController:(UIViewController *)vc
{
    if (![vc isKindOfClass:[UIViewController class]] || !vc.isViewLoaded) return;
    for (SCPCarPane *p in self.slots) if (p.vc == vc) return;   // dang nam trong ngan, split tu lo
    if (SCPCRevealSceneView(vc.view, 0)) {
        vc.view.transform = CGAffineTransformIdentity;
        SCPLog("CarSplit: app toan man %@ bi an (con sot tu split) -> hien lai",
               SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo")));
    }
}

// Moi o deu da co app -> nho cach chia nay vao "Gan day"
- (void)rememberRecent
{
    NSMutableArray *apps = [NSMutableArray array];
    for (SCPCarPane *p in self.slots) {
        if (!p.vc || !p.bundleID || p.picker) return;
        [apps addObject:p.bundleID];
    }
    [SCPPrefs addRecentLayout:[self layoutID] apps:apps];
}

// Ca 2 ngan deu co app -> nho cap nay (tu mo lai khi cam xe / nut mo split)
- (void)rememberPair
{
    if ([self paneCount] != 2) return;
    NSString *l = self.slots[0].bundleID, *r = self.slots[1].bundleID;
    if (l && r) [SCPPrefs setLastPairLeft:l right:r];
}

- (void)detachVC:(UIViewController *)vc background:(BOOL)background
{
    if (!vc) return;
    if (background) {
        self.allowBackground++;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(vc, NSSelectorFromString(@"backgroundSceneWithCompletion:"), ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: background loi %@", e); }
        self.allowBackground--;
    }
    [vc willMoveToParentViewController:nil];
    [vc.view removeFromSuperview];
    [vc removeFromParentViewController];
    // Tra VC cho DashBoard o trang thai binh thuong de lan sau no mo toan man duoc
    SCPCRevealSceneView(vc.view, 0);
    vc.view.transform = CGAffineTransformIdentity;
}

- (BOOL)protectsViewController:(id)vc
{
    if (!self.active || self.allowBackground > 0) return NO;
    for (SCPCarPane *p in self.slots) if (p.vc == vc) return YES;
    return NO;
}

static id SCPCSceneOf(UIViewController *vc);

- (id)sceneOfViewController:(id)vc
{
    return [vc isKindOfClass:[UIViewController class]] ? SCPCSceneOf(vc) : nil;
}

static NSString *SCPCSceneID(id scene)
{
    @try { return [scene respondsToSelector:NSSelectorFromString(@"identifier")] ? objcInvoke(scene, @"identifier") : nil; }
    @catch (NSException *e) { return nil; }
}

// DashBoard bao didDestroyScene cho MOI VC dang nghe, ke ca scene cua app khac (vd mo GOFA huy scene cu
// cua no -> ca 2 ngan bi dong) -> chi dong ngan khi dung la scene cua VC trong ngan.
- (void)scene:(id)scene destroyedForViewController:(id)vc ownScene:(id)own
{
    for (SCPCarPane *p in self.slots) {
        if (p.vc != vc) continue;
        NSString *sid = SCPCSceneID(scene), *oid = SCPCSceneID(own);
        BOOL mine = own && (own == scene || (sid && [sid isEqualToString:oid]));
        if (!mine) {
            SCPLog("CarSplit: scene %@ bi huy khong phai cua %@ (%@) -> giu ngan %d", sid ?: scene, p.bundleID, oid ?: @"?", p.slot);
            continue;
        }
        SCPLog("CarSplit: scene cua %@ bi huy (app thoat/crash) -> dong ngan %d", p.bundleID, p.slot);
        __weak SCPCarPane *weakPane = p;
        dispatch_async(dispatch_get_main_queue(), ^{
            SCPCarPane *pp = weakPane;
            if (pp && pp.vc == vc && [self.slots containsObject:pp]) [self closeSlot:pp.slot background:NO];
        });
    }
}

- (BOOL)paneSize:(CGSize *)outSize forBundle:(NSString *)bid
{
    if (!self.active || !bid || !self.container) return NO;
    SCPCarPane *p = [self paneForBundle:bid];
    int slot = p ? p.slot : [self pendingSlotForBundle:bid];
    if (slot < 0) return NO;
    CGSize s = [self frameForSlot:slot].size;
    if (s.width < 2 || s.height < 2) return NO;
    if (outSize) *outSize = s;
    return YES;
}

// ---------------------------------------------------------------------
//  Bo cuc
// ---------------------------------------------------------------------
- (void)relayoutAnimated:(BOOL)animated
{
    [self relayoutAnimated:animated pushScenes:YES];
}

- (void)relayoutAnimated:(BOOL)animated pushScenes:(BOOL)push
{
    if (!self.container) return;
    BOOL showDividers = [self dividersVisible];
    void (^changes)(void) = ^{
        for (SCPCarPane *p in self.slots) {
            CGRect f = [self frameForSlot:p.slot];
            BOOL visible = f.size.width > 1 && f.size.height > 1;
            p.view.frame = f;
            p.view.alpha = visible ? 1 : 0;
            p.view.layer.cornerRadius = [self innerCornersForSlot:p.slot] ? SCPC_RADIUS : 0;
            p.view.layer.maskedCorners = [self innerCornersForSlot:p.slot];
            p.host.frame = p.view.bounds;
            p.picker.frame = p.view.bounds;
            [self layoutBarForPane:p];
        }
        for (SCPCarDividerView *d in self.dividers) {
            d.frame = [self dividerFrameAt:d.index];
            d.alpha = showDividers ? 1 : 0;
            [self layoutKnobOf:d];
        }
        // 1 lon + 2: vach 1 (ngang, khong co nut) nam sat nut mui ten 4 huong cua vach 0 -> dua vach 0 len tren
        // cung, neu khong cham vao nua nut se roi vao vach 1 va chi keo duoc 1 chieu
        if ([self mainStack] && self.dividers.count) {
            [self.container bringSubviewToFront:self.dividers[0]];
            if (self.menu) [self.container bringSubviewToFront:self.menu];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes completion:nil];
    } else {
        changes();
    }
    for (SCPCarPane *p in self.slots) p.view.userInteractionEnabled = (p.view.alpha > 0);
    for (SCPCarDividerView *d in self.dividers) d.userInteractionEnabled = showDividers;
    if (push) [self pushSceneSizes];
    [self pushBridgeFrameSoon];   // CBWindow cua CarBridge theo khung ngan moi
    [self updateBridgeHints];
}

// FBScene cua 1 DBApplicationSceneViewController (thu vai ten thuoc tinh), nil neu khong lay duoc
static id SCPCSceneOf(UIViewController *vc)
{
    for (NSString *k in @[@"scene", @"_scene"]) {
        @try { id s = [vc valueForKey:k]; if (s) return s; } @catch (NSException *e) {}
    }
    @try {
        id h = [vc valueForKey:@"sceneHandle"];
        id s = h ? [h valueForKey:@"scene"] : nil;
        if (s) return s;
    } @catch (NSException *e) {}
    return nil;
}

// Kich thuoc scene dang dung (settings.frame); CGSizeZero neu khong doc duoc
static CGSize SCPCSceneSize(UIViewController *vc)
{
    id scene = SCPCSceneOf(vc);
    id st = nil;
    @try { st = [scene respondsToSelector:NSSelectorFromString(@"settings")] ? objcInvoke(scene, @"settings") : nil; } @catch (NSException *e) {}
    if (![st respondsToSelector:NSSelectorFromString(@"frame")]) return CGSizeZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(st, NSSelectorFromString(@"frame")).size;
}

// Bao kich thuoc moi cho scene cua tung ngan: DashBoard tao DBSceneUpdate, lay frame qua hook sceneFrameForAppInfo
- (void)pushSceneSizes
{
    for (SCPCarPane *p in self.slots) {
        if (!p.vc) continue;
        CGSize s = [self frameForSlot:p.slot].size;
        if (s.width < 2 || s.height < 2 || CGSizeEqualToSize(s, p.sceneSize)) continue;
        p.sceneSize = s;
        SCPLog("CarSplit: scene %@ -> %@", p.bundleID, NSStringFromCGSize(s));
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(p.vc, NSSelectorFromString(@"foregroundSceneWithSettings:completion:"), nil, ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: foregroundScene loi %@", e); }
        UIViewController *vc = p.vc;
        __weak SCPCarSplit *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *h = nil;
            @try { h = objcInvoke(vc, @"sceneHostView"); } @catch (NSException *e) {}
            if (h && h.superview == vc.view && !CGRectEqualToRect(h.frame, vc.view.bounds)) {
                SCPLog("CarSplit: sceneHostView %@ -> %@", NSStringFromCGRect(h.frame), NSStringFromCGRect(vc.view.bounds));
                h.frame = vc.view.bounds;
            }
        });
        // Kiem tra scene da doi kich thuoc that chua; chua thi dua scene ve nen roi len lai 1 lan
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf verifySceneOfPane:p expected:s retry:YES];
        });
    }
}

- (void)verifySceneOfPane:(SCPCarPane *)p expected:(CGSize)s retry:(BOOL)retry
{
    if (!self.active || !p.vc || !CGSizeEqualToSize(p.sceneSize, s)) return;   // da doi tiep / da dong
    CGSize cur = SCPCSceneSize(p.vc);
    if (CGSizeEqualToSize(cur, CGSizeZero)) { SCPLog("CarSplit: khong doc duoc kich thuoc scene %@", p.bundleID); return; }
    BOOL ok = (fabs(cur.width - s.width) < 2 && fabs(cur.height - s.height) < 2)
           || (fabs(cur.width - s.height) < 2 && fabs(cur.height - s.width) < 2);   // co the bi dao chieu
    SCPLog("CarSplit: scene %@ that = %@ (can %@)%@", p.bundleID, NSStringFromCGSize(cur), NSStringFromCGSize(s),
           ok ? @"" : (retry ? @" -> ve nen roi len lai" : @" -> van sai"));
    if (ok || !retry) return;
    UIViewController *vc = p.vc;
    self.allowBackground++;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, NSSelectorFromString(@"backgroundSceneWithCompletion:"), ^{});
    } @catch (NSException *e) { SCPLog("CarSplit: background loi %@", e); }
    self.allowBackground--;
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPCarSplit *me = weakSelf;
        if (!me.active || p.vc != vc) return;
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(vc, NSSelectorFromString(@"foregroundSceneWithSettings:completion:"), nil, ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: foregroundScene loi %@", e); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf verifySceneOfPane:p expected:s retry:NO];
        });
    });
}

// Doi cho 2 o (o, ti le, app dang cho mo)
- (void)swapSlot:(int)a with:(int)b
{
    int n = [self paneCount];
    if (a == b || a < 0 || b < 0 || a >= n || b >= n) return;
    [self.slots exchangeObjectAtIndex:a withObjectAtIndex:b];
    if (![self mainStack] && (int)self.fractions.count == n) [self.fractions exchangeObjectAtIndex:a withObjectAtIndex:b];
    if (self.fullscreenSlot == a) self.fullscreenSlot = b;
    else if (self.fullscreenSlot == b) self.fullscreenSlot = a;
    for (NSString *bid in self.pending.allKeys) {
        NSArray *v = self.pending[bid];
        int ps = [v[0] intValue];
        if (ps == a) self.pending[bid] = @[@(b), v[1]];
        else if (ps == b) self.pending[bid] = @[@(a), v[1]];
    }
    [self reindexPanes];
    SCPLog("CarSplit: doi cho o %d va %d", a, b);
    [self rememberPair];
    [self rememberRecent];
    [self relayoutAnimated:YES];
}

- (void)toggleFullscreenForSlot:(int)slot
{
    self.fullscreenSlot = (self.fullscreenSlot == slot) ? -1 : slot;
    [self relayoutAnimated:YES];
}

// ---------------------------------------------------------------------
//  Dong
// ---------------------------------------------------------------------
- (void)closeSlot:(int)slot background:(BOOL)background
{
    if (!self.active || slot < 0 || slot >= [self paneCount]) return;
    NSString *bid = self.slots[slot].bundleID;
    [self removePaneAt:slot background:background];
    SCPLog("CarSplit: dong o %d (%@), con %d o", slot, bid, [self paneCount]);
    [self afterPaneRemoved:bid];
}

// Sau khi bot 1 o: het o -> tat split; con 1 o -> app do ve toan man nhu luc chua chia; con lai -> chia lai
- (void)afterPaneRemoved:(NSString *)closedBid
{
    int n = [self paneCount];
    if (n == 0) { [self closeGoingHome:YES]; return; }
    if (n == 1) {
        NSString *keep = self.slots[0].bundleID;
        if (!keep) for (NSString *b in self.pending) if ([self pendingSlotForBundle:b] == 0) keep = b;
        if (keep) [self soloBundle:keep]; else [self closeGoingHome:YES];
        return;
    }
    [self relayoutAnimated:YES];

    // Workspace cua DashBoard van coi app vua dong la app chinh -> chuyen sang 1 app con lai cho khop
    NSString *activeBase = objcInvoke(objcInvoke(SCPCDashboard(), @"workspaceOwner"), @"activeBaseApplicationBundleID");
    SCPCarPane *other = nil;
    for (SCPCarPane *p in self.slots) if (p.vc && p.bundleID) { other = p; break; }
    if (closedBid && other && [activeBase isEqualToString:closedBid]) {
        NSString *ob = other.bundleID;
        self.pending[ob] = @[@(other.slot), [NSDate date]];
        id launchInfo = objcInvoke_1(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:", SCPCAppInfo(ob));
        if (launchInfo) SCPCSendEvent(4, launchInfo);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.pending removeObjectForKey:ob];
        });
    }
}

// Tat split, mo `bid` toan man nhu khi cham icon (ve Home truoc de DashBoard mo lai tu dau)
- (void)soloBundle:(NSString *)bid
{
    if (!self.active) return;
    if (!bid) { [self closeGoingHome:YES]; return; }
    SCPLog("CarSplit: chi giu %@ -> mo toan man", bid);
    id launchInfo = objcInvoke_1(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:", SCPCAppInfo(bid));
    [self closeGoingHome:YES];
    if (!launchInfo) return;
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf && !weakSelf.active) SCPCSendEvent(4, launchInfo);
    });
}

- (void)closeApp:(NSString *)bundleID
{
    SCPCarPane *p = [self paneForBundle:bundleID];
    if (self.active && p) [self closeSlot:p.slot background:YES];
}

- (void)closeGoingHome:(BOOL)goHome
{
    if (!self.active) return;
    SCPLog("CarSplit: tat split (goHome=%d)", goHome);
    [self stopBridge];
    for (SCPCarPane *p in self.slots) {
        [p.barTimer invalidate]; p.barTimer = nil;
        if (p.vc) [self detachVC:p.vc background:YES];
        p.vc = nil; p.bundleID = nil;
        [p.picker removeFromSuperview]; p.picker = nil;
    }
    self.active = NO;
    [self.pending removeAllObjects];
    [self hideMenu];
    UIView *c = self.container;
    self.container = nil; self.slots = nil; self.fractions = nil; self.dividers = nil;
    [UIView animateWithDuration:0.2 animations:^{ c.alpha = 0; } completion:^(BOOL f) { [c removeFromSuperview]; }];
    if (goHome) SCPCSendEvent(1, @"CarDuo: dong split");
    [self refreshAppTabSoon];   // DashBoard co the dang mo 1 app toan man -> hien tab
}

// Settings chi cho chon app ma CarPlay hien duoc (app CarPlay that va app CarBridge)
- (void)publishCarPlayApps
{
    NSMutableArray *ids = [NSMutableArray array], *bridged = [NSMutableArray array];
    for (NSDictionary *a in SCPCCarPlayApps()) {
        if (SCPCIsBridgedApp(a[@"id"])) [bridged addObject:a[@"id"]]; else [ids addObject:a[@"id"]];
    }
    // App CarBridge co the khong nam trong thu vien app cua DashBoard -> hoi thang CarBridge
    Class ws = objc_getClass("LSApplicationWorkspace");
    NSArray *all = ws ? objcInvoke(objcInvoke(ws, @"defaultWorkspace"), @"allInstalledApplications") : nil;
    NSArray<NSString *> *home = SCPCHomeScreenBundles();
    for (id proxy in all) {
        NSString *bid = objcInvoke(proxy, @"bundleIdentifier");
        if (home && ![home containsObject:bid]) continue;   // da an khoi man chinh CarPlay
        if (bid.length && ![bridged containsObject:bid] && SCPCIsBridgedApp(bid)) [bridged addObject:bid];
    }
    if (ids.count) [SCPPrefs setCarPlayApps:ids];
    [SCPPrefs setCarBridgeApps:bridged];
    SCPLog("CarSplit: %lu app CarPlay + %lu app CarBridge cho Settings: %@", (unsigned long)ids.count, (unsigned long)bridged.count, bridged);
}

// DashBoard bi huy (ngat xe): bo trang thai, khong goi gi vao scene nua
- (void)dashboardInvalidated
{
    [self removeAppTab];
    [self removeHomeButton];
    self.autoLaunchDone = NO;
    if (!self.active) return;
    SCPLog("CarSplit: DashBoard invalidate -> bo split");
    self.bridgedBundle = nil; self.bridgeStarting = NO;   // CarBridge tu xu ly ngat xe
    self.active = NO;
    [self.pending removeAllObjects];
    for (SCPCarPane *p in self.slots) [p.barTimer invalidate];
    [self.menuTimer invalidate]; self.menuTimer = nil;
    [self.container removeFromSuperview];
    self.container = nil; self.slots = nil; self.fractions = nil; self.dividers = nil; self.menu = nil;
}

// ---------------------------------------------------------------------
//  Option cua tung o: the trang giua mep tren -> hang nut. Thu tu: hay dung va an toan truoc
//  (Chon app, Phong to), thoat split (Chi mo app nay), vach ngan, cuoi cung la Tat app (mat app).
// ---------------------------------------------------------------------
- (void)setupBarForPane:(SCPCarPane *)p
{
    UIView *h = [[SCPCarTabView alloc] initWithFrame:CGRectMake(0, 0, SCPC_HANDLE_W, SCPC_HANDLE_H)];
    h.backgroundColor = [UIColor colorWithWhite:1 alpha:0.8];
    h.layer.cornerRadius = SCPC_HANDLE_H / 2;
    h.layer.shadowColor = [UIColor blackColor].CGColor;
    h.layer.shadowOpacity = 0.35; h.layer.shadowRadius = 3; h.layer.shadowOffset = CGSizeZero;
    [h addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapped:)]];
    [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanned:)]];
    p.handle = h;
    [p.view addSubview:h];

    UIButton *solo = SCPCRoundButton(SCPCGlyph(@"solo", 20, NO), self, @selector(paneSolo:));
    p.fullscreenButton = SCPCRoundButton(SCPCGlyph(@"expand", 20, NO), self, @selector(paneFullscreen:));
    UIButton *close = SCPCRoundButton(SCPCGlyph(@"close", 20, NO), self, @selector(paneClose:));
    UIButton *choose = SCPCRoundButton(SCPCGlyph(@"grid", 20, NO), self, @selector(paneChoose:));
    UIView *bar = SCPCPill(@[choose, p.fullscreenButton, solo, [NSNull null], close], NO);
    bar.hidden = YES;
    p.bar = bar;
    [p.view addSubview:bar];
}

- (SCPCarPane *)paneForView:(UIView *)v
{
    for (SCPCarPane *p in self.slots) if ([v isDescendantOfView:p.view]) return p;
    return nil;
}

- (void)layoutBarForPane:(SCPCarPane *)p
{
    CGSize s = p.view.bounds.size;
    p.handle.center = CGPointMake(s.width / 2, 5 + SCPC_HANDLE_H / 2);
    p.handle.hidden = (p.vc == nil);   // dang chon app thi khong can
    p.bar.center = CGPointMake(s.width / 2, SCPC_HANDLE_H + 12 + SCPC_PILL / 2);
    // O hep (3 o, ~150pt): thu nho ca thanh nut cho vua o thay vi bi cat mep
    CGFloat avail = s.width - 10, bw = p.bar.bounds.size.width;
    CGFloat k = (bw > avail && avail > 40) ? avail / bw : 1;
    p.bar.transform = CGAffineTransformMakeScale(k, k);
    BOOL full = (self.fullscreenSlot == p.slot);
    [p.fullscreenButton setImage:SCPCGlyph(full ? @"collapse" : @"expand", 20, NO) forState:UIControlStateNormal];
    SCPCSetOn(p.fullscreenButton, full);
    [p.view bringSubviewToFront:p.handle];
    [p.view bringSubviewToFront:p.bar];
}

- (void)setBarVisible:(BOOL)visible forPane:(SCPCarPane *)p
{
    [p.barTimer invalidate]; p.barTimer = nil;
    if (visible) {
        [self hideMenu];
        for (SCPCarPane *o in self.slots) if (o != p) [self setBarVisible:NO forPane:o];
        [self layoutBarForPane:p];
        BOOL wasHidden = p.bar.hidden;
        p.bar.hidden = NO;
        if (wasHidden) SCPCDropIn(p.bar);
        __weak SCPCarSplit *weakSelf = self;
        __weak SCPCarPane *weakPane = p;
        p.barTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) {
            if (weakPane) [weakSelf setBarVisible:NO forPane:weakPane];
        }];
        if (wasHidden && [p.bundleID isEqualToString:self.bridgedBundle]) [self pushBridgeFrame];   // nhuong cho thanh nut cung luc thanh hien
    } else if (!p.bar.hidden) {
        UIView *bar = p.bar;
        BOOL bridged = p.bundleID && [p.bundleID isEqualToString:self.bridgedBundle];
        __weak SCPCarSplit *weakSelf = self;
        [UIView animateWithDuration:0.16 animations:^{ bar.alpha = 0; } completion:^(BOOL f) {
            bar.hidden = YES; bar.alpha = 1;
            if (bridged) [weakSelf pushBridgeFrame];   // keo app len lai ngay khi thanh an xong
        }];
    }
}

- (void)handleTapped:(UITapGestureRecognizer *)g
{
    SCPCarPane *p = [self paneForView:g.view];
    if (p) [self setBarVisible:p.bar.hidden forPane:p];
}

- (void)handlePanned:(UIPanGestureRecognizer *)g
{
    SCPCarPane *p = [self paneForView:g.view];
    if (!p || g.state != UIGestureRecognizerStateEnded) return;
    CGFloat ty = [g translationInView:p.view].y;
    if (ty > 10) [self setBarVisible:YES forPane:p];
    else if (ty < -10) [self setBarVisible:NO forPane:p];
}

- (void)paneSolo:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self soloBundle:p.bundleID];
}

- (void)paneChoose:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self showPickerForSlot:p.slot];
}

- (void)paneFullscreen:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self toggleFullscreenForSlot:p.slot];
}

- (void)paneClose:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self closeSlot:p.slot background:YES];
}

// ---------------------------------------------------------------------
//  Duong ranh + num keo: keo doi ti le, cham mo menu (doi cho / ti le / ve CarPlay)
// ---------------------------------------------------------------------
static UIColor *SCPCKnobColor(void) { return [UIColor colorWithWhite:0.16 alpha:0.92]; }

// Nut keo dang keo: phong nhe + nen xanh; tha ra ve nen toi
static void SCPCKnobActive(UIView *knob, BOOL on)
{
    [UIView animateWithDuration:on ? 0.15 : 0.2 animations:^{
        knob.transform = on ? CGAffineTransformMakeScale(1.15, 1.15) : CGAffineTransformIdentity;
        knob.backgroundColor = on ? SCPCAccent() : SCPCKnobColor();
    }];
}

// Kieu nut: 1 = vien thuoc dung (3 cham doc), 2 = vien thuoc nam (3 cham ngang), 3 = o vuong 4 cham (1 lon + 2).
// Chi ve lai khi doi kieu (tag luu kieu hien tai).
static void SCPCKnobStyle(UIView *knob, NSInteger style)
{
    if (knob.tag == style) return;
    knob.tag = style;
    for (UIView *sub in [knob.subviews copy]) [sub removeFromSuperview];
    CGSize sz = (style == 3) ? CGSizeMake(22, 22) : (style == 1 ? CGSizeMake(12, 40) : CGSizeMake(40, 12));
    knob.bounds = CGRectMake(0, 0, sz.width, sz.height);
    knob.layer.cornerRadius = (style == 3) ? 7 : 6;
    CGFloat mx = sz.width / 2, my = sz.height / 2, dot = 3;
    NSArray<NSValue *> *pts = (style == 3)
        ? @[[NSValue valueWithCGPoint:CGPointMake(mx - 3.5, my - 3.5)], [NSValue valueWithCGPoint:CGPointMake(mx + 3.5, my - 3.5)],
            [NSValue valueWithCGPoint:CGPointMake(mx - 3.5, my + 3.5)], [NSValue valueWithCGPoint:CGPointMake(mx + 3.5, my + 3.5)]]
        : (style == 1)
        ? @[[NSValue valueWithCGPoint:CGPointMake(mx, my - 7)], [NSValue valueWithCGPoint:CGPointMake(mx, my)], [NSValue valueWithCGPoint:CGPointMake(mx, my + 7)]]
        : @[[NSValue valueWithCGPoint:CGPointMake(mx - 7, my)], [NSValue valueWithCGPoint:CGPointMake(mx, my)], [NSValue valueWithCGPoint:CGPointMake(mx + 7, my)]];
    for (NSValue *pv in pts) {
        UIView *d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, dot, dot)];
        d.center = pv.CGPointValue;
        d.backgroundColor = [UIColor whiteColor];
        d.layer.cornerRadius = dot / 2;
        d.userInteractionEnabled = NO;
        [knob addSubview:d];
    }
}

- (SCPCarDividerView *)newDividerAt:(int)i
{
    SCPCarDividerView *d = [[SCPCarDividerView alloc] initWithFrame:CGRectZero];
    d.index = i;
    d.backgroundColor = [UIColor clearColor];
    // Nut keo kieu HyperOS (1 lon + 2: 1 nut duy nhat o cho giao 2 vach, keo duoc 2 chieu)
    UIView *knob = [[UIView alloc] initWithFrame:CGRectZero];
    knob.backgroundColor = SCPCKnobColor();
    knob.layer.cornerCurve = kCACornerCurveContinuous;
    knob.layer.borderWidth = 0.5;
    knob.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    knob.layer.shadowColor = [UIColor blackColor].CGColor;
    knob.layer.shadowOpacity = 0.5; knob.layer.shadowRadius = 5; knob.layer.shadowOffset = CGSizeMake(0, 2);
    knob.userInteractionEnabled = NO;
    [d addSubview:knob];
    d.knob = knob;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPanned:)];
    pan.maximumNumberOfTouches = 1;
    [d addGestureRecognizer:pan];
    [d addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dividerTapped:)]];
    [self.container addSubview:d];
    return d;
}

- (void)layoutKnobOf:(SCPCarDividerView *)d
{
    CGSize s = d.bounds.size;
    BOOL v = [self dividerRunsHorizontally:d.index];
    UIView *knob = d.knob;
    SCPCKnobStyle(knob, [self mainStack] ? 3 : (v ? 2 : 1));
    if ([self mainStack]) {
        // 1 lon + 2: 1 nut duy nhat o cho giao 2 vach (nam tren vach 0), vach 1 khong co nut
        knob.hidden = (d.index != 0);
        if (d.index == 0) {
            CGRect d1 = [self dividerFrameAt:1];
            CGPoint j = [d convertPoint:CGPointMake(CGRectGetMidX(d1), CGRectGetMidY(d1)) fromView:self.container];
            knob.center = [self vertical] ? CGPointMake(j.x, s.height / 2) : CGPointMake(s.width / 2, j.y);
        }
    } else {
        knob.hidden = NO;
        // Vach ngang: nut lech sang 1/4 chieu dai, khong trung the trang o giua mep tren o phia duoi
        knob.center = v ? CGPointMake(MAX(knob.bounds.size.width / 2 + 6, s.width * 0.25), s.height / 2) : CGPointMake(s.width / 2, s.height / 2);
    }
    [self.container bringSubviewToFront:d];
    if (self.menu) [self.container bringSubviewToFront:self.menu];
}

- (void)dividerPanned:(UIPanGestureRecognizer *)g
{
    // Keo vach i: chi doi ti le 2 o hai ben (o i va i + 1), cac o khac giu nguyen
    SCPCarDividerView *d = (SCPCarDividerView *)g.view;
    int i = d.index, n = [self paneCount];
    if (i < 0 || i + 1 >= n) return;
    if ([self mainStack]) { [self mainStackDividerPanned:g]; return; }
    static CGFloat startA = 0.5, startB = 0.5;
    CGRect a = CGRectInset(self.container.bounds, SCPC_INSET, SCPC_INSET);
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCPC_GAP * (n - 1);
    if (len < 10) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        startA = [self fractionAt:i]; startB = [self fractionAt:i + 1];
        [self hideMenu];
        SCPCKnobActive(d.knob, YES);
    }
    CGPoint t = [g translationInView:self.container];
    CGFloat pair = startA + startB, minF = (n == 2) ? 0.2 : 0.15;
    CGFloat na = MIN(pair - minF, MAX(minF, startA + (v ? t.y : t.x) / len));
    BOOL ended = (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled);
    if (ended) {
        SCPCKnobActive(d.knob, NO);
        if (n == 2) for (NSNumber *snap in @[@0.3, @0.5, @0.7]) if (fabs(na - snap.doubleValue) < 0.04) { na = snap.doubleValue; break; }
    }
    if ((int)self.fractions.count != n) [self resetFractions];
    self.fractions[i] = @(na);
    self.fractions[i + 1] = @(pair - na);
    if (ended) {
        [self relayoutAnimated:YES];   // tha tay moi bao kich thuoc moi cho scene
        [self saveRatio];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self relayoutAnimated:NO pushScenes:NO];
    [CATransaction commit];
}

// 1 lon + 2 nho: vach 0 doi be rong o lon, vach 1 doi chieu cao (rong) 2 o nho
// 1 lon + 2. Keo nut o cho giao 2 vach: doi ca be rong o lon (f0) lan chieu cao 2 o nho (f1) cung luc.
// Keo doc theo vach (khong cham nut): vach 0 doi f0, vach 1 doi f1.
- (void)mainStackDividerPanned:(UIPanGestureRecognizer *)g
{
    SCPCarDividerView *d = (SCPCarDividerView *)g.view;
    int i = d.index;
    static CGFloat start0 = 0.5, start1 = 0.5;
    static BOOL both = NO;
    CGRect a = CGRectInset(self.container.bounds, SCPC_INSET, SCPC_INSET);
    BOOL along0 = [self dividerRunsHorizontally:0], along1 = [self dividerRunsHorizontally:1];
    CGRect rest = CGRectUnion([self frameForSlot:1], [self frameForSlot:2]);
    CGFloat len0 = (along0 ? a.size.height : a.size.width) - SCPC_GAP;
    CGFloat len1 = (along1 ? rest.size.height : rest.size.width) - SCPC_GAP;
    if (len0 < 10 || len1 < 10) return;
    if ((int)self.fractions.count != 2) [self resetFractions];
    if (g.state == UIGestureRecognizerStateBegan) {
        start0 = [self fractionAt:0]; start1 = [self fractionAt:1];
        both = (i == 0 && !d.knob.hidden && CGRectContainsPoint(CGRectInset(d.knob.frame, -SCPC_DIVIDER_HIT, -SCPC_DIVIDER_HIT), [g locationInView:d]));
        [self hideMenu];
        if (both || i == 0) SCPCKnobActive(d.knob, YES);
    }
    CGPoint t = [g translationInView:self.container];
    CGFloat f0 = start0, f1 = start1;
    if (i == 0) f0 = MIN(0.75, MAX(0.25, start0 + (along0 ? t.y : t.x) / len0));
    if (i == 1 || both) f1 = MIN(0.75, MAX(0.25, start1 + (along1 ? t.y : t.x) / len1));
    BOOL ended = (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled);
    if (ended) {
        if (both || i == 0) SCPCKnobActive(d.knob, NO);
        if (fabs(f0 - 0.5) < 0.04) f0 = 0.5;
        if (fabs(f1 - 0.5) < 0.04) f1 = 0.5;
    }
    self.fractions[0] = @(f0);
    self.fractions[1] = @(f1);
    if (ended) {
        [self relayoutAnimated:YES];
        [self saveRatio];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self relayoutAnimated:NO pushScenes:NO];
    [CATransaction commit];
}

- (void)saveRatio
{
    NSMutableArray *txt = [NSMutableArray array];
    for (NSNumber *f in self.fractions) [txt addObject:[NSString stringWithFormat:@"%.2f", f.doubleValue]];
    SCPLog("CarSplit: ti le cac o = %@", [txt componentsJoinedByString:@" / "]);
    if ([self paneCount] != 2) return;
    CGFloat r = [self fractionAt:0];
    [SCPPrefs setSplitRatio:r];
    NSString *l = self.slots[0].bundleID, *rb = self.slots[1].bundleID;
    if (l && rb) [SCPPrefs setRatio:r forPairLeft:l right:rb];
}

- (void)dividerTapped:(UITapGestureRecognizer *)g
{
    SCPCarDividerView *d = (SCPCarDividerView *)g.view;
    CGPoint p = [g locationInView:d];
    if (!CGRectContainsPoint(CGRectInset(d.knob.frame, -14, -14), p)) return;
    if (self.menu && self.menuDivider == d.index) [self hideMenu]; else [self showMenuForDivider:d.index];
}

// Icon cho ti le ke tiep khi bam nut ti le (50 -> 70 -> 30 -> 50)
// Ti le ke tiep cua nut ti le: 2 o 50 -> 70 -> 30 -> 50; 3 o deu -> giua to (25/50/25) -> deu
- (NSArray<NSNumber *> *)nextFractions
{
    int n = [self paneCount];
    if ([self mainStack]) {   // o lon 50 -> 60 -> 40 -> 50, 2 o nho giu ti le
        CGFloat r = [self fractionAt:0];
        CGFloat next = fabs(r - 0.5) < 0.05 ? 0.6 : (r > 0.55 ? 0.4 : 0.5);
        return @[@(next), @([self fractionAt:1])];
    }
    if (n == 2) {
        CGFloat r = [self fractionAt:0];
        CGFloat next = fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5);
        return @[@(next), @(1 - next)];
    }
    BOOL equal = YES;
    for (int i = 0; i < n; i++) if (fabs([self fractionAt:i] - 1.0 / n) > 0.03) equal = NO;
    if (n == 3 && equal) return @[@0.25, @0.5, @0.25];
    NSMutableArray *eq = [NSMutableArray array];
    for (int i = 0; i < n; i++) [eq addObject:@(1.0 / MAX(1, n))];
    return eq;
}

- (UIImage *)nextRatioGlyph
{
    NSArray<NSNumber *> *next = [self nextFractions];
    if ([self mainStack]) next = @[next[0], @(1 - next[0].doubleValue)];   // icon: be rong o lon / phan con lai
    return SCPCBoxesGlyph(next, [self vertical], 20);
}

- (void)showMenuForDivider:(int)index
{
    [self hideMenu];
    if (index < 0 || index >= (int)self.dividers.count) return;
    self.menuDivider = index;
    for (SCPCarPane *p in self.slots) [self setBarVisible:NO forPane:p];
    BOOL v = [self dividerRunsHorizontally:index];
    NSMutableArray *btns = [NSMutableArray arrayWithObjects:
                            SCPCRoundButton(SCPCGlyph(@"swap", 20, v), self, @selector(menuSwap)),
                            SCPCRoundButton([self nextRatioGlyph], self, @selector(menuRatio)), nil];
    [btns addObject:SCPCRoundButton(SCPCGlyph(@"close", 20, NO), self, @selector(menuClose))];
    // Chia trai/phai -> thanh doc theo duong ranh; chia tren/duoi -> thanh ngang
    UIView *m = SCPCPill(btns, !v);
    CGFloat len = v ? m.bounds.size.width : m.bounds.size.height;
    // Hang nut nam doc theo vach: vach doc -> ngay tren num; vach ngang -> ben phai num (num o 1/4 ben trai)
    SCPCarDividerView *dv = self.dividers[index];
    CGPoint kc = [self.container convertPoint:dv.knob.center fromView:dv];
    CGFloat maxX = self.container.bounds.size.width - len / 2 - 8;
    CGSize ks = dv.knob.bounds.size;
    if (!v) m.center = CGPointMake(kc.x, MAX(len / 2 + 8, kc.y - ks.height / 2 - 8 - len / 2));
    else    m.center = CGPointMake(MIN(maxX, kc.x + ks.width / 2 + 8 + len / 2), kc.y);
    self.menu = m;
    [self.container addSubview:m];
    SCPCDropIn(m);
    __weak SCPCarSplit *weakSelf = self;
    self.menuTimer = [NSTimer scheduledTimerWithTimeInterval:3.5 repeats:NO block:^(NSTimer *t) { [weakSelf hideMenu]; }];
}

- (void)hideMenu
{
    [self.menuTimer invalidate]; self.menuTimer = nil;
    UIView *m = self.menu;
    self.menu = nil;
    if (!m) return;
    [UIView animateWithDuration:0.15 animations:^{ m.alpha = 0; } completion:^(BOOL f) { [m removeFromSuperview]; }];
}

- (void)menuSwap
{
    int i = self.menuDivider;
    [self hideMenu];
    [self swapSlot:i with:i + 1];
}

- (void)menuRatio
{
    [self hideMenu];
    self.fractions = [[self nextFractions] mutableCopy];
    self.fullscreenSlot = -1;
    [self relayoutAnimated:YES];
    [self saveRatio];
}

- (void)menuClose { [self hideMenu]; [self closeGoingHome:YES]; }


// ---------------------------------------------------------------------
//  Bang chon app CarPlay (nam trong 1 ngan)
// ---------------------------------------------------------------------
- (void)removePickerFromPane:(SCPCarPane *)p
{
    if (!p.picker) return;
    UIView *pv = p.picker;
    p.picker = nil;
    [UIView animateWithDuration:0.15 animations:^{ pv.alpha = 0; } completion:^(BOOL f) { [pv removeFromSuperview]; }];
}

- (void)showPickerForSlot:(int)slot
{
    if (![self activate]) return;
    if (slot < 0 || slot >= [self paneCount]) slot = [self autoSlot];
    SCPCarPane *p = self.slots[slot];
    [self removePickerFromPane:p];
    [self hideMenu];
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;

    UIView *pv = [[UIView alloc] init];
    p.picker = pv;                     // dat truoc de bo cuc tinh ca ngan nay
    CGSize size = [self frameForSlot:slot].size;
    pv.frame = CGRectMake(0, 0, size.width, size.height);
    pv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];
    pv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, size.width - 64, 26)];
    title.text = @"Chọn app CarPlay";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    title.adjustsFontSizeToFitWidth = YES;
    [pv addSubview:title];

    UIButton *cancel = SCPCCircleButton(SCPCGlyph(@"close", 16, NO), 30, self, @selector(pickerCancel:));
    cancel.tag = slot;
    cancel.center = CGPointMake(size.width - 24, 23);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [pv addSubview:cancel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, size.width, size.height - 44)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [pv addSubview:scroll];

    NSArray *apps = SCPCCarPlayApps();
    NSMutableSet *inUse = [NSMutableSet set];
    for (SCPCarPane *o in self.slots) if (o.bundleID) [inUse addObject:o.bundleID];
    CGFloat cellW = 76, cellH = 82, icon = 46;
    NSInteger cols = MAX(1, (NSInteger)(size.width / cellW));
    CGFloat padX = (size.width - cols * cellW) / 2;
    NSInteger i = 0;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSDictionary *app in apps) {
        NSInteger row = i / cols, col = i % cols;
        UIButton *b = [SCPCButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(padX + col * cellW, 4 + row * cellH, cellW, cellH);
        b.accessibilityIdentifier = app[@"id"];
        b.tag = slot;
        [b addTarget:self action:@selector(pickerAppTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - icon) / 2, 4, icon, icon)];
        iv.image = SCPCAppIcon(app[@"id"]);
        SCPCStyleIcon(iv);
        iv.userInteractionEnabled = NO;
        iv.alpha = [inUse containsObject:app[@"id"]] ? 0.4 : 1;
        [b addSubview:iv];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, icon + 7, cellW - 4, 26)];
        l.text = app[@"name"];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.userInteractionEnabled = NO;
        [b addSubview:l];
        [scroll addSubview:b];
        if (i < cols * 2) [cells addObject:b];
        i++;
    }
    scroll.contentSize = CGSizeMake(size.width, 12 + ((i + cols - 1) / cols) * cellH);
    if (i == 0) title.text = @"Không tìm thấy app CarPlay";

    [p.view addSubview:pv];
    [p.view bringSubviewToFront:p.handle];
    [self relayoutAnimated:YES];
    pv.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ pv.alpha = 1; }];
    SCPCPopIn(cells);
    SCPLog("CarSplit: bang chon %ld app CarPlay cho ngan %d", (long)i, slot);
}

- (void)pickerAppTapped:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    NSString *bid = b.accessibilityIdentifier;
    SCPLog("CarSplit: chon %@ cho o %d", bid, p.slot);
    [self openApp:bid slot:p.slot];
}

// Huy bang chon: o con app -> quay lai app; o trong -> bo o do (3 -> 2 o; con 1 app -> ve toan man)
- (void)pickerCancel:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self removePickerFromPane:p];
    if (p.vc || [self slotOccupied:p.slot]) { [self relayoutAnimated:YES]; return; }
    [self removePaneAt:p.slot background:NO];
    [self afterPaneRemoved:nil];
}

// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
//  Bang cua nut CarDuo tren dock: Mac dinh (2 o / 3 o / 1 lon + 2), Gan day, Yeu thich.
//  Dang mo app toan man: chon bo cuc mac dinh -> app do vao o 1, cac o con lai hien bang chon app.
// ---------------------------------------------------------------------
#define SCPC_LAYOUT_W   76.0    // 1 o trong bang bo cuc
#define SCPC_TRAY_IDLE  8.0     // giay khong cham -> thu bang bo cuc

- (UIView *)tabParent
{
    UIViewController *root = SCPCRootVC();
    UIView *base = objcInvoke(root, @"baseContainerView");
    return base.superview ?: root.view;
}

// App CarPlay dang mo toan man (co the dua vao ngan), nil neu dang o man chinh / app khong ho tro
- (NSString *)fullscreenAppBundle
{
    UIViewController *cur = objcInvoke(SCPCRootVC(), @"currentBaseViewController");
    if (!cur || ![self isAdoptableViewController:cur]) return nil;
    return SCPRealBundleForInfos(objcInvoke(cur, @"applicationInfo"), objcInvoke(cur, @"proxyApplicationInfo"));
}

// Dat view tren app/home nhung duoi Siri (stackedContainerView)
- (BOOL)viewIsRaised:(UIView *)v
{
    UIView *parent = v.superview;
    if (!parent) return NO;
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    NSArray *subs = parent.subviews;
    if (stacked.superview != parent) return subs.lastObject == v;
    NSUInteger i = [subs indexOfObjectIdenticalTo:v], si = [subs indexOfObjectIdenticalTo:stacked];
    return i != NSNotFound && i + 1 == si;
}

- (void)raiseView:(UIView *)v
{
    UIView *parent = v.superview;
    if (!parent || [self viewIsRaised:v]) return;   // da dung cho -> khong dong vao (tranh layout lai)
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    if (stacked.superview == parent) [parent insertSubview:v belowSubview:stacked];
    else [parent bringSubviewToFront:v];
}

- (void)refreshAppTabSoon
{
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refreshAppTab];
    });
}

// Goi khi DashBoard layout / mo / dong app: cap nhat nut CarDuo tren dock (khong con the logo tren app,
// nut dock lam het viec do). Bang dang mo thi giu no tren cung.
- (void)refreshAppTab
{
    [self refreshHomeButton];
    if (self.tray && ![self viewIsRaised:self.tray]) { [self raiseView:self.trayShield]; [self raiseView:self.tray]; }
}

- (void)removeAppTab
{
    [self collapseAppTray];
}

// Bang bo cuc o giua mep tren vung app. app = app vao o 1 (app dang mo / icon vua giu);
// nil = mo tu man chinh -> mo lai cap app lan truoc theo bo cuc chon.
// Cac lua chon cua bang. layout: 2 / 3 / 13. apps = nil: bo cuc mac dinh (app dang mo vao o 1);
// apps != nil: mo dung cac app do (NSNull = o trong, hien bang chon).
- (NSArray<NSArray<NSDictionary *> *> *)panelSections:(NSArray<NSString *> **)titles
{
    NSMutableArray *sections = [NSMutableArray array], *names = [NSMutableArray array];
    [sections addObject:@[@{@"layout": @2, @"name": @"2 ô"}, @{@"layout": @3, @"name": @"3 ô"},
                          @{@"layout": @(SCPC_LAYOUT_MAIN_STACK), @"name": @"1 lớn + 2"}]];
    [names addObject:@"Mặc định"];

    NSMutableArray *recent = [NSMutableArray array];
    for (NSDictionary *r in ([SCPPrefs showRecent] ? [SCPPrefs recentLayouts] : @[])) {
        NSArray *apps = r[@"apps"];
        BOOL ok = apps.count >= 2;
        NSMutableArray *short_ = [NSMutableArray array];
        for (NSString *bid in apps) {
            if (![bid isKindOfClass:[NSString class]] || ![self isCarPlayApp:bid]) { ok = NO; break; }
            [short_ addObject:[self displayNameFor:bid]];
        }
        if (ok) [recent addObject:@{@"layout": r[@"layout"], @"apps": apps, @"name": [short_ componentsJoinedByString:@" + "]}];
    }
    if ([SCPPrefs showRecent]) {   // bat trong Cai dat -> luon hien (trong -> dong goi y)
        [sections addObject:recent];
        [names addObject:@"Gần đây"];
    }

    NSMutableArray *favs = [NSMutableArray array];
    NSInteger favCount = [SCPPrefs showFavorites] ? 3 : 0;   // tat trong Cai dat -> khong hien muc Yeu thich
    for (NSInteger i = 1; i <= favCount; i++) {
        NSDictionary *f = [SCPPrefs favorite:i];
        NSArray *apps = [self favoriteApps:f];
        if (!apps) continue;
        [favs addObject:@{@"layout": f[@"layout"] ?: @2, @"apps": apps, @"name": f[@"name"] ?: @""}];
    }
    if (favs.count) { [sections addObject:favs]; [names addObject:@"Yêu thích"]; }
    if (titles) *titles = names;
    return sections;
}

// Bang cua nut CarDuo / logo: Mac dinh (2 o / 3 o / 1 lon + 2), Gan day, Yeu thich. app = app vao o 1 khi
// chon bo cuc mac dinh (app dang mo / icon vua giu); nil = tu man chinh -> cap app lan truoc.
- (void)showLayoutPanelForApp:(NSString *)app
{
    [self collapseAppTray];
    UIView *parent = [self tabParent];
    if (!parent || ![SCPPrefs enabled]) return;
    self.layoutApp = app;
    CGRect area = [self appAreaInParent:parent];

    // Lop phu: cham ra ngoai bang -> thu lai
    UIView *shield = [[UIView alloc] initWithFrame:parent.bounds];
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shield.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    [shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(collapseAppTray)]];
    [parent addSubview:shield];
    self.trayShield = shield;

    BOOL v = [self vertical];
    NSArray<NSString *> *titles = nil;
    NSArray<NSArray<NSDictionary *> *> *sections = [self panelSections:&titles];
    int current = self.active ? [self layoutID] : 0;
    CGFloat pad = 10, headH = 18, rowH = 50, imgW = 56, imgH = 28;
    NSUInteger cols = 0;
    for (NSArray *sec in sections) cols = MAX(cols, sec.count);
    CGFloat emptyH = 20, w = pad * 2 + cols * SCPC_LAYOUT_W, h = 6 + 4;
    for (NSArray *sec in sections) h += headH + (sec.count ? rowH : emptyH);
    h = MIN(h, area.size.height - 12);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMidX(area) - w / 2, CGRectGetMinY(area) + 6, w, h)];
    SCPCChrome(panel, 20);
    panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    panel.layer.shadowOpacity = 0.45; panel.layer.shadowRadius = 14; panel.layer.shadowOffset = CGSizeMake(0, 4);
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:panel.bounds];   // man xe thap: cuon duoc
    scroll.showsVerticalScrollIndicator = NO;
    scroll.layer.cornerRadius = 20; scroll.clipsToBounds = YES;
    [panel addSubview:scroll];

    NSMutableArray *choices = [NSMutableArray array], *cells = [NSMutableArray array];
    CGFloat y = 6;
    for (NSUInteger si = 0; si < sections.count; si++) {
        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, y, w - pad * 2 - 8, 14)];
        head.text = (si == 0 && self.active) ? @"Đổi bố cục" : titles[si];
        head.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        head.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [scroll addSubview:head];
        y += headH;
        NSArray<NSDictionary *> *items = sections[si];
        if (!items.count) {   // "Gan day" chua co gi
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, y, w - pad * 2 - 8, 14)];
            hint.text = @"Chia màn xong sẽ hiện ở đây";
            hint.textColor = [UIColor colorWithWhite:1 alpha:0.4];
            hint.font = [UIFont systemFontOfSize:11];
            [scroll addSubview:hint];
            y += emptyH;
            continue;
        }
        CGFloat x0 = pad + (cols - items.count) * SCPC_LAYOUT_W / 2;   // hang it muc -> can giua
        for (NSUInteger k = 0; k < items.count; k++) {
            NSDictionary *c = items[k];
            int layoutID = [c[@"layout"] intValue];
            UIButton *b = [SCPCButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(x0 + k * SCPC_LAYOUT_W, y, SCPC_LAYOUT_W, rowH);
            b.tag = (NSInteger)choices.count;
            [choices addObject:c];
            [b addTarget:self action:@selector(panelChoiceTapped:) forControlEvents:UIControlEventTouchUpInside];
            if (si == 0 && layoutID == current) {   // bo cuc dang dung
                b.backgroundColor = [SCPCAccent() colorWithAlphaComponent:0.22];
                b.layer.cornerRadius = 12;
            }
            UIImageView *iv = [[UIImageView alloc] initWithImage:SCPCLayoutImage(layoutID, v, CGSizeMake(imgW, imgH), c[@"apps"])];
            iv.center = CGPointMake(SCPC_LAYOUT_W / 2, 4 + imgH / 2);
            iv.userInteractionEnabled = NO;
            [b addSubview:iv];
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(3, imgH + 8, SCPC_LAYOUT_W - 6, 13)];
            l.text = c[@"name"];
            l.textColor = [UIColor colorWithWhite:1 alpha:0.85];
            l.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            l.textAlignment = NSTextAlignmentCenter;
            l.lineBreakMode = NSLineBreakByTruncatingTail;
            l.userInteractionEnabled = NO;
            [b addSubview:l];
            [scroll addSubview:b];
            [cells addObject:b];
        }
        y += rowH;
    }
    scroll.contentSize = CGSizeMake(w, y + 4);
    self.panelChoices = choices;

    [parent addSubview:panel];
    self.tray = panel;
    [self raiseView:shield];
    [self raiseView:panel];
    shield.alpha = 0;
    panel.alpha = 0; panel.transform = CGAffineTransformMakeTranslation(0, -h);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0
                     animations:^{ shield.alpha = 1; panel.alpha = 1; panel.transform = CGAffineTransformIdentity; } completion:nil];
    SCPCPopIn(cells);
    [self restartTrayTimer];
    SCPLog("CarSplit: bang bo cuc cho %@ (%@, %lu lua chon)", app ?: (self.active ? @"doi bo cuc" : @"cap lan truoc"),
           [titles componentsJoinedByString:@" / "], (unsigned long)choices.count);
}

- (void)panelChoiceTapped:(UIButton *)b
{
    NSDictionary *c = (b.tag >= 0 && b.tag < (NSInteger)self.panelChoices.count) ? self.panelChoices[b.tag] : nil;
    if (!c) return;
    int layoutID = [c[@"layout"] intValue];
    NSArray *apps = c[@"apps"];
    if (!apps) { [self layoutChosenID:layoutID]; return; }
    NSString *app = self.layoutApp;
    self.layoutApp = nil;
    [self collapseAppTray];
    SCPLog("CarSplit: mo lai %@ (bo cuc %d, app %@, thay cho %@)", c[@"name"], layoutID, apps, app ?: @"-");
    [self openSetupLayout:layoutID apps:apps];
}

// App theo tung o cua 1 bo cuc yeu thich (NSNull = o trong / app khong con tren CarPlay), nil neu khong co app nao
- (NSArray *)favoriteApps:(NSDictionary *)f
{
    if (!f) return nil;
    int layoutID = [f[@"layout"] intValue];
    int n = (layoutID == SCPC_LAYOUT_MAIN_STACK) ? 3 : MAX(2, MIN(SCPC_MAX_PANES, layoutID));
    NSArray *keys = @[@"left", @"right", @"third"];
    NSMutableArray *apps = [NSMutableArray array];
    BOOL any = NO;
    for (int i = 0; i < n; i++) {
        NSString *bid = f[keys[i]];
        if (bid && [self isCarPlayApp:bid]) { [apps addObject:bid]; any = YES; }
        else [apps addObject:[NSNull null]];
    }
    return any ? apps : nil;
}

// Siri / Shortcuts carduo://fav?n=1
- (void)openFavorite:(NSInteger)index
{
    NSDictionary *f = [SCPPrefs favorite:index];
    NSArray *apps = [self favoriteApps:f];
    SCPLog("CarSplit: bo cuc yeu thich %ld: %@", (long)index, f);
    if (apps) [self openSetupLayout:[f[@"layout"] intValue] apps:apps];
}

// Mo dung 1 cach chia (gan day / yeu thich). Dang chia -> doi bo cuc va thay app theo thu tu o.
- (void)openSetupLayout:(int)layoutID apps:(NSArray *)apps
{
    if (self.active) [self switchToLayout:layoutID];
    else {
        self.suppressReopen = YES;   // app dang toan man khong tu vao o 1, cac o lay dung app cua cach chia
        BOOL ok = [self activateWithLayout:layoutID];
        self.suppressReopen = NO;
        if (!ok) return;
    }
    if (layoutID == 2 && apps.count >= 2 && [apps[0] isKindOfClass:[NSString class]] && [apps[1] isKindOfClass:[NSString class]]) {
        CGFloat saved = [SCPPrefs ratioForPairLeft:apps[0] right:apps[1]];
        if (saved >= 0.2 && saved <= 0.8) self.fractions = [NSMutableArray arrayWithObjects:@(saved), @(1 - saved), nil];
    }
    [self openAppsInOrder:apps];
}

- (void)restartTrayTimer
{
    [self.trayTimer invalidate];
    __weak SCPCarSplit *weakSelf = self;
    self.trayTimer = [NSTimer scheduledTimerWithTimeInterval:SCPC_TRAY_IDLE repeats:NO block:^(NSTimer *t) { [weakSelf collapseAppTray]; }];
}

- (void)collapseAppTray
{
    [self.trayTimer invalidate]; self.trayTimer = nil;
    UIView *tray = self.tray, *shield = self.trayShield;
    self.tray = nil; self.trayShield = nil;
    if (!tray && !shield) return;
    [UIView animateWithDuration:0.2 animations:^{
        tray.alpha = 0; tray.transform = CGAffineTransformMakeTranslation(0, -20); shield.alpha = 0;
    } completion:^(BOOL f) { [tray removeFromSuperview]; [shield removeFromSuperview]; }];
}

// Chon bo cuc: app vao o 1, o 2 hien bang chon app (tu man chinh: cap app lan truoc)
// Chon so o: app vao o 1, cac o con lai hien bang chon app (tu man chinh: cap app lan truoc)
// Chon bo cuc. Dang chia -> doi bo cuc. Chua chia -> app vao o 1, cac o con lai hien bang chon
// (tu man chinh: cap app lan truoc)
// Chon bo cuc mac dinh. Dang chia -> doi bo cuc. Chua chia -> app vao o 1, cac o con lai hien bang chon
// (tu man chinh: cap app lan truoc)
- (void)layoutChosenID:(int)layoutID
{
    NSString *app = self.layoutApp;
    self.layoutApp = nil;
    [self collapseAppTray];
    if (self.active) { [self switchToLayout:layoutID]; return; }
    SCPLog("CarSplit: chon bo cuc %d cho %@", layoutID, app ?: @"cap lan truoc");
    if (!app) { [self openRememberedPairWithLayout:layoutID]; return; }
    if (![self activateWithLayout:layoutID]) return;   // app dang mo toan man: activate tu mo lai no vao o 1
    [self openApp:app slot:0];
    for (int s = 1; s < [self paneCount]; s++) if (![self slotOccupied:s]) [self showPickerForSlot:s];
}

// ---------------------------------------------------------------------
//  CarBridge (YouTube, TikTok... app iPhone tren CarPlay): DashBoard chi tao scene rong (ngan trang),
//  CarBridge tu ve app bang cua so rieng CBWindow (SpringBoard) khi duoc kich hoat tu cham icon.
//  App CarBridge vao ngan -> goi CBBridgeManagerDashboard startBridging:, khung chieu = khung ngan
//  (hook getAppFrame + bao SpringBoard dat lai CBWindow moi khi ngan doi).
// ---------------------------------------------------------------------
#define SCPC_BRIDGE_TOP   16.0    // chua mep tren ngan (thanh "...") khong bi CBWindow che

static id SCPCBridgeManager(void)
{
    Class c = objc_getClass("CBBridgeManagerDashboard");
    return (c && [c respondsToSelector:@selector(sharedInstance)]) ? objcInvoke(c, @"sharedInstance") : nil;
}

static BOOL SCPCIsBridgedApp(NSString *bid)
{
    Class c = objc_getClass("CBBridgeManagerDashboard");
    SEL s = NSSelectorFromString(@"isBridgedApp:");
    if (!c || !bid || ![c respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(c, s, bid);
}

- (SCPCarPane *)bridgedPane
{
    if (!self.bridgedBundle) return nil;
    for (SCPCarPane *p in self.slots) if ([p.bundleID isEqualToString:self.bridgedBundle]) return p;
    return nil;
}

// Khung CBWindow (toa do man xe) cho app CarBridge dang o trong ngan; CGRectZero neu ngan dang an
- (CGRect)bridgeFrame
{
    SCPCarPane *p = [self bridgedPane];
    if (!self.active || !p || p.view.alpha < 0.5 || p.view.bounds.size.width < 20 || !p.view.window) return CGRectZero;
    // Thanh nut cua ngan dang hien -> day khung chieu xuong duoi thanh nut de bam duoc
    CGFloat top = p.bar.hidden ? SCPC_BRIDGE_TOP : SCPC_HANDLE_H + 10 + SCPC_BTN + 6;
    CGRect b = p.view.bounds;
    CGRect r = CGRectMake(0, top, b.size.width, MAX(0, b.size.height - top));
    return [p.view convertRect:r toView:nil];
}

// Ngan dang chua app CarBridge nhung CarBridge dang chieu app khac (chi chieu duoc 1 app) -> ngan trang
- (BOOL)bridgeWaitingInPane:(SCPCarPane *)p
{
    return self.active && p.vc && p.bundleID && !p.picker && !self.bridgeStarting
        && SCPCIsBridgedApp(p.bundleID) && ![p.bundleID isEqualToString:self.bridgedBundle];
}

- (void)updateBridgeHints
{
    for (SCPCarPane *p in self.slots) {
        BOOL waiting = [self bridgeWaitingInPane:p];
        if (waiting && !p.bridgeHint) {
            UILabel *l = [[UILabel alloc] init];
            l.textColor = [UIColor whiteColor];
            l.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.92];   // ngan CarBridge trang -> nhan nen toi
            l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            l.textAlignment = NSTextAlignmentCenter;
            l.layer.cornerRadius = 17;
            l.clipsToBounds = YES;
            l.userInteractionEnabled = NO;
            p.bridgeHint = l;
        }
        if (!p.bridgeHint) continue;
        p.bridgeHint.text = waiting ? [NSString stringWithFormat:@"Chạm để hiện %@", [self displayNameFor:p.bundleID]] : nil;
        p.bridgeHint.hidden = !waiting;
        [p.bridgeHint sizeToFit];
        CGFloat w = MIN(p.bridgeHint.bounds.size.width + 32, p.view.bounds.size.width - 16);
        p.bridgeHint.bounds = CGRectMake(0, 0, MAX(0, w), 34);
        p.bridgeHint.center = CGPointMake(CGRectGetMidX(p.view.bounds), CGRectGetMidY(p.view.bounds));
        if (p.bridgeHint.superview != p.view) [p.view addSubview:p.bridgeHint];
        [p.view bringSubviewToFront:p.bridgeHint];
        [p.view bringSubviewToFront:p.handle];
        [p.view bringSubviewToFront:p.bar];
    }
}

// SpringBoard bao CBWindow da mat (CarBridge dong khi app khac mo...) -> chieu lai, toi da 1 lan / 5s
- (void)bridgeWindowLost:(NSString *)bid
{
    SCPCarPane *p = [self paneForBundle:bid];
    if (!self.active || !p || self.bridgeStarting || ![bid isEqualToString:self.bridgedBundle]) return;
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 5) return;
    last = now;
    SCPLog("CarBridge: CBWindow cua %@ mat -> chieu lai", bid);
    self.bridgedBundle = nil;   // de startBridgeForPane khong bao "thay app"
    [self startBridgeForPane:p];
}

- (void)startBridgeForPane:(SCPCarPane *)p
{
    id mgr = SCPCBridgeManager();
    if (!mgr || !p.bundleID) return;
    if (self.bridgedBundle && ![self.bridgedBundle isEqualToString:p.bundleID]) {
        SCPLog("CarBridge: chi chieu duoc 1 app, thay %@ bang %@", self.bridgedBundle, p.bundleID);
    }
    self.bridgedBundle = p.bundleID;
    self.lastBridgeFrame = CGRectNull;
    self.bridgeStarting = YES;
    [self updateBridgeHints];
    SCPLog("CarBridge: chieu %@ vao ngan %d, khung %@", p.bundleID, p.slot, NSStringFromCGRect([self bridgeFrame]));
    NSString *bid = p.bundleID;
    __weak SCPCarSplit *weakSelf = self;
    @try {
        void (^done)(void) = ^{
            SCPLog("CarBridge: da chieu %@", bid);
            [weakSelf pushBridgeFrame];
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, NSSelectorFromString(@"startBridging:withCompletion:"), bid, done);
    } @catch (NSException *e) { SCPLog("CarBridge: startBridging loi %@", e); }
    // Cho CarBridge tao xong CBWindow roi dat khung (vai lan cho chac), het giai doan khoi dong sau 4s
    for (NSNumber *d in @[@1.0, @2.5, @4.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPCarSplit *me = weakSelf;
            if (d.doubleValue >= 4.0) { me.bridgeStarting = NO; [me updateBridgeHints]; }
            [me pushBridgeFrame];
        });
    }
}

- (void)stopBridge
{
    if (!self.bridgedBundle) return;
    SCPLog("CarBridge: dung chieu %@", self.bridgedBundle);
    self.bridgedBundle = nil;
    self.bridgeStarting = NO;
    @try { objcCall(SCPCBridgeManager(), @"stopBridging"); } @catch (NSException *e) { SCPLog("CarBridge: stopBridging loi %@", e); }
    [self updateBridgeHints];
}

// Bao SpringBoard dat CBWindow dung khung ngan (CBWindow nam trong SpringBoard)
- (void)pushBridgeFrame
{
    if (!self.bridgedBundle) return;
    if (!self.active || ![self bridgedPane]) { [self stopBridge]; return; }
    CGRect r = [self bridgeFrame];
    if (CGRectEqualToRect(r, self.lastBridgeFrame)) return;
    self.lastBridgeFrame = r;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_CBFRAME object:nil
                    userInfo:@{@"identifier": self.bridgedBundle, @"x": @(r.origin.x), @"y": @(r.origin.y),
                               @"w": @(r.size.width), @"h": @(r.size.height)}];
}

- (void)pushBridgeFrameSoon
{
    if (!self.bridgedBundle) return;
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pushBridgeFrame];
    });
}

// ---------------------------------------------------------------------
//  Chua split: nut CarDuo tren dock CarPlay (tren nut Home) mo bang bo cuc; giu icon app 0.7s tren man
//  chinh cung vay. Tu mo split khi cam xe.
// ---------------------------------------------------------------------
#define SCPC_HOME_BTN 34.0
#define SCPC_DOCK_BTN 30.0    // nut CarDuo khi nam tren dock CarPlay
#define SCPC_DOCK_TOP 36.0    // dong ho + song / 4G o dau dai dock: khong day cum icon dock len qua day
static char kSCPCLongPressKey;

// Logo CarDuo (art/AppIcon.svg, khung 1024): 2 o xanh CarPlay vien trang, mui ten dan duong + song am
static UIImage *SCPCLogoImage(CGFloat side)
{
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef ctx = rc.CGContext;
        CGFloat s = side / 1024.0;
        CGContextScaleCTM(ctx, s, s);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        void (^pane)(CGRect, CGFloat, UIColor *, UIColor *) = ^(CGRect f, CGFloat rad, UIColor *c0, UIColor *c1) {
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:f cornerRadius:rad];
            CGContextSaveGState(ctx);
            [p addClip];
            NSArray *cols = @[(id)c0.CGColor, (id)c1.CGColor];
            CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
            CGContextDrawLinearGradient(ctx, g, f.origin, CGPointMake(CGRectGetMaxX(f), CGRectGetMaxY(f)), 0);
            CGGradientRelease(g);
            NSArray *sheen = @[(id)[UIColor colorWithWhite:1 alpha:0.18].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
            CGFloat locs[2] = {0, 0.45};
            g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)sheen, locs);
            CGContextDrawLinearGradient(ctx, g, f.origin, CGPointMake(f.origin.x, CGRectGetMaxY(f)), 0);
            CGGradientRelease(g);
            CGContextRestoreGState(ctx);
        };
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, 12 * s), 16 * s,   // bong khong theo CTM -> tu nhan ti le
        [UIColor colorWithRed:0.02 green:0.25 blue:0.10 alpha:0.3].CGColor);
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(82, 186, 532, 652) cornerRadius:132] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(634, 186, 308, 652) cornerRadius:118] fill];
        CGContextRestoreGState(ctx);
        pane(CGRectMake(96, 200, 504, 624), 118, [UIColor colorWithRed:0x5E/255.0 green:0xE8/255.0 blue:0x6A/255.0 alpha:1],
             [UIColor colorWithRed:0x0F/255.0 green:0xB5/255.0 blue:0x1E/255.0 alpha:1]);
        pane(CGRectMake(648, 200, 280, 624), 104, [UIColor colorWithRed:0x2C/255.0 green:0xC8/255.0 blue:0x52/255.0 alpha:1],
             [UIColor colorWithRed:0x06/255.0 green:0x86/255.0 blue:0x2E/255.0 alpha:1]);
        CGColorSpaceRelease(cs);
        [[UIColor whiteColor] setFill];
        UIBezierPath *arrow = [UIBezierPath bezierPath];
        [arrow moveToPoint:CGPointMake(348, 370)];
        [arrow addLineToPoint:CGPointMake(441, 637)];
        [arrow addLineToPoint:CGPointMake(348, 583)];
        [arrow addLineToPoint:CGPointMake(255, 637)];
        [arrow closePath];
        [arrow fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(695, 447, 46, 130) cornerRadius:23] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(765, 387, 46, 250) cornerRadius:23] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(835, 427, 46, 170) cornerRadius:23] fill];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (BOOL)atHomeScreen
{
    UIViewController *root = SCPCRootVC();
    return root && !self.active && [SCPPrefs enabled] && !objcInvoke(root, @"currentBaseViewController");
}

// Khung cum icon cua dock CarPlay (appDockViewController) trong toa do parent, Null neu khong thay
- (CGRect)dockClusterInParent:(UIView *)parent
{
    UIView *dock = nil;
    @try { id dockVC = objcInvoke(SCPCRootVC(), @"appDockViewController"); dock = dockVC ? objcInvoke(dockVC, @"view") : nil; } @catch (NSException *e) {}
    if (!dock.window || dock.hidden || !parent.window) return CGRectNull;
    UIScreen *screen = parent.window.screen ?: dock.window.screen;
    if (!screen) return CGRectNull;
    CGRect inScreen = [dock convertRect:dock.bounds toCoordinateSpace:screen.coordinateSpace];
    inScreen.origin.y -= dock.transform.ty;   // vi tri goc, chua tinh phan nut CarDuo da day cum icon len
    return [parent convertRect:inScreen fromCoordinateSpace:screen.coordinateSpace];
}

// Tim nut Home cua dock: view co ten lop chua "Home", nho (20..70pt), nam trong dai dock
static void SCPCFindHomeButton(UIView *v, UIView *parent, CGRect strip, int depth, UIView *skip, CGRect *best)
{
    if (!v || depth > 14 || v == skip || v.hidden || v.alpha < 0.05) return;
    NSString *cls = NSStringFromClass([v class]);
    if ([cls rangeOfString:@"Home" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        CGRect r = [parent convertRect:v.bounds fromView:v];
        if (r.size.width >= 20 && r.size.width <= 70 && r.size.height >= 20 && r.size.height <= 70
            && CGRectContainsPoint(CGRectInset(strip, -4, -4), CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) {
            if (CGRectIsNull(*best) || CGRectGetMinY(r) > CGRectGetMinY(*best)) *best = r;   // lay nut thap nhat
        }
    }
    for (UIView *c in v.subviews) SCPCFindHomeButton(c, parent, strip, depth + 1, skip, best);
}

// Vi tri nut CarDuo: tren dock CarPlay (dai trai / phai), ngay duoi cum icon dock va tren nut Home. Khe khong du
// thi day cum icon len (toi da toi duoi dong ho / song) cho vua; van khong du thi goc tren phai vung app.
// *outShift = so pt can day cum icon dock len. Ghi log moi lan doi cho.
- (CGPoint)launcherCenterInParent:(UIView *)parent size:(CGFloat *)outSize shift:(CGFloat *)outShift
{
    UIViewController *root = SCPCRootVC();
    UIView *content = objcInvoke(root, @"contentView") ?: root.view;
    CGRect full = [parent convertRect:content.bounds fromView:content];
    CGRect area = [self appAreaInParent:parent];
    CGFloat leftW = CGRectGetMinX(area) - CGRectGetMinX(full), rightW = CGRectGetMaxX(full) - CGRectGetMaxX(area);
    CGRect strip = CGRectNull;
    if (leftW >= 30) strip = CGRectMake(CGRectGetMinX(full), CGRectGetMinY(full), leftW, full.size.height);
    else if (rightW >= 30) strip = CGRectMake(CGRectGetMaxX(area), CGRectGetMinY(full), rightW, full.size.height);

    CGFloat size = SCPC_HOME_BTN, shift = 0;
    CGPoint c = CGPointMake(CGRectGetMaxX(area) - size / 2 - 8, CGRectGetMinY(area) + size / 2 + 8);
    NSString *where = @"goc tren phai vung app (khong co dock doc)";
    CGRect cluster = CGRectNull, home = CGRectNull;
    if (!CGRectIsNull(strip)) {
        size = MIN(SCPC_DOCK_BTN, strip.size.width - 8);
        CGFloat cx = CGRectGetMidX(strip);
        cluster = CGRectIntersection([self dockClusterInParent:parent], strip);
        SCPCFindHomeButton(root.view, parent, strip, 0, self.homeButton, &home);
        CGFloat clusterBottom = CGRectIsNull(cluster) ? CGRectGetMinY(strip) + SCPC_DOCK_TOP : CGRectGetMaxY(cluster);
        CGFloat clusterTop = CGRectIsNull(cluster) ? clusterBottom : CGRectGetMinY(cluster);
        // Nut Home (luoi app) nam cuoi dai dock; khong tim thay thi coi o day dai dock cao bang be ngang dai
        CGFloat homeTop = !CGRectIsNull(home) && CGRectGetMinY(home) > clusterBottom ? CGRectGetMinY(home)
                                                                                    : CGRectGetMaxY(strip) - strip.size.width;
        CGFloat need = clusterBottom + 4 + size + 4 - homeTop;                 // pt con thieu de nhet nut vao khe
        CGFloat room = clusterTop - (CGRectGetMinY(strip) + SCPC_DOCK_TOP);   // pt co the day cum icon len
        if (need <= 0 || need <= room) {
            shift = CGRectIsNull(cluster) ? 0 : MAX(0, need);
            c = CGPointMake(cx, clusterBottom - shift + 4 + size / 2);
            where = shift > 0 ? @"duoi cum icon dock, tren nut Home (day cum icon len)" : @"duoi cum icon dock, tren nut Home";
        } else {
            size = SCPC_HOME_BTN;
            c = CGPointMake(CGRectGetMaxX(area) - size / 2 - 8, CGRectGetMinY(area) + size / 2 + 8);
            where = @"goc tren phai vung app (dock khong con cho)";
        }
    }
    if (![where isEqualToString:self.launcherWhere]) {
        self.launcherWhere = where;
        SCPLog("CarSplit: nut CarDuo dat %@ | dai dock=%@ cum icon=%@ nut Home=%@ day len %.1f", where,
               NSStringFromCGRect(strip), NSStringFromCGRect(cluster), NSStringFromCGRect(home), shift);
    }
    if (outSize) *outSize = size;
    if (outShift) *outShift = shift;
    return c;
}

// Nut CarDuo tren dock CarPlay: luon hien (man chinh, app toan man, dang chia -> doi bo cuc)
- (void)refreshHomeButton
{
    UIViewController *root = SCPCRootVC();
    BOOL show = root && [SCPPrefs enabled];
    UIView *parent = show ? [self tabParent] : nil;
    if (!parent) { [self removeHomeButton]; return; }
    // Ham nay chay moi lan DashBoard layout -> do dock (quet cay view tim nut Home) toi da 1 lan / giay
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.homeButton.superview && self.homeButton.superview == self.launcherHost && now - self.lastLauncherCalc < 1.0) {
        [self raiseLauncher];
        return;
    }
    self.lastLauncherCalc = now;
    CGFloat size = SCPC_HOME_BTN, shift = 0;
    CGPoint c = [self launcherCenterInParent:parent size:&size shift:&shift];
    [self setDockShift:shift];
    if (!self.homeButton || fabs(self.homeButton.bounds.size.width - size) > 0.5) {
        [self.homeButton removeFromSuperview];
        UIButton *b = SCPCRoundButton(SCPCLogoImage(size), self, @selector(homeButtonTapped));
        b.bounds = CGRectMake(0, 0, size, size);
        b.layer.cornerRadius = 0;
        b.backgroundColor = nil;
        self.homeButton = b;
    }
    // Nut nam tren dai dock: gan vao chinh view ve dai dock (status bar CarPlay nam tren baseContainerView,
    // gan vao tabParent thi nut bi dai dock che mat). Ngoai dock (goc vung app) thi van gan vao tabParent.
    CGRect r = CGRectMake(c.x - size / 2, c.y - size / 2, size, size);
    UIView *host = [self.launcherWhere hasPrefix:@"goc"] ? nil : [self dockHostForRect:r inParent:parent];
    if (!host) host = parent;
    if (self.homeButton.superview != host) {
        [host addSubview:self.homeButton];
        SCPLog("CarSplit: nut CarDuo gan vao %@ %@", NSStringFromClass([host class]),
               host == parent ? @"(tabParent)" : NSStringFromCGRect([parent convertRect:host.bounds fromView:host]));
    }
    self.launcherHost = host;
    self.homeButton.center = [host convertPoint:c fromView:parent];
    [self raiseLauncher];
    if ([self atHomeScreen]) [self installIconLongPress];
}

// Day cum icon dock CarPlay len dy pt (transform, DashBoard layout lai khong mat) de chua cho nut CarDuo
// ngay tren nut Home; dy = 0 tra ve cho cu
- (void)setDockShift:(CGFloat)dy
{
    UIView *dock = nil;
    @try { id dockVC = objcInvoke(SCPCRootVC(), @"appDockViewController"); dock = dockVC ? objcInvoke(dockVC, @"view") : nil; } @catch (NSException *e) {}
    if (!dock) return;
    CGAffineTransform t = dy > 0 ? CGAffineTransformMakeTranslation(0, -dy) : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(dock.transform, t)) dock.transform = t;
}

- (void)raiseLauncher
{
    UIView *host = self.homeButton.superview;
    if (!host) return;
    if (host == [self tabParent]) [self raiseView:self.homeButton];
    else if (host.subviews.lastObject != self.homeButton) [host bringSubviewToFront:self.homeButton];
}

static void SCPCDumpTree(UIView *v, UIView *root, int depth, NSMutableString *out)
{
    if (!v || depth > 7 || out.length > 6000) return;
    CGRect r = [root convertRect:v.bounds fromView:v];
    [out appendFormat:@"%@%@ %@%@%@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass([v class]), NSStringFromCGRect(r), v.hidden ? @" hidden" : @"",
        v.userInteractionEnabled ? @"" : @" noTouch"];
    for (UIView *c in v.subviews) SCPCDumpTree(c, root, depth + 1, out);
}

// View to nhat chua cum icon dock ma van nam gon trong dai dock va bao tron khung r (toa do parent).
// nil neu khong thay (dock chua layout / khac man hinh). Lan dau ghi cay view dai dock vao log.
- (UIView *)dockHostForRect:(CGRect)r inParent:(UIView *)parent
{
    UIView *dock = nil;
    @try { id dockVC = objcInvoke(SCPCRootVC(), @"appDockViewController"); dock = dockVC ? objcInvoke(dockVC, @"view") : nil; } @catch (NSException *e) {}
    if (!dock.window || !parent.window) return nil;
    UIScreen *screen = parent.window.screen ?: dock.window.screen;
    if (!screen) return nil;
    CGRect want = [parent convertRect:r toCoordinateSpace:screen.coordinateSpace];
    CGRect full = [parent convertRect:parent.bounds toCoordinateSpace:screen.coordinateSpace];
    UIView *best = nil;
    for (UIView *v = dock; v && ![v isKindOfClass:[UIWindow class]] && v != parent; v = v.superview) {
        CGRect mine = [v convertRect:v.bounds toCoordinateSpace:screen.coordinateSpace];
        if (mine.size.width > full.size.width * 0.5) break;   // da ra ngoai dai dock (view toan man hinh)
        if (CGRectContainsRect(CGRectInset(mine, -0.5, -0.5), want)) { best = v; break; }
    }
    if (!self.dockTreeLogged && dock.bounds.size.height < full.size.height * 0.9) {   // dock da layout xong
        self.dockTreeLogged = YES;
        UIView *top = dock;
        while (top.superview && ![top.superview isKindOfClass:[UIWindow class]] && top.superview != parent
               && [top.superview convertRect:top.superview.bounds toCoordinateSpace:screen.coordinateSpace].size.width <= full.size.width * 0.5)
            top = top.superview;
        NSMutableString *s = [NSMutableString string];
        SCPCDumpTree(top, top, 0, s);
        SCPLog("DIAG cay dai dock:\n%@", s);
    }
    return best;
}

- (void)removeHomeButton
{
    [self.homeButton removeFromSuperview];
    self.homeButton = nil;
    self.lastLauncherCalc = 0;
    [self setDockShift:0];
}

- (void)homeButtonTapped
{
    NSString *cur = self.active ? nil : [self fullscreenAppBundle];
    SCPLog("CarSplit: bam nut CarDuo tren dock (%@)", self.active ? @"dang chia -> doi bo cuc" : (cur ?: @"man chinh"));
    if (self.tray) [self collapseAppTray]; else [self showLayoutPanelForApp:cur];
}

// Cap dung lan cuoi (khong co thi cap trong Cai dat). App khong con tren CarPlay thi bo, o do hien bang chon.
// Tu mo khi cam xe: mo lai dung cach chia gan nhat (bo cuc + app); khong co thi Bo cuc yeu thich 1
- (void)openRememberedPair
{
    for (NSDictionary *r in [SCPPrefs recentLayouts]) {
        NSArray *apps = r[@"apps"];
        BOOL ok = apps.count >= 2;
        for (NSString *bid in apps) if (![bid isKindOfClass:[NSString class]] || ![self isCarPlayApp:bid]) ok = NO;
        if (!ok) continue;
        SCPLog("CarSplit: mo lai cach chia gan nhat %@", r);
        [self openSetupLayout:[r[@"layout"] intValue] apps:apps];
        return;
    }
    NSDictionary *f = [SCPPrefs favorite:1];
    NSArray *apps = [self favoriteApps:f];
    if (apps) { SCPLog("CarSplit: chua co cach chia gan day -> Bo cuc yeu thich 1"); [self openSetupLayout:[f[@"layout"] intValue] apps:apps]; }
    else SCPLog("CarSplit: chua co cach chia gan day / yeu thich -> khong tu mo");
}

// App de mo khi khong co app dang mo: cach chia gan nhat, khong co thi Bo cuc yeu thich 1 (NSNull = o trong)
- (NSArray *)rememberedApps
{
    for (NSDictionary *r in [SCPPrefs recentLayouts]) {
        NSMutableArray *apps = [NSMutableArray array];
        BOOL any = NO;
        for (NSString *bid in r[@"apps"]) {
            BOOL ok = [bid isKindOfClass:[NSString class]] && [self isCarPlayApp:bid];
            [apps addObject:ok ? bid : [NSNull null]];
            any = any || ok;
        }
        if (any) return apps;
    }
    return [self favoriteApps:[SCPPrefs favorite:1]] ?: @[];
}

- (void)openRememberedPairWithLayout:(int)layoutID
{
    NSArray *apps = [self rememberedApps];
    SCPLog("CarSplit: mo bo cuc %d voi app gan nhat %@", layoutID, apps);
    [self openSetupLayout:layoutID apps:apps];
}

// Gan cu chi giu lau vao luoi icon man chinh CarPlay (*IconListView), toi da 1 lan quet / 2s
- (void)installIconLongPress
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastIconScan < 2.0) return;
    self.lastIconScan = now;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) [self installLongPressIn:w depth:0];
    }
}

- (void)installLongPressIn:(UIView *)v depth:(int)depth
{
    if (!v || depth > 14 || v == self.container) return;
    if ([NSStringFromClass([v class]) hasSuffix:@"IconListView"]) {
        if (objc_getAssociatedObject(v, &kSCPCLongPressKey)) return;
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(iconLongPressed:)];
        g.minimumPressDuration = 0.7;
        [v addGestureRecognizer:g];
        objc_setAssociatedObject(v, &kSCPCLongPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SCPLog("CarSplit: gan giu icon vao %@", NSStringFromClass([v class]));
        return;
    }
    for (UIView *c in v.subviews) [self installLongPressIn:c depth:depth + 1];
}

- (void)iconLongPressed:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan || self.active || ![SCPPrefs enabled]) return;
    UIView *hit = [g.view hitTest:[g locationInView:g.view] withEvent:nil];
    NSString *bid = nil;
    for (UIView *v = hit; v && v != g.view.superview && !bid; v = v.superview) {
        id icon = SCPCTry(v, @"icon");
        if (icon) bid = SCPCIconBundle(icon);
    }
    if (!bid || ![self isCarPlayApp:bid]) {
        SCPLog("CarSplit: giu icon %@ -> khong chia man duoc", bid);
        if (bid) [self toast:@"App này không chia màn hình được"];
        return;
    }
    SCPLog("CarSplit: giu icon %@ -> bang bo cuc", bid);
    [self showLayoutPanelForApp:bid];
}

// Man xe vua hien (cam xe). Bat "Tu mo split khi cam xe" -> doi DashBoard san sang roi mo cap da nho.
- (void)carScreenAppeared
{
    if (self.autoLaunchDone) return;
    self.autoLaunchDone = YES;
    if (![SCPPrefs enabled] || ![SCPPrefs autoLaunch]) return;
    SCPLog("CarSplit: cam xe -> se tu mo split");
    [self autoLaunchAttempt:0];
}

- (void)autoLaunchAttempt:(int)n
{
    __weak SCPCarSplit *weakSelf = self;
    if (self.active) return;
    if (!SCPCRootVC() && n < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf autoLaunchAttempt:n + 1];
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPCarSplit *me = weakSelf;
        if (!me || me.active) return;
        SCPLog("CarSplit: tu mo split khi cam xe");
        [me openRememberedPair];
    });
}

- (void)toast:(NSString *)msg
{
    UIView *host = SCPCRootVC().view;
    if (!host) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    [l sizeToFit];
    l.bounds = CGRectMake(0, 0, l.bounds.size.width + 40, 38);
    SCPCChrome(l, 19);
    l.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.96];
    l.center = CGPointMake(CGRectGetMidX(host.bounds), host.bounds.size.height - 50);
    [host addSubview:l];
    l.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

@end


