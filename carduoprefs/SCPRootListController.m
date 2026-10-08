#import "SCPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <spawn.h>
#import <dlfcn.h>
#import "SCPLang.h"

#define kPrefsDomain CFSTR("com.anlai97.carduo")
// Key the language choice is stored under ("vi" / "en", same as earlier versions).
#define kLanguageKey CFSTR("Language")
// Enable switch key (same as the first switch in Root.plist); the header's status chip reads it.
#define kEnabledKey CFSTR("Enabled")
// The tweak re-reads its prefs on this notification (also posted by every stored cell).
#define kPrefsChanged "com.anlai97.carduo.prefschanged"

#pragma mark - Localization

// The app language is picked in the nav bar, so strings come from <lang>.lproj by hand
// instead of following the system language.
static NSDictionary<NSString *, NSString *> *sStrings;

static NSArray<NSString *> *SCPLanguages(void) {
	return @[@"vi", @"en"];
}

static NSString *SCPLanguageName(NSString *lang) {
	return [lang isEqualToString:@"vi"] ? @"Tiếng Việt" : @"English";
}

NSString *SCPLanguage(void) {
	NSString *lang = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(kLanguageKey, kPrefsDomain);
	if (lang && [SCPLanguages() containsObject:lang]) return lang;
	return [[NSLocale preferredLanguages].firstObject hasPrefix:@"vi"] ? @"vi" : @"en";
}

static void SCPLoadStrings(void) {
	NSString *bundlePath = [NSBundle bundleForClass:NSClassFromString(@"SCPRootListController")].bundlePath;
	NSString *path = [bundlePath stringByAppendingFormat:@"/%@.lproj/Localizable.strings", SCPLanguage()];
	sStrings = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
}

// Shared with the app picker (declared in SCPLang.h).
NSString *L(NSString *key) {
	if (!sStrings) SCPLoadStrings();
	return sStrings[key] ?: key;
}

#pragma mark - HarmonyOS theme

static UIColor *SCPDynamicColor(UInt32 light, UInt32 dark) {
	UIColor *(^rgb)(UInt32) = ^(UInt32 v) {
		return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
	};
	UIColor *l = rgb(light), *d = rgb(dark);
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
		return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
	}];
}

static UIColor *SCPAccentColor(void)     { return SCPDynamicColor(0x0A59F7, 0x317AF7); }
static UIColor *SCPBackgroundColor(void) { return SCPDynamicColor(0xF1F3F5, 0x000000); }
static UIColor *SCPCardColor(void)       { return SCPDynamicColor(0xFFFFFF, 0x202224); }

static UIColor *SCPColorFromHex(NSString *hex) {
	unsigned int v = 0;
	[[NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]] scanHexInt:&v];
	return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

// Row icon: a white SF Symbol on a rounded, softly lit color tile.
static UIImage *SCPIcon(NSString *symbol, UIColor *color) {
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
	UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
	if (!glyph) return nil;

	const CGFloat side = 29;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		CGRect rect = CGRectMake(0, 0, side, side);
		UIBezierPath *tile = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8.5];
		[color setFill];
		[tile fill];

		[tile addClip];
		CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
		NSArray *colors = @[(id)[UIColor colorWithWhite:1 alpha:0.22].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
		CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
		CGContextDrawLinearGradient(ctx.CGContext, gradient, CGPointZero, CGPointMake(0, side), 0);
		CGGradientRelease(gradient);
		CGColorSpaceRelease(space);

		CGSize s = glyph.size;
		[glyph drawInRect:CGRectMake((side - s.width) / 2, (side - s.height) / 2, s.width, s.height)];
	}];
}

static BOOL SCPEnabled(void) {
	id value = (__bridge_transfer id)CFPreferencesCopyAppValue(kEnabledKey, kPrefsDomain);
	return value ? [value boolValue] : YES;
}

#pragma mark - Header card

