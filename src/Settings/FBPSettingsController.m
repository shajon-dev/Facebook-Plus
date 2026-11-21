// Settings UI.
//
// A top-level menu of categories (each a row with a monochrome glyph, a title
// and a short summary) plus two info cards (app versions, developer / links).
// Tapping a category pushes a page holding only that category's switches: the
// iOS Settings pattern, short per screen rather than one long mixed list.
//
// The whole panel uses a fixed dark palette (FBPPanelColor / FBPCardColor),
// pinned regardless of the host app's OLED / dark / light setting.

#import "FBPSettingsController.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"
#import "FBPAppIconController.h"
#import "FBPDownloadManagerController.h"
#import "FBPDownloadStore.h"
#import "FBPFontController.h"
#import "FBPLanguageController.h"
#import "FBPWelcomeController.h"
#import "FBPUpdateChecker.h"
#import "FBPCacheCleaner.h"
#import "FBPTrace.h"

#import <objc/runtime.h>
#import <Security/Security.h>
#import <Photos/Photos.h>

// The tweak's version is injected from the control file at build time
// (-DFBP_VERSION in the Makefile), so it is never hardcoded here.
#ifndef FBP_VERSION
#define FBP_VERSION @"—"
#endif

#pragma mark - Row / section model keys

static NSString *const kRowType    = @"type";
static NSString *const kRowKey     = @"key";     // pref key, action id, or link URL
static NSString *const kRowTitle   = @"title";
static NSString *const kRowDesc    = @"desc";
static NSString *const kRowIcon    = @"icon";
static NSString *const kRowValue   = @"value";   // trailing value text (info / action)
static NSString *const kRowLink    = @"link";    // tappable URL (info rows)
static NSString *const kRowDanger  = @"danger";
static NSString *const kRowCategory = @"category"; // detail sections for a menu row
static NSString *const kRowConfirm  = @"confirmOnEnable"; // {title,message,confirm} alert shown before a switch turns on
// Set on a row whose own switch is off upstream: it is drawn in a muted colour
// and stops responding to touch entirely, rather than offering a choice that
// changes nothing. See FBPPlusModeRow and FBPRowGatesOtherRows.
static NSString *const kRowDisabled = @"disabled";

// Defined with the row builders below, used by the switch handler above them.
static BOOL FBPRowGatesOtherRows(NSString *key);

// Associated-object key for a switch's confirm-on-enable payload. Its address is
// the key; the stored value is the kRowConfirm dictionary.
static const void *kFBPSwitchConfirmKey = &kFBPSwitchConfirmKey;

static NSString *const kTypeSwitch   = @"switch";
static NSString *const kTypeAction   = @"action";
static NSString *const kTypeInfo     = @"info";
static NSString *const kTypeCategory = @"catnav";
static NSString *const kTypeButton   = @"button";  // title with a trailing pill button

static NSString *const kSecRows   = @"rows";
static NSString *const kSecFooter = @"footer";

static NSString *const kActionClearCache  = @"clearCache";
static NSString *const kActionAppIcon     = @"appIcon";
static NSString *const kActionFonts       = @"fonts";
static NSString *const kActionWelcome     = @"welcome";
static NSString *const kActionReset       = @"reset";
static NSString *const kActionSuspend     = @"suspend";
static NSString *const kActionLanguage    = @"language";
static NSString *const kActionCheckUpdate = @"checkUpdate";
static NSString *const kActionDownloads   = @"downloads";
static NSString *const kActionLogExport  = @"logExport";
static NSString *const kActionLogClear   = @"logClear";
static NSString *const kActionPlusMode   = @"plusMode";

static NSString *const kCellIdentifier = @"fbp.settings.row";
static NSString *const kTelegramURL    = @"https://t.me/ReFacebookPlus";

static const CGFloat kContentInset = 16.0;

#pragma mark - Icon loading

/// Monochrome bundled glyph by default; a few assets are solid brand / app logos
/// and are rendered in their own colours instead of flattened to white.
static UIImage *FBPSettingsIcon(NSString *name) {
    static NSSet *original;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ original = [NSSet setWithArray:@[@"facebook", @"logo", @"telegram"]]; });

    if ([original containsObject:name]) {
        UIImage *img = [UIImage imageNamed:name
                                  inBundle:NSBundle.fbp_resourceBundle
             compatibleWithTraitCollection:nil];
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    UIImage *img = [UIImage fbp_imageNamed:name];
    if (!img) img = [UIImage fbp_symbolNamed:name size:20 weight:UIImageSymbolWeightRegular];
    return img;
}

#pragma mark - Cell

@interface FBPSettingsCell : UITableViewCell
@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIStackView *labelStack;
@property (nonatomic, strong) UIView *accessoryContainer;
@end

