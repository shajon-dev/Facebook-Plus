// Lists and applies Facebook's built-in alternate app icons.

#import "FBPAppIconController.h"
#import "FBPResources.h"
#import "FBPAlert.h"
#import "FBPToast.h"

#import <objc/runtime.h>

#pragma mark - System icon-change alert suppression

// -setAlternateIconName: makes UIKit present its own unstyled "You have changed
// the icon for …" alert. The tweak replaces it with a toast, so the stock alert
// is dropped — but only the single alert that immediately follows the tweak's own
// icon change, guarded by this flag so no other alert in the app is ever affected.
static BOOL gFBPSuppressIconAlert = NO;

@implementation UIViewController (FBPIconAlert)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(
            self, @selector(presentViewController:animated:completion:));
        Method replacement = class_getInstanceMethod(
            self, @selector(fbp_presentViewController:animated:completion:));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

- (void)fbp_presentViewController:(UIViewController *)viewControllerToPresent
                        animated:(BOOL)flag
                      completion:(void (^)(void))completion {
    if (gFBPSuppressIconAlert &&
        [viewControllerToPresent isKindOfClass:UIAlertController.class]) {
        gFBPSuppressIconAlert = NO;
        if (completion) completion();
        return;   // swallow the stock icon-change alert
    }
    // Not a swizzle recursion: names are exchanged, so this calls the original.
    [self fbp_presentViewController:viewControllerToPresent
                          animated:flag
                        completion:completion];
}

@end

// name  : the value passed to -setAlternateIconName: (nil = the default icon)
// title : what the row shows
// image : the icon file in Facebook's own bundle used for the preview
static NSString *const kName  = @"name";
static NSString *const kTitle = @"title";
static NSString *const kImage = @"image";

static NSString *const kCell = @"fbp.appicon.row";

#pragma mark - Cell

/// FBP-prefixed so the OLED sweep leaves its card colour alone (a plain
/// UITableViewCell would be blackened to invisibility in OLED mode). Painted and
/// typed to match the main settings rows.
@interface FBPAppIconCell : UITableViewCell
@end
@implementation FBPAppIconCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                     reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = FBPCardColor();
        self.textLabel.font = FBPFont(16, UIFontWeightRegular);
        self.textLabel.textColor = UIColor.labelColor;   // white under the dark override
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface FBPAppIconController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *icons;
// The applied icon name (nil = default), tracked locally so the checkmark
// updates the instant a row is tapped instead of waiting on -alternateIconName,
// which does not reliably reflect the change inside the completion handler.
@property (nonatomic, copy, nullable) NSString *selectedName;
@end

@implementation FBPAppIconController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        // The default icon carries no name; every other entry matches a key in
        // Facebook's CFBundleAlternateIcons and a PNG shipped in the app bundle.
        NSMutableArray<NSDictionary *> *icons = [@[
            @{ kTitle : @"Default",   kImage : @"Icon-Production60x60" },
            @{ kName : @"AltAppIconChill",     kTitle : @"Chill",     kImage : @"AltAppIconChill@2x" },
            @{ kName : @"AltAppIconDreamy",    kTitle : @"Dreamy",    kImage : @"AltAppIconDreamy@2x" },
            @{ kName : @"AltAppIconFab",       kTitle : @"Fab",       kImage : @"AltAppIconFab@2x" },
            @{ kName : @"AltAppIconFierce",    kTitle : @"Fierce",    kImage : @"AltAppIconFierce@2x" },
            @{ kName : @"AltAppIconLovey",     kTitle : @"Lovey",     kImage : @"AltAppIconLovey@2x" },
            @{ kName : @"AltAppIconVaporwave", kTitle : @"Vaporwave", kImage : @"AltAppIconVaporwave@2x" },
        ] mutableCopy];

        // Custom logos injected by build.py (its cyan step) show up as extra
        // "fbplus_" entries in the app's own CFBundleAlternateIcons; discover them
        // at runtime so they only appear when actually present in the bundle.
        [icons addObjectsFromArray:[self customIconEntries]];

        _icons = icons;
    }
    return self;
}

/// The fbplus_* alternate icons declared in the app's Info.plist, as row models.
/// Empty on any build where no custom logo was injected.
- (NSArray<NSDictionary *> *)customIconEntries {
    NSDictionary *bundleIcons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
    NSDictionary *alternates = bundleIcons[@"CFBundleAlternateIcons"];
    if (![alternates isKindOfClass:NSDictionary.class]) return @[];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in alternates) {
        if (![name hasPrefix:@"fbplus_"]) continue;
        entries[entries.count] = @{ kName : name, kImage : name,
                                    kTitle : [self displayNameForIcon:name] };
    }
    // Stable, alphabetical order by display name.
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[kTitle] localizedCaseInsensitiveCompare:b[kTitle]];
    }];
    return entries;
}