// Blue gradient card: app icon on the left, name + tagline in white, and an On/Off chip
// (no version - that lives in the footer card).
@interface SCPHeaderCard : UIView
@property (nonatomic, strong) UIView *card, *clip, *glowLarge, *glowSmall, *chip, *dot;
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) UILabel *nameLabel, *taglineLabel, *statusLabel;
- (void)updateWithTagline:(NSString *)tagline status:(NSString *)status enabled:(BOOL)enabled;
@end

@implementation SCPHeaderCard

- (instancetype)initWithFrame:(CGRect)frame {
	if (!(self = [super initWithFrame:frame])) return nil;
	self.preservesSuperviewLayoutMargins = YES;

	// card carries the shadow, clip rounds the content
	_card = [UIView new];
	_card.layer.cornerRadius = 24;
	_card.layer.cornerCurve = kCACornerCurveContinuous;
	_card.layer.shadowColor = [UIColor colorWithRed:0.04 green:0.27 blue:0.88 alpha:1].CGColor;
	_card.layer.shadowOpacity = 0.30;
	_card.layer.shadowRadius = 14;
	_card.layer.shadowOffset = CGSizeMake(0, 6);
	[self addSubview:_card];

	_clip = [UIView new];
	_clip.layer.cornerRadius = 24;
	_clip.layer.cornerCurve = kCACornerCurveContinuous;
	_clip.clipsToBounds = YES;
	[_card addSubview:_clip];

	_gradient = [CAGradientLayer layer];
	_gradient.colors = @[(id)[UIColor colorWithRed:0.36 green:0.71 blue:1.00 alpha:1].CGColor,
	                     (id)[UIColor colorWithRed:0.12 green:0.42 blue:1.00 alpha:1].CGColor,
	                     (id)[UIColor colorWithRed:0.04 green:0.27 blue:0.88 alpha:1].CGColor];
	_gradient.locations = @[@0, @0.55, @1];
	_gradient.startPoint = CGPointZero;
	_gradient.endPoint = CGPointMake(1, 1);
	[_clip.layer addSublayer:_gradient];

	// Two soft circles on the right (glass highlight)
	_glowLarge = [UIView new];
	_glowLarge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
	[_clip addSubview:_glowLarge];
	_glowSmall = [UIView new];
	_glowSmall.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
	[_clip addSubview:_glowSmall];

	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	_logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"logo" inBundle:bundle compatibleWithTraitCollection:nil]];
	_logo.layer.shadowColor = UIColor.blackColor.CGColor;
	_logo.layer.shadowOpacity = 0.18;
	_logo.layer.shadowRadius = 8;
	_logo.layer.shadowOffset = CGSizeMake(0, 4);
	[_clip addSubview:_logo];

	_nameLabel = [UILabel new];
	_nameLabel.text = @"CarDuo";
	_nameLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
	_nameLabel.textColor = UIColor.whiteColor;
	[_clip addSubview:_nameLabel];

	_taglineLabel = [UILabel new];
	_taglineLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
	_taglineLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
	_taglineLabel.numberOfLines = 2;
	[_clip addSubview:_taglineLabel];

	_chip = [UIView new];
	_chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
	_chip.layer.cornerRadius = 11;
	[_clip addSubview:_chip];

	_dot = [UIView new];
	_dot.layer.cornerRadius = 3.5;
	[_chip addSubview:_dot];

	_statusLabel = [UILabel new];
	_statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
	_statusLabel.textColor = UIColor.whiteColor;
	[_chip addSubview:_statusLabel];
	return self;
}