@implementation FBPSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = FBPCardColor();
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        self.selectedBackgroundView = selected;

        // Invisible slot that keeps the glyph aligned and the label indent
        // consistent; the glyph is monochrome, with no coloured tile.
        _iconTile = [[UIView alloc] init];
        _iconTile.backgroundColor = UIColor.clearColor;
        _iconTile.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconTile];

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = FBPIconColor();
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [_iconTile addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = FBPFont(16, UIFontWeightRegular);
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.numberOfLines = 0;

        _descLabel = [[UILabel alloc] init];
        _descLabel.font = FBPFont(12, UIFontWeightRegular);
        _descLabel.textColor = UIColor.secondaryLabelColor;
        _descLabel.numberOfLines = 0;

        _labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _descLabel]];
        _labelStack.axis = UILayoutConstraintAxisVertical;
        _labelStack.alignment = UIStackViewAlignmentLeading;
        _labelStack.spacing = 1.5;
        _labelStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_labelStack];

        _accessoryContainer = [[UIView alloc] init];
        _accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_accessoryContainer];

        [_labelStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                     forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer setContentHuggingPriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                             forAxis:UILayoutConstraintAxisHorizontal];

        [NSLayoutConstraint activateConstraints:@[
            [_iconTile.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:kContentInset],
            [_iconTile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconTile.widthAnchor constraintEqualToConstant:29],
            [_iconTile.heightAnchor constraintEqualToConstant:29],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:22],
            [_iconView.heightAnchor constraintEqualToConstant:22],

            [_labelStack.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:12],
            [_labelStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_labelStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor
                                                               constant:9],
            [_labelStack.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainer.leadingAnchor
                                                                 constant:-10],

            [_accessoryContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                               constant:-kContentInset],
            [_accessoryContainer.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:52],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    for (UIView *subview in self.accessoryContainer.subviews) [subview removeFromSuperview];
    self.titleLabel.text = nil;
    self.titleLabel.textColor = UIColor.labelColor;
    self.descLabel.text = nil;
    self.descLabel.hidden = YES;
    self.iconView.image = nil;
    self.iconView.tintColor = FBPIconColor();
    self.selectionStyle = UITableViewCellSelectionStyleNone;
}

@end

#pragma mark - Base table controller

@interface FBPTableController : UITableViewController
@end

@implementation FBPTableController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Pin a fixed dark appearance so the host app's theme can never shift it.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPPanelColor();
    self.view.tintColor = FBPTintColor();

    // In a UITableViewController self.view *is* the table, so the panel colour has
    // to live on the table itself — setting it clear let the cards show for a
    // frame over whatever was behind during a push/present, which read as the
    // background arriving late and a janky slide. A backgroundView keeps the
    // surface solid through overscroll as well.
    self.tableView.backgroundColor = FBPPanelColor();
    UIView *panelBackground = [[UIView alloc] init];
    panelBackground.backgroundColor = FBPPanelColor();
    self.tableView.backgroundView = panelBackground;
    self.tableView.separatorInset = UIEdgeInsetsZero;      // full-width hairlines
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:FBPSettingsCell.class forCellReuseIdentifier:kCellIdentifier];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = FBPPanelColor();
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : FBPFont(20, UIFontWeightSemibold),
    };
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
    self.navigationController.navigationBar.tintColor = FBPTintColor();
}

#pragma mark Spacing (tight, even gaps between cards)

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 4 : 12;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if ([self respondsToSelector:@selector(tableView:titleForFooterInSection:)]) {
        NSString *footer = [(id<UITableViewDataSource>)self tableView:tableView
                                             titleForFooterInSection:section];
        if (footer.length) return UITableViewAutomaticDimension;
    }
    return CGFLOAT_MIN;
}

#pragma mark Cell configuration (shared)

