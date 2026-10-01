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

- (void)closeSplit
{
    notify_post("com.anpham.splitcarplay.close");
}

@end