- (void)updateWithTagline:(NSString *)tagline status:(NSString *)status enabled:(BOOL)enabled {
	_taglineLabel.text = tagline;
	_statusLabel.text = status;
	_dot.backgroundColor = enabled ? [UIColor colorWithRed:0.45 green:0.95 blue:0.55 alpha:1]
	                               : [UIColor colorWithRed:1.00 green:0.55 blue:0.45 alpha:1];
	[self setNeedsLayout];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	// Lines up with the inset-grouped rows below
	UIEdgeInsets m = self.layoutMargins;
	CGRect r = CGRectMake(m.left, 16, self.bounds.size.width - m.left - m.right, self.bounds.size.height - 32);
	_card.frame = r;
	_clip.frame = _card.bounds;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_gradient.frame = _clip.bounds;
	[CATransaction commit];
	_card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:24].CGPath;

	CGFloat W = r.size.width, H = r.size.height;
	_glowLarge.frame = CGRectMake(W - 120, -50, 170, 170);
	_glowLarge.layer.cornerRadius = 85;
	_glowSmall.frame = CGRectMake(W - 60, H - 70, 110, 110);
	_glowSmall.layer.cornerRadius = 55;

	const CGFloat side = 64;
	_logo.frame = CGRectMake(20, (H - side) / 2, side, side);
	CGFloat x = CGRectGetMaxX(_logo.frame) + 16, w = W - x - 16;
	// Name, tagline (1-2 lines) and chip as one block, centered vertically
	CGFloat taglineH = ceil([_taglineLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
	_nameLabel.frame = CGRectMake(x, (H - (32 + taglineH + 8 + 22)) / 2, w, 32);
	_taglineLabel.frame = CGRectMake(x, CGRectGetMaxY(_nameLabel.frame), w, taglineH);

	CGSize s = [_statusLabel sizeThatFits:CGSizeMake(w, 22)];
	_chip.frame = CGRectMake(x, CGRectGetMaxY(_taglineLabel.frame) + 8, s.width + 30, 22);
	_dot.frame = CGRectMake(10, 7.5, 7, 7);
	_statusLabel.frame = CGRectMake(22, 0, s.width, 22);
}

@end

@interface SCPRootListController ()
@property (nonatomic, strong) SCPHeaderCard *headerCard;
@end

@implementation SCPRootListController

#pragma mark - Specifiers

- (NSArray *)specifiers {
	if (!_specifiers) {
		SCPLoadStrings();
		NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
		// Bo cuc yeu thich: dong "O 3" chi hien khi bo cuc co 3 o (3 o / 1 lon + 2)
		for (PSSpecifier *spec in [specs copy]) {
			NSString *key = [spec propertyForKey:@"key"];
			if (![key hasPrefix:@"Fav"] || ![key hasSuffix:@"Third"] || key.length < 4) continue;
			NSInteger layout = [SCPPrefValue([[key substringToIndex:4] stringByAppendingString:@"Layout"]) integerValue];
			if (layout != 3 && layout != 13) [specs removeObject:spec];
		}
		_specifiers = specs;
		[self localizeSpecifiers:_specifiers];
	}
	return _specifiers;
}

// Root.plist holds string keys; swap them for the chosen language and attach the row icons.
- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers {
	for (PSSpecifier *spec in specifiers) {
		if (spec.name.length) spec.name = L(spec.name);
		NSString *footer = [spec propertyForKey:@"footerText"];
		if (footer) [spec setProperty:L(footer) forKey:@"footerText"];
		NSString *placeholder = [spec propertyForKey:@"placeholder"];
		if (placeholder) [spec setProperty:L(placeholder) forKey:@"placeholder"];

		// Lists filled at runtime (file names etc.) set "dynamicTitles" so they are left alone.
		if (spec.titleDictionary.count && ![[spec propertyForKey:@"dynamicTitles"] boolValue]) {
			NSMutableDictionary *titles = [NSMutableDictionary dictionary];
			[spec.titleDictionary enumerateKeysAndObjectsUsingBlock:^(id value, NSString *title, BOOL *stop) {
				titles[value] = L(title);
			}];
			spec.titleDictionary = titles;
		}

		NSString *symbol = [spec propertyForKey:@"symbol"];
		if (symbol) {
			UIImage *icon = SCPIcon(symbol, SCPColorFromHex([spec propertyForKey:@"symbolColor"] ?: @"#0A59F7"));
			if (icon) [spec setProperty:icon forKey:@"iconImage"];
		}
	}
}

#pragma mark - Appearance

- (void)viewDidLoad {
	[super viewDidLoad];
	// Scoped to this controller so the rest of Settings keeps its own look.
	[UISwitch appearanceWhenContainedInInstancesOfClasses:@[[self class]]].onTintColor = SCPAccentColor();
	[UISlider appearanceWhenContainedInInstancesOfClasses:@[[self class]]].minimumTrackTintColor = SCPAccentColor();
	UISegmentedControl *segments = [UISegmentedControl appearanceWhenContainedInInstancesOfClasses:@[[self class]]];
	segments.selectedSegmentTintColor = SCPAccentColor();
	[segments setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
	                                   NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
	                        forState:UIControlStateSelected];
	[self applyLanguage];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// Pick up values the tweak wrote from another process (e.g. SpringBoard) since last time,
	// and the app chosen in the picker we may be coming back from.
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self reloadSpecifiers];
	[self updateHeaderStatus];
	self.table.backgroundColor = SCPBackgroundColor();
	self.table.tintColor = SCPAccentColor();
}