- (void)configureCell:(FBPSettingsCell *)cell withRow:(NSDictionary *)row {
    BOOL disabled = [row[kRowDisabled] boolValue];

    cell.titleLabel.text = row[kRowTitle];
    cell.titleLabel.textColor = disabled      ? UIColor.tertiaryLabelColor
                              : [row[kRowDanger] boolValue] ? UIColor.systemRedColor
                                                            : UIColor.labelColor;
    NSString *desc = row[kRowDesc];
    cell.descLabel.text = desc;
    cell.descLabel.hidden = (desc.length == 0);

    UIImage *icon = FBPSettingsIcon(row[kRowIcon]);
    cell.iconView.image = icon;
    cell.iconView.tintColor = FBPIconColor();

    NSString *type = row[kRowType];

    if ([type isEqualToString:kTypeSwitch]) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = FBPTintColor();
        toggle.on = FBPEnabled(row[kRowKey]);
        objc_setAssociatedObject(toggle, @selector(tag), row[kRowKey],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (row[kRowConfirm]) {
            objc_setAssociatedObject(toggle, kFBPSwitchConfirmKey, row[kRowConfirm],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [toggle addTarget:self action:@selector(fbpToggleSwitch:)
         forControlEvents:UIControlEventValueChanged];
        [self setAccessory:toggle inCell:cell];

    } else if ([type isEqualToString:kTypeInfo]) {
        NSString *link = row[kRowLink];
        UILabel *value = [[UILabel alloc] init];
        value.text = row[kRowValue];
        value.font = FBPFont(15, link.length ? UIFontWeightMedium : UIFontWeightRegular);
        value.textColor = link.length ? FBPTintColor() : UIColor.labelColor;
        value.textAlignment = NSTextAlignmentRight;
        [self setAccessory:value inCell:cell];
        cell.selectionStyle = link.length ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;

    } else if ([type isEqualToString:kTypeButton]) {
        // A trailing pill: "Request" to ask for Photos access, or a green
        // "Granted" once it is on. The button is the only control — the row
        // itself does not select. Status is read live, so a reloadData (after a
        // grant, or on the next -viewWillAppear) flips the pill with no stored
        // state.
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        BOOL granted = [self fbpPhotosAddAccessGranted];

        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        [pill setTitle:(granted ? FBPL(@"download.permission.granted")
                                 : FBPL(@"download.permission.request"))
              forState:UIControlStateNormal];
        [pill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        pill.titleLabel.font = FBPFont(14, UIFontWeightSemibold);
        pill.backgroundColor = granted ? UIColor.systemGreenColor : FBPTintColor();
        pill.layer.cornerRadius = 15.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.contentEdgeInsets = UIEdgeInsetsMake(6, 16, 6, 16);
        [pill addTarget:self action:@selector(fbpPhotoPermissionTapped:)
       forControlEvents:UIControlEventTouchUpInside];
        [self setAccessory:pill inCell:cell];

    } else {   // action / category — value and/or chevron
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSMutableArray<UIView *> *pieces = [NSMutableArray array];
        NSString *value = row[kRowValue];
        if (value.length) {
            UILabel *valueLabel = [[UILabel alloc] init];
            valueLabel.font = FBPFont(15, UIFontWeightRegular);
            valueLabel.textColor = UIColor.secondaryLabelColor;
            valueLabel.text = value;
            [pieces addObject:valueLabel];
        }
        // The unlock-method row opens an action sheet, so it gets the up/down
        // menu glyph rather than the push chevron the other rows use.
        BOOL isPicker = [row[kRowKey] isEqualToString:kActionPlusMode];
        BOOL showChevron = [type isEqualToString:kTypeCategory] ||
                           row[kRowCategory] != nil ||
                           isPicker ||
                           [row[kRowKey] isEqualToString:kActionAppIcon] ||
                           [row[kRowKey] isEqualToString:kActionFonts] ||
                           [row[kRowKey] isEqualToString:kActionLanguage] ||
                           [row[kRowKey] isEqualToString:kActionDownloads] ||
                           [row[kRowKey] isEqualToString:kActionWelcome];
        if (showChevron) {
            UIImageView *chevron = [[UIImageView alloc] initWithImage:
                [UIImage fbp_symbolNamed:(isPicker ? @"chevron.up.chevron.down" : @"chevron.right")
                                    size:13 weight:UIImageSymbolWeightSemibold]];
            chevron.tintColor = UIColor.tertiaryLabelColor;
            [pieces addObject:chevron];
        }
        if (pieces.count) {
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:pieces];
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = 7;
            [self setAccessory:stack inCell:cell];
        }
    }

    // Frozen, and it has to *look* frozen. Applied last so it covers whatever
    // the branches above put in the cell — the value label, the chevron, the
    // icon — rather than being undone by them. userInteractionEnabled is what
    // actually stops the touch; the colours are what stop the user reaching for
    // it in the first place. Cells are reused, so the enabled case resets every
    // one of these explicitly.
    cell.contentView.alpha = disabled ? 0.4 : 1.0;
    cell.userInteractionEnabled = !disabled;
    if (disabled) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.iconView.tintColor = UIColor.tertiaryLabelColor;
    }
}

- (void)setAccessory:(UIView *)view inCell:(FBPSettingsCell *)cell {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.accessoryContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:cell.accessoryContainer.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:cell.accessoryContainer.trailingAnchor],
        [view.centerYAnchor constraintEqualToAnchor:cell.accessoryContainer.centerYAnchor],
        [view.topAnchor constraintGreaterThanOrEqualToAnchor:cell.accessoryContainer.topAnchor],
    ]];
}

- (void)fbpToggleSwitch:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, @selector(tag));
    if (!key) return;

    NSDictionary *confirm = objc_getAssociatedObject(sender, kFBPSwitchConfirmKey);
    if (sender.isOn && confirm) {
        // Ask before turning this on. Snap the switch back to off first, so a
        // cancel (or a dismiss) leaves both the UI and the stored preference
        // exactly as they were; only the confirm action commits.
        [sender setOn:NO animated:NO];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:confirm[@"title"]
                             message:confirm[@"message"]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:confirm[@"confirm"]
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            [sender setOn:YES animated:YES];
            [FBPPrefs.shared setBool:YES forKey:key];
            [FBPPrefs.shared commit];
            if (FBPRowGatesOtherRows(key)) [self.tableView reloadData];
        }]];
        // System blue keeps the buttons legible on the alert's light background
        // (the settings tint is tuned for the black panel, not a system alert).
        alert.view.tintColor = UIColor.systemBlueColor;
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [FBPPrefs.shared setBool:sender.isOn forKey:key];
    [FBPPrefs.shared commit];

    // Rows this switch gates have to redraw now, not on the next time the page
    // is opened: turning Facebook Plus off has to grey the unlock-method row
    // while the user is looking at it.
    if (FBPRowGatesOtherRows(key)) [self.tableView reloadData];
}