/// "fbplus_neon_glow" -> "Neon Glow".
- (NSString *)displayNameForIcon:(NSString *)name {
    NSString *base = [name substringFromIndex:@"fbplus_".length];
    base = [base stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    base = [base stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    return base.localizedCapitalizedString;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FBPL(@"row.appicon.title");
    self.selectedName = [UIApplication.sharedApplication alternateIconName];

    // Match the main settings screen: a fixed dark panel that never shifts with
    // the host app's OLED / dark / light state.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.tintColor = FBPTintColor();
    self.tableView.backgroundColor = FBPPanelColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;

    [self.tableView registerClass:FBPAppIconCell.class forCellReuseIdentifier:kCell];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(closeTapped)];
    [self applyNavigationChrome];
}

/// A black, opaque navigation bar with a white rounded title, so the pushed page
/// reads as part of the same tweak UI in every theme.
- (void)applyNavigationChrome {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;
    self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.tintColor = FBPTintColor();
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = FBPPanelColor();
        appearance.shadowColor = UIColor.clearColor;
        appearance.titleTextAttributes = @{
            NSForegroundColorAttributeName : FBPIconColor(),
            NSFontAttributeName : FBPFont(17, UIFontWeightSemibold),
        };
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// The value -setAlternateIconName: expects for the currently applied icon, or
/// nil for the default. Read from the controller's own optimistic state.
- (nullable NSString *)currentIconName {
    return self.selectedName;
}

#pragma mark - Table

// One icon per section, so the inset-grouped style leaves a gap between each row.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.icons.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 8.0;   // the gap between icon cards
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 4.0 : CGFLOAT_MIN;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCell
                                                            forIndexPath:indexPath];
    NSDictionary *entry = self.icons[indexPath.section];

    // Only the default entry's title is localized; the alternate icons are proper
    // names (Chill, Dreamy, …) and stay as-is.
    cell.textLabel.text = entry[kName] ? entry[kTitle] : FBPL(@"appicon.default");

    // The preview is the icon art from Facebook's own bundle, rounded like a home
    // screen icon.
    UIImage *preview = [UIImage imageNamed:entry[kImage]];
    cell.imageView.image = preview;
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
    cell.imageView.clipsToBounds = YES;
    cell.imageView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    cell.imageView.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;

    NSString *name = entry[kName]; // nil for default
    NSString *current = [self currentIconName];
    BOOL selected = (name == nil) ? (current == nil) : [name isEqualToString:current];
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark
                                  : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *name = self.icons[indexPath.section][kName]; // nil = default
    if (![UIApplication.sharedApplication supportsAlternateIcons]) {
        [self showError:FBPL(@"appicon.error.unsupported")];
        return;
    }

    NSString *title = name ? self.icons[indexPath.section][kTitle] : FBPL(@"appicon.default");
    NSString *previous = self.selectedName;
    if (previous == name || [previous isEqualToString:name]) return;   // already applied

    // Move the checkmark immediately, then apply. Suppress the stock alert; a
    // toast confirms the change instead.
    self.selectedName = name;
    [self.tableView reloadData];

    // The stock alert is presented around (often just after) the completion, so
    // the flag stays armed until the swizzle catches that alert; a safety timer
    // disarms it if none arrives, so no later alert is ever swallowed.
    gFBPSuppressIconAlert = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ gFBPSuppressIconAlert = NO; });

    [UIApplication.sharedApplication setAlternateIconName:name
                                       completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                gFBPSuppressIconAlert = NO;
                self.selectedName = previous;   // revert the optimistic move
                [self.tableView reloadData];
                [self showError:FBPL(@"appicon.error.failed")];
            } else {
                [FBPToastManager.shared showMessage:[NSString stringWithFormat:FBPL(@"appicon.applied"), title]
                                            success:YES];
            }
        });
    }];
}

#pragma mark - Helpers

- (void)showError:(NSString *)message {
    [FBPAlert showWithTitle:FBPL(@"row.appicon.title")
                    message:message
                cancelTitle:nil
               confirmTitle:FBPL(@"common.ok")
                destructive:NO
                  onConfirm:nil
                   onCancel:nil];
}

@end