- (void)applyLanguage {
	SCPLoadStrings();
	self.title = @"CarDuo";
	self.table.tableHeaderView = [self headerView];
	self.table.tableFooterView = [self footerView];
	self.navigationItem.rightBarButtonItem = [self languageButton];
}

- (UIBarButtonItem *)languageButton {
	NSString *current = SCPLanguage();
	NSMutableArray *actions = [NSMutableArray array];
	__weak typeof(self) weakSelf = self;
	for (NSString *lang in SCPLanguages()) {
		UIAction *action = [UIAction actionWithTitle:SCPLanguageName(lang) image:nil identifier:nil handler:^(UIAction *a) {
			[weakSelf setLanguage:lang];
		}];
		action.state = [lang isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}
	UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:nil action:nil];
	item.menu = [UIMenu menuWithTitle:L(@"LANGUAGE") children:actions];
	item.tintColor = SCPAccentColor();
	return item;
}

- (void)setLanguage:(NSString *)lang {
	CFPreferencesSetAppValue(kLanguageKey, (__bridge CFStringRef)lang, kPrefsDomain);
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self applyLanguage];
	_specifiers = nil;
	[self reloadSpecifiers];
	notify_post(kPrefsChanged);
}

// A full-width table header/footer holding one rounded card: an image beside a column of text lines.
// The card follows the table's layout margins so it lines up with the inset-grouped rows.
- (UIView *)cardContainerWithHeight:(CGFloat)height insets:(UIEdgeInsets)insets image:(UIImage *)image side:(CGFloat)side imageOnRight:(BOOL)imageOnRight lines:(NSArray<UILabel *> *)lines {
	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, height)];
	container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	container.preservesSuperviewLayoutMargins = YES;

	UIView *card = [UIView new];
	card.backgroundColor = SCPCardColor();
	card.layer.cornerRadius = 20;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:card];

	UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
	imageView.translatesAutoresizingMaskIntoConstraints = NO;

	UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:lines];
	text.axis = UILayoutConstraintAxisVertical;
	text.spacing = 3;

	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:imageOnRight ? @[text, imageView] : @[imageView, text]];
	row.alignment = UIStackViewAlignmentCenter;
	row.spacing = 14;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:row];

	UILayoutGuide *margins = container.layoutMarginsGuide;
	[NSLayoutConstraint activateConstraints:@[
		[card.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[card.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[card.topAnchor constraintEqualToAnchor:container.topAnchor constant:insets.top],
		[card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-insets.bottom],
		[imageView.widthAnchor constraintEqualToConstant:side],
		[imageView.heightAnchor constraintEqualToConstant:side],
		[row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
		imageOnRight ? [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16]
		             : [row.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
		[row.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
	]];
	return container;
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
	UILabel *label = [UILabel new];
	label.text = text;
	label.font = [UIFont systemFontOfSize:size weight:weight];
	label.textColor = color;
	label.numberOfLines = 0;
	return label;
}

// Top card (gradient, see SCPHeaderCard). The enable switch follows as the first row.
- (UIView *)headerView {
	if (!self.headerCard) {
		self.headerCard = [[SCPHeaderCard alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
		self.headerCard.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	}
	[self updateHeaderStatus];
	return self.headerCard;
}

- (void)updateHeaderStatus {
	[self updateHeaderStatusEnabled:SCPEnabled()];
}

- (void)updateHeaderStatusEnabled:(BOOL)enabled {
	[self.headerCard updateWithTagline:L(@"HEADER_TAGLINE") status:L(enabled ? @"STATUS_ON" : @"STATUS_OFF") enabled:enabled];
}

// The chip follows the enable switch right away (uses the new value, not a possibly stale prefs read).
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];
	NSString *key = [specifier propertyForKey:@"key"];
	if ([key isEqualToString:(__bridge NSString *)kEnabledKey]) [self updateHeaderStatusEnabled:[value boolValue]];
	// Doi bo cuc yeu thich -> hien / an dong "O 3"
	if ([key hasPrefix:@"Fav"] && [key hasSuffix:@"Layout"]) {
		SCPSetPrefValue(key, value);   // ghi dong bo de buoc loc "O 3" doc dung gia tri moi
		_specifiers = nil;
		[self reloadSpecifiers];
	}
}

#pragma mark - Respring

// Nut "Respring" trong Root.plist (action = respring): hoi lai roi khoi dong lai SpringBoard.
- (void)respring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"RESPRING_CONFIRM") message:nil
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"RESPRING") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
		[self performRespring];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

// Respring kieu userspace (FBSSystemService + SBSRelaunchAction, nhu nut Respring cua cac tweak khac);
// khong co thi killall SpringBoard.
- (void)performRespring {
	dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
	dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
	Class relaunch = NSClassFromString(@"SBSRelaunchAction"), service = NSClassFromString(@"FBSSystemService");
	if (relaunch && service) {
		id action = ((id (*)(Class, SEL, NSString *, NSUInteger, NSURL *))objc_msgSend)(relaunch,
			NSSelectorFromString(@"actionWithReason:options:targetURL:"), @"RestartRenderServer", 4 /* FadeToBlack */, nil);
		id shared = ((id (*)(Class, SEL))objc_msgSend)(service, NSSelectorFromString(@"sharedService"));
		if (action && shared) {
			((void (*)(id, SEL, NSSet *, id))objc_msgSend)(shared, NSSelectorFromString(@"sendActions:withResult:"),
				[NSSet setWithObject:action], nil);
			return;
		}
	}
	for (NSString *path in @[@"/var/jb/usr/bin/killall", @"/usr/bin/killall"]) {
		if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) continue;
		pid_t pid;
		const char *argv[] = {path.fileSystemRepresentation, "-9", "SpringBoard", NULL};
		posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
		return;
	}
}

// Bottom card: author logo, app name, version and copyright.
- (UIView *)footerView {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *avatar = [UIImage imageNamed:@"avatar" inBundle:bundle compatibleWithTraitCollection:nil];
	return [self cardContainerWithHeight:136 insets:UIEdgeInsetsMake(8, 0, 32, 0) image:avatar side:56 imageOnRight:NO lines:@[
		[self labelWithText:@"CarDuo" size:16 weight:UIFontWeightSemibold color:[UIColor labelColor]],
		[self labelWithText:[NSString stringWithFormat:L(@"VERSION_FORMAT"), @TWEAK_VERSION] size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
		[self labelWithText:L(@"COPYRIGHT") size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
	]];
}

// Rows with a "height" in Root.plist (the car screen preview).
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	id height = [[self specifierAtIndexPath:indexPath] propertyForKey:@"height"];
	if (height) return [height floatValue];
	return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	cell.backgroundColor = SCPCardColor();
	cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

	// Action rows read as regular navigation rows; only destructive ones stay red.
	PSSpecifier *spec = [cell isKindOfClass:[PSTableCell class]] ? ((PSTableCell *)cell).specifier : nil;
	if (spec.cellType == PSButtonCell) {
		BOOL destructive = [[spec propertyForKey:@"isDestructive"] boolValue];
		cell.textLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
		cell.accessoryType = destructive ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayHeaderView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	label.textColor = [UIColor secondaryLabelColor];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayFooterView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:12];
	label.textColor = [UIColor secondaryLabelColor];
}


@end