#pragma mark Photos permission

/// Add-only is all a download save needs; a full-access grant covers it too.
- (BOOL)fbpPhotosAddAccessGranted {
    if (@available(iOS 14.0, *)) {
        PHAuthorizationStatus status =
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        return (status == PHAuthorizationStatusAuthorized ||
                status == PHAuthorizationStatusLimited);
    }
    return YES;
}

- (void)fbpPhotoPermissionTapped:(UIButton *)sender {
    if (@available(iOS 14.0, *)) {
        PHAuthorizationStatus status =
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];

        // Never asked yet: let iOS show its "Add Photos Only" prompt in place,
        // then reload so the pill flips to "Granted".
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                       handler:^(__unused PHAuthorizationStatus granted) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
            }];
            return;
        }

        // Already granted: nothing to ask. The pill already reads "Granted".
        if (status == PHAuthorizationStatusAuthorized ||
            status == PHAuthorizationStatusLimited) {
            return;
        }
    }

    // Denied or restricted: iOS will not prompt again, so Settings is the only
    // way back on. -viewWillAppear reloads on return, flipping the pill if it
    // was changed there.
    NSURL *settings = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    if (settings && [UIApplication.sharedApplication canOpenURL:settings]) {
        [UIApplication.sharedApplication openURL:settings options:@{} completionHandler:nil];
    }
}

@end

#pragma mark - Row builders (shared helpers)

static NSDictionary *FBPSwitchRow(NSString *key, NSString *title, NSString *desc, NSString *icon) {
    NSMutableDictionary *row = [@{ kRowType : kTypeSwitch, kRowKey : key,
                                   kRowTitle : title, kRowIcon : icon } mutableCopy];
    if (desc.length) row[kRowDesc] = desc;
    return row;
}
// A switch that asks for confirmation the moment it is turned on. `alertTitle` /
// `alertMessage` / `confirmButton` are the alert's text; cancelling leaves the
// switch off and writes nothing (see fbpToggleSwitch:).
static NSDictionary *FBPSwitchRowConfirm(NSString *key, NSString *title, NSString *desc,
                                         NSString *icon, NSString *alertTitle,
                                         NSString *alertMessage, NSString *confirmButton) {
    NSMutableDictionary *row = [FBPSwitchRow(key, title, desc, icon) mutableCopy];
    row[kRowConfirm] = @{ @"title"   : alertTitle   ?: @"",
                          @"message" : alertMessage ?: @"",
                          @"confirm" : confirmButton ?: @"" };
    return row;
}
static NSDictionary *FBPActionRow(NSString *action, NSString *title, NSString *desc,
                                  NSString *icon, BOOL danger) {
    NSMutableDictionary *row = [@{ kRowType : kTypeAction, kRowKey : action,
                                   kRowTitle : title, kRowIcon : icon } mutableCopy];
    if (desc.length) row[kRowDesc] = desc;
    if (danger) row[kRowDanger] = @YES;
    return row;
}
static NSDictionary *FBPInfoRow(NSString *title, NSString *value, NSString *icon, NSString *link) {
    NSMutableDictionary *row = [@{ kRowType : kTypeInfo, kRowTitle : title,
                                   kRowValue : value, kRowIcon : icon } mutableCopy];
    if (link.length) row[kRowLink] = link;
    return row;
}
static NSDictionary *FBPSection(NSString *footer, NSArray *rows) {
    NSMutableDictionary *s = [@{ kSecRows : rows } mutableCopy];
    if (footer.length) s[kSecFooter] = footer;
    return s;
}

/// The "Request Permission" row: a title with a trailing pill that asks for (or
/// reports) add-only Photos access, so a save that Photos refused can be put
/// right from the Downloads page itself.
static NSDictionary *FBPPhotoPermissionRow(void) {
    return @{ kRowType : kTypeButton,
              kRowTitle : FBPL(@"download.permission.title"),
              kRowIcon : @"photo.badge.plus" };
}

/// The download manager row, with the number of running downloads as its
/// trailing value.
///
/// Built by its own function rather than inline because the count is read at
/// build time and the category list is rebuilt in -viewWillAppear, so walking
/// back into Settings from anywhere shows a current number.
static NSDictionary *FBPDownloadManagerRow(void) {
    NSMutableDictionary *row =
        [FBPActionRow(kActionDownloads, FBPL(@"download.manager.title"),
                      FBPL(@"download.manager.rowDesc"), @"arrow.down.circle", NO) mutableCopy];

    NSUInteger active = FBPDownloadStore.shared.activeCount;
    if (active > 0) {
        row[kRowValue] = [NSString stringWithFormat:FBPL(@"download.manager.activeCount"),
                                                    (long)active];
    }
    return row;
}

