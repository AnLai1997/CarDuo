#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <dlfcn.h>

@interface SCPRootListController : PSListController
@end

@implementation SCPRootListController

// AltList cung cap ATLApplicationListSelectionController (chon app). Nap dong de khong can link luc build.
+ (void)initialize
{
    if (self != [SCPRootListController class]) return;
    if (!dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList", RTLD_NOW)) {
        dlopen("/Library/Frameworks/AltList.framework/AltList", RTLD_NOW);
    }
}

// Cell co key "height" trong Root.plist (khung xem truoc)
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    id h = [sp propertyForKey:@"height"];
    if (h) return [h floatValue];
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Gui Darwin notification sang SpringBoard
- (void)runTest
{
    notify_post("com.anpham.splitcarplay.test");
}

- (void)bubbleDemo
{
    notify_post("com.anpham.splitcarplay.bubbledemo");
}

- (void)closeSplit
{
    notify_post("com.anpham.splitcarplay.close");
}

- (void)clearLog
{
    notify_post("com.anpham.splitcarplay.clearlog");
}

@end