// The Facebook Plus unlock-method picker. Shows the current mode as its trailing
// value; tapping it opens an action sheet (see plusModeTapped).
static NSDictionary *FBPPlusModeRow(void) {
    NSMutableDictionary *row =
        [FBPActionRow(kActionPlusMode, FBPL(@"row.plusmode.title"),
                      nil, @"crown.fill", NO) mutableCopy];
    BOOL trial = [[FBPPrefs.shared stringForKey:FBPKeyMetaPlusMode] isEqualToString:@"trial"];
    row[kRowValue] = trial ? FBPL(@"row.plusmode.trial") : FBPL(@"row.plusmode.direct");
    // The method only means something while Facebook Plus is on: with the
    // toggle off, every gate in FBPPlusHooks.xm declines whichever mode is
    // stored. Offering the picker there invites a change that does nothing, so
    // it is frozen instead — muted, and not tappable.
    if (!FBPEnabled(FBPKeyMetaPlus)) row[kRowDisabled] = @YES;
    return row;
}

/// YES when turning this switch changes whether *other* rows are usable, so the
/// table has to be redrawn rather than just the switch moved.
static BOOL FBPRowGatesOtherRows(NSString *key) {
    return [key isEqualToString:FBPKeyMetaPlus];
}

#pragma mark - Category definitions

/// The categories; each has a title, summary, menu glyph, and the grouped
/// sections shown on its own page.
static NSArray<NSDictionary *> *FBPCategories(void) {
    return @[
        @{ kRowTitle : FBPL(@"cat.ads.title"), kRowDesc : FBPL(@"cat.ads.summary"),
           kRowIcon : @"ads", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyNoAds, FBPL(@"row.noads.title"), FBPL(@"row.noads.desc"), @"ads"),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyNoRecs, FBPL(@"row.norecs.title"), FBPL(@"row.norecs.desc"), @"magic"),
                FBPSwitchRow(FBPKeyNoReels, FBPL(@"row.noreels.title"), nil, @"reels"),
                FBPSwitchRow(FBPKeyNoReelsRecommended, FBPL(@"row.noreelsrecommended.title"), FBPL(@"row.noreelsrecommended.desc"), @"reels"),
                FBPSwitchRow(FBPKeyNoStories, FBPL(@"row.nostories.title"), FBPL(@"row.nostories.desc"), @"incognito"),
                FBPSwitchRow(FBPKeyNoThreads, FBPL(@"row.nothreads.title"), FBPL(@"row.nothreads.desc"), @"at"),
            ]),
            FBPSection(FBPL(@"footer.feedClutter"), @[
                FBPSwitchRow(FBPKeyNoPYMK, FBPL(@"row.nopymk.title"), nil, @"people"),
                FBPSwitchRow(FBPKeyNoGroupSuggestions, FBPL(@"row.nogroups.title"), nil, @"group"),
                FBPSwitchRow(FBPKeyNoSuggestedPages, FBPL(@"row.nosuggestedpages.title"), nil, @"group"),
                FBPSwitchRow(FBPKeyNoSurveys, FBPL(@"row.nosurveys.title"), FBPL(@"row.nosurveys.desc"), @"magic"),
                FBPSwitchRow(FBPKeyNoCommentProductBanner, FBPL(@"row.nocommentbanner.title"), FBPL(@"row.nocommentbanner.desc"), @"ads"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.confirm.title"), kRowDesc : FBPL(@"cat.confirm.summary"),
           kRowIcon : @"alert", kRowCategory : @[
            FBPSection(FBPL(@"footer.confirm"), @[
                FBPSwitchRow(FBPKeyFeedLike, FBPL(@"row.feedlike.title"), FBPL(@"row.feedlike.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmComment, FBPL(@"row.confirmcomment.title"), FBPL(@"row.confirmcomment.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmShare, FBPL(@"row.confirmshare.title"), FBPL(@"row.confirmshare.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmPost, FBPL(@"row.confirmpost.title"), FBPL(@"row.confirmpost.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmFriend, FBPL(@"row.confirmfriend.title"), FBPL(@"row.confirmfriend.desc"), @"people"),
                FBPSwitchRow(FBPKeyConfirmFollow, FBPL(@"row.confirmfollow.title"), FBPL(@"row.confirmfollow.desc"), @"group"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.stories.title"), kRowDesc : FBPL(@"cat.stories.summary"),
           kRowIcon : @"incognito", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyAnonymousStories, FBPL(@"row.anonstories.title"), FBPL(@"row.anonstories.desc"), @"incognito"),
                FBPSwitchRow(FBPKeyNoAutoNext, FBPL(@"row.noautonext.title"), nil, @"reels"),
                FBPSwitchRow(FBPKeyNoStoryPYMK, FBPL(@"row.nostorypymk.title"), FBPL(@"row.nostorypymk.desc"), @"people"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.downloads.title"), kRowDesc : FBPL(@"cat.downloads.summary"),
           kRowIcon : @"download", kRowCategory : @[
            // The manager sits at the top of the category, above the switches
            // that decide whether downloads happen at all: it is the one row
            // here the user comes back to repeatedly rather than sets once.
            FBPSection(nil, @[
                FBPDownloadManagerRow(),
                FBPPhotoPermissionRow(),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyReelsDownloaderEnabled, FBPL(@"row.downloadreels.title"), FBPL(@"row.downloadreels.desc"), @"download"),
                FBPSwitchRow(FBPKeyStoryDownloaderEnabled, FBPL(@"row.downloadstories.title"), FBPL(@"row.downloadstories.desc"), @"download"),
                FBPSwitchRow(FBPKeyDownloadQualityPicker, FBPL(@"row.downloadquality.title"), FBPL(@"row.downloadquality.desc"), @"arrow.down.circle"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.appearance.title"), kRowDesc : FBPL(@"cat.appearance.summary"),
           kRowIcon : @"magic", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyOLED, FBPL(@"row.oled.title"), FBPL(@"row.oled.desc"), @"moon.fill"),
                FBPSwitchRow(FBPKeyOLEDDividers, FBPL(@"row.oleddividers.title"), FBPL(@"row.oleddividers.desc"), @"rectangle.split.1x2"),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyDisableHDR, FBPL(@"row.disablehdr.title"), FBPL(@"row.disablehdr.desc"), @"sun.max"),
            ]),
            FBPSection(nil, @[
                FBPActionRow(kActionAppIcon, FBPL(@"row.appicon.title"), FBPL(@"row.appicon.desc"), @"app.badge.fill", NO),
                FBPActionRow(kActionFonts, FBPL(@"row.fonts.title"), FBPL(@"row.fonts.desc"), @"textformat", NO),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.sidebar.title"), kRowDesc : FBPL(@"cat.sidebar.summary"),
           kRowIcon : @"line.3.horizontal", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyHideSidebarUpgrades, FBPL(@"row.hidesidebarupgrades.title"), nil, @"line.3.horizontal"),
                FBPSwitchRow(FBPKeyHideSidebarAlsoFromMeta, FBPL(@"row.hidesidebaralsometa.title"), nil, @"line.3.horizontal"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.plus.title"), kRowDesc : FBPL(@"cat.plus.summary"),
           kRowIcon : @"crown.fill", kRowCategory : @[
            FBPSection(FBPL(@"footer.metaplus"), @[
                FBPSwitchRowConfirm(FBPKeyMetaPlus, FBPL(@"row.metaplus.title"),
                                    nil, @"crown.fill",
                                    FBPL(@"alert.metaplus.title"),
                                    FBPL(@"alert.metaplus.message"),
                                    FBPL(@"alert.metaplus.confirm")),
            ]),
            FBPSection(FBPL(@"footer.plusmode"), @[
                FBPPlusModeRow(),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.general.title"), kRowDesc : FBPL(@"cat.general.summary"),
           kRowIcon : @"setting", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyLinksInSafari, FBPL(@"row.linksinsafari.title"), FBPL(@"row.linksinsafari.desc"), @"safari.fill"),
                FBPActionRow(kActionLanguage, FBPL(@"row.language.title"), nil, @"globe", NO),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyAutoClearCache, FBPL(@"row.autoclear.title"), nil, @"arrow.triangle.2.circlepath"),
                FBPActionRow(kActionClearCache, FBPL(@"row.clearcache.title"), nil, @"trash.fill", NO),
                FBPActionRow(kActionCheckUpdate, FBPL(@"row.checkupdate.title"), FBPL(@"row.checkupdate.desc"), @"arrow.down.circle", NO),
            ]),
            FBPSection(nil, @[
                FBPActionRow(kActionWelcome, FBPL(@"row.welcome.title"), nil, @"hand.wave.fill", NO),
                FBPActionRow(kActionReset, FBPL(@"row.reset.title"), nil, @"arrow.counterclockwise", YES),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.logs.title"), kRowDesc : FBPL(@"cat.logs.summary"),
           kRowIcon : @"ladybug.fill", kRowCategory : @[
            FBPSection(nil, @[
                FBPInfoRow(FBPL(@"logs.recordedlines"),
                           [NSString stringWithFormat:@"%lu", (unsigned long)FBPLogLineCount()],
                           @"doc.text", nil),
                FBPSwitchRow(FBPKeyLogsKeep, FBPL(@"row.logskeep.title"),
                             FBPL(@"row.logskeep.desc"), @"tray.and.arrow.down.fill"),
            ]),
            FBPSection(nil, @[
                FBPActionRow(kActionLogExport, FBPL(@"row.logexport.title"),
                             FBPL(@"row.logexport.desc"), @"square.and.arrow.up", NO),
                FBPActionRow(kActionLogClear, FBPL(@"row.logclear.title"),
                             FBPL(@"row.logclear.desc"), @"trash.fill", NO),
            ]),
        ]},
    ];
}

#pragma mark - Category detail page

@interface FBPSettingsDetailController : FBPTableController
- (instancetype)initWithCategory:(NSDictionary *)category;
@end

@implementation FBPSettingsDetailController {
    NSDictionary *_category;
    NSArray<NSDictionary *> *_sections;
}

- (instancetype)initWithCategory:(NSDictionary *)category {
    if ((self = [super init])) {
        _category = category;
        _sections = category[kRowCategory];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _category[kRowTitle];
}

- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)section {
    return _sections[section][kSecRows];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowsInSection:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[section][kSecFooter];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier forIndexPath:indexPath];
    [self configureCell:cell withRow:[self rowsInSection:indexPath.section][indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowsInSection:indexPath.section][indexPath.row];
    if (![row[kRowType] isEqualToString:kTypeAction]) return;
    // A frozen row already refuses the touch through userInteractionEnabled;
    // this is the guard for anything that reaches the delegate another way,
    // such as a keyboard or accessibility activation.
    if ([row[kRowDisabled] boolValue]) return;
    NSString *action = row[kRowKey];

    if ([action isEqualToString:kActionClearCache]) {
        [self clearCache];
    } else if ([action isEqualToString:kActionAppIcon]) {
        [self.navigationController pushViewController:[[FBPAppIconController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionFonts]) {
        [self.navigationController pushViewController:[[FBPFontController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionLanguage]) {
        [self.navigationController pushViewController:[[FBPLanguageController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionDownloads]) {
        [self.navigationController
            pushViewController:[[FBPDownloadManagerController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionCheckUpdate]) {
        [FBPUpdateChecker checkManuallyFromViewController:self];
    } else if ([action isEqualToString:kActionWelcome]) {
        [self dismissViewControllerAnimated:YES completion:^{ [FBPWelcomeController present]; }];
    } else if ([action isEqualToString:kActionReset]) {
        [self confirmReset];
    } else if ([action isEqualToString:kActionLogExport]) {
        [self exportLogs];
    } else if ([action isEqualToString:kActionLogClear]) {
        FBPLogClear();
        // Rebuild the page so the "Recorded Lines" row drops to 0 at once, instead
        // of showing the pre-clear count until the user leaves and comes back.
        [self reloadCurrentCategory];
        [FBPToastManager.shared showMessage:FBPL(@"toast.logCleared") success:YES];
    } else if ([action isEqualToString:kActionPlusMode]) {
        [self presentPlusModePicker];
    }
}

// Action sheet to pick the Facebook Plus unlock method. "Direct" forces the
// reveal gate outright; "Trial" makes the app believe an active trial is running.
- (void)presentPlusModePicker {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:FBPL(@"row.plusmode.title")
                         message:FBPL(@"row.plusmode.desc")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    void (^choose)(NSString *) = ^(NSString *mode) {
        [FBPPrefs.shared setString:mode forKey:FBPKeyMetaPlusMode];
        [FBPPrefs.shared commit];
        [self reloadCurrentCategory];
    };
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"row.plusmode.direct")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { choose(@"direct"); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"row.plusmode.trial")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { choose(@"trial"); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.view.tintColor = UIColor.systemBlueColor;

    // iPad: anchor the popover to the centre of the screen so it does not crash
    // for want of a source view.
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    [self presentViewController:sheet animated:YES completion:nil];
}

// Re-reads the live category (FBPCategories rebuilds each call, so dynamic row
// values like the recorded-line count are recomputed) and reloads the table.
- (void)reloadCurrentCategory {
    NSString *icon = _category[kRowIcon];
    for (NSDictionary *category in FBPCategories()) {
        if ([category[kRowIcon] isEqualToString:icon]) {
            _category = category;
            _sections = category[kRowCategory];
            break;
        }
    }
    [self.tableView reloadData];
}

// Re-localize when returning from a pushed page (e.g. the language picker).
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *icon = _category[kRowIcon];
    for (NSDictionary *category in FBPCategories()) {
        if ([category[kRowIcon] isEqualToString:icon]) {
            _category = category;
            _sections = category[kRowCategory];
            break;
        }
    }
    self.title = _category[kRowTitle];
    [self.tableView reloadData];
}

#pragma mark Actions

// Write the in-memory diagnostic log to a text file and hand it to the share
// sheet, so a bug report can carry it.
- (void)exportLogs {
    if (FBPLogLineCount() == 0) {
        [FBPToastManager.shared showMessage:FBPL(@"toast.logEmpty") success:NO];
        return;
    }
    NSURL *file = FBPLogWriteExportFile();
    if (!file) {
        [FBPToastManager.shared showMessage:FBPL(@"toast.logEmpty") success:NO];
        return;
    }
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"reset.title")
                                            message:FBPL(@"reset.message")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"reset.confirm")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [FBPPrefs.shared resetToDefaults];
        [self.tableView reloadData];
        [FBPToastManager.shared showMessage:FBPL(@"toast.settingsReset") success:YES];
    }]];
    alert.view.tintColor = FBPTintColor();
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearCache {
    [FBPCacheCleaner clearAllCachesWithCompletion:^(unsigned long long bytesFreed) {
        NSString *msg = bytesFreed > 0
            ? [NSString stringWithFormat:@"%@ (%@)", FBPL(@"toast.cacheCleared"), [FBPCacheCleaner formattedByteSize:bytesFreed]]
            : FBPL(@"toast.cacheCleared");
        [FBPToastManager.shared showMessage:msg success:YES];
    }];
}

@end

#pragma mark - Top-level menu

@interface FBPSettingsMenuController : FBPTableController
@end

@implementation FBPSettingsMenuController {
    NSArray<NSDictionary *> *_categories;
    NSArray<NSArray<NSDictionary *> *> *_sections;  // menu sections of rows
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FBPL(@"nav.settings");
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(dismissSettings)];
    self.navigationItem.leftBarButtonItem.tintColor = FBPTintColor();
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
    [self.tableView reloadData];
}

- (void)rebuild {
    _categories = FBPCategories();

    NSMutableArray *categoryRows = [NSMutableArray array];
    for (NSDictionary *category in _categories) {
        [categoryRows addObject:@{
            kRowType : kTypeCategory,
            kRowTitle : category[kRowTitle],
            kRowDesc : category[kRowDesc],
            kRowIcon : category[kRowIcon],
            kRowCategory : category[kRowCategory],
        }];
    }

    // Both versions are auto-detected, never hardcoded: Facebook's from the host
    // app's Info.plist (its full FBAppVersion, falling back to the short version),
    // ours from the control file (via the FBP_VERSION macro).
    NSString *fbVersion =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"FBAppVersion"]
        ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
        ?: @"—";
    NSString *plusVersion = FBP_VERSION;
    NSString *osVersion = [NSString stringWithFormat:@"%@ %@",
                           UIDevice.currentDevice.systemName,
                           UIDevice.currentDevice.systemVersion];

    _sections = @[
        categoryRows,
        // One about card: who made it, where to reach it, and the versions and
        // device a bug report needs.
        @[
            FBPInfoRow(FBPL(@"info.developer"), @"S. SHAJON", @"people", nil),
            FBPInfoRow(FBPL(@"info.github"), [FBPUpdateChecker activeGitHubOwner], @"github",
                       [FBPUpdateChecker githubRepoURL]),
            FBPInfoRow(FBPL(@"info.telegram"), @"@ReFacebookPlus", @"telegram", kTelegramURL),
            FBPInfoRow(FBPL(@"info.fbPlusVersion"), plusVersion, @"logo", nil),
            FBPInfoRow(FBPL(@"info.fbVersion"), fbVersion, @"facebook", nil),
            FBPInfoRow(FBPL(@"info.iosVersion"), osVersion, @"gear", nil),
            FBPInfoRow(FBPL(@"info.deviceName"), FBPDeviceDisplayName(), @"iphone", nil),
        ],
        // Several options only take effect on a fresh launch, so this sits right
        // under the info cards as the one-tap way to force-close the app.
        @[
            FBPActionRow(kActionSuspend, FBPL(@"row.suspend.title"), FBPL(@"row.suspend.desc"),
                         @"power", NO),
        ],
    ];
}

- (void)dismissSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_sections[section].count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier forIndexPath:indexPath];
    [self configureCell:cell withRow:_sections[indexPath.section][indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];

    if ([row[kRowType] isEqualToString:kTypeCategory]) {
        [self.navigationController pushViewController:
            [[FBPSettingsDetailController alloc] initWithCategory:row] animated:YES];
        return;
    }
    if ([row[kRowKey] isEqualToString:kActionSuspend]) {
        [self suspendApp];
        return;
    }
    NSString *link = row[kRowLink];
    if (link.length) {
        NSURL *url = [NSURL URLWithString:link];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

/// Force-closes Facebook: suspends it to the background (so it animates away
/// like a normal home-button exit rather than vanishing), then terminates the
/// process. Reopening the app from the home screen gives a clean, fresh launch
/// that applies any options which only take effect at startup.
- (void)suspendApp {
    UIApplication *app = UIApplication.sharedApplication;
    if ([app respondsToSelector:@selector(suspend)]) {
        [app performSelector:@selector(suspend)];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

@end

#pragma mark - Public entry

@implementation FBPSettingsController

+ (void)presentFromViewController:(UIViewController *)viewController {
    UIViewController *host = viewController ?: [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) return;

    FBPSettingsMenuController *menu = [[FBPSettingsMenuController alloc] init];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:menu];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // Paint the container black up front so the panel slides in already-dark —
    // otherwise the cards appear a frame before the background fills in.
    navigation.view.backgroundColor = FBPPanelColor();
    [host presentViewController:navigation animated:YES completion:nil];
}

@end
