// Content-sized bottom sheet: lays out the action rows and a separate Cancel
// card, and runs each action's handler after dismissal.

#import "FBPSheet.h"
#import "FBPResources.h"

static NSString *const kActionCell = @"fbp.action";
static NSString *const kCancelCell = @"fbp.cancel";

static const CGFloat kRowHeight    = 62.0;
static const CGFloat kCancelHeight = 56.0;
static const CGFloat kHeaderHeight = 44.0;

/// Row with the two text lines in either order, and an optional badge capsule
/// beside the title.
///
/// The lines live in a vertical stack so the order is a one-line change at
/// configure time rather than two sets of constraints. The stack is pinned at
/// the same inset, with the same spacing, as the hand-built layout it replaced,
/// so a caller that does not ask for the new order renders identically.
@interface FBPSheetCell : UITableViewCell
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, strong) UILabel *detailLine;
@property (nonatomic, strong) UILabel *titleLine;
/// Capsule holding @c badgeLabel. Hidden unless the action set a badge.
@property (nonatomic, strong) UIView *badgeView;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIStackView *lineStack;
- (void)setTitleFirst:(BOOL)titleFirst;
@end

@implementation FBPSheetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;

        _glyphView = [[UIImageView alloc] init];
        _glyphView.contentMode = UIViewContentModeScaleAspectFit;
        _glyphView.tintColor = UIColor.labelColor;
        _glyphView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_glyphView];

        _detailLine = [[UILabel alloc] init];
        _detailLine.font = [UIFont systemFontOfSize:13];
        _detailLine.textColor = UIColor.secondaryLabelColor;

        _titleLine = [[UILabel alloc] init];
        _titleLine.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
        _titleLine.textColor = UIColor.labelColor;

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _badgeLabel.textColor = FBPTintColor();
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _badgeView = [[UIView alloc] init];
        _badgeView.backgroundColor = [FBPTintColor() colorWithAlphaComponent:0.18];
        _badgeView.layer.cornerRadius = 8.0;
        _badgeView.layer.cornerCurve = kCACornerCurveContinuous;
        _badgeView.translatesAutoresizingMaskIntoConstraints = NO;
        [_badgeView addSubview:_badgeLabel];

        // Title and badge share a row; the trailing spacer keeps the capsule
        // tight against the title instead of stretched across the cell.
        UIView *spacer = [[UIView alloc] init];
        [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                                  forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *titleRow =
            [[UIStackView alloc] initWithArrangedSubviews:@[_titleLine, _badgeView, spacer]];
        titleRow.axis = UILayoutConstraintAxisHorizontal;
        titleRow.alignment = UIStackViewAlignmentCenter;
        titleRow.spacing = 8;

        _lineStack = [[UIStackView alloc] initWithArrangedSubviews:@[_detailLine, titleRow]];
        _lineStack.axis = UILayoutConstraintAxisVertical;
        _lineStack.alignment = UIStackViewAlignmentFill;
        _lineStack.spacing = 2;
        _lineStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_lineStack];

        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
        self.selectedBackgroundView = selected;

        [NSLayoutConstraint activateConstraints:@[
            [_glyphView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                     constant:16],
            [_glyphView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_glyphView.widthAnchor constraintEqualToConstant:26],
            [_glyphView.heightAnchor constraintEqualToConstant:26],

            [_badgeLabel.leadingAnchor constraintEqualToAnchor:_badgeView.leadingAnchor
                                                      constant:7],
            [_badgeLabel.trailingAnchor constraintEqualToAnchor:_badgeView.trailingAnchor
                                                       constant:-7],
            [_badgeLabel.topAnchor constraintEqualToAnchor:_badgeView.topAnchor constant:2],
            [_badgeLabel.bottomAnchor constraintEqualToAnchor:_badgeView.bottomAnchor
                                                     constant:-2],

            [_lineStack.leadingAnchor constraintEqualToAnchor:_glyphView.trailingAnchor
                                                     constant:14],
            [_lineStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                      constant:-16],
            [_lineStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                 constant:10],
        ]];
    }
    return self;
}

/// Reorder the two lines. Cheap enough to call on every configure, and a no-op
/// when the order already matches.
- (void)setTitleFirst:(BOOL)titleFirst {
    BOOL alreadyTitleFirst = (self.lineStack.arrangedSubviews.firstObject != self.detailLine);
    if (alreadyTitleFirst == titleFirst) return;

    // Exactly two rows, so promoting the last one to the front is the swap.
    UIView *moving = self.lineStack.arrangedSubviews.lastObject;
    if (!moving) return;
    [self.lineStack removeArrangedSubview:moving];
    [self.lineStack insertArrangedSubview:moving atIndex:0];
}

@end

@interface FBPSheetController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<FBPSheetAction *> *actions;
@property (nonatomic, copy, nullable) NSString *sheetTitle;
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation FBPSheetController

- (instancetype)initWithActions:(NSArray<FBPSheetAction *> *)actions
                          title:(NSString *)title {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _actions = [actions copy];
        _sheetTitle = [title copy];
    }
    return self;
}

- (CGFloat)preferredSheetHeight {
    CGFloat header = self.sheetTitle.length ? kHeaderHeight : 12.0;
    // actions card + spacing + cancel card + bottom safe area
    return header + (kRowHeight * self.actions.count) + 24.0 + kCancelHeight + 48.0;
}

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:backdrop];
    [self.view sendSubviewToBack:backdrop];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStyleInsetGrouped];
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.showsVerticalScrollIndicator = NO;
    _tableView.alwaysBounceVertical = NO;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [_tableView registerClass:FBPSheetCell.class forCellReuseIdentifier:kActionCell];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // actions, then Cancel in its own card
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.actions.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? self.sheetTitle : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? kRowHeight : kCancelHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:kCancelCell];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kCancelCell];
            cell.backgroundColor = UIColor.clearColor;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        }
        cell.textLabel.text = @"Cancel";
        cell.textLabel.textColor = UIColor.labelColor;
        return cell;
    }

    FBPSheetCell *cell = [tableView dequeueReusableCellWithIdentifier:kActionCell
                                                        forIndexPath:indexPath];
    FBPSheetAction *action = self.actions[indexPath.row];
    cell.titleLine.text = action.title;
    cell.detailLine.text = action.detail;
    cell.detailLine.hidden = (action.detail.length == 0);
    cell.badgeLabel.text = action.badge;
    cell.badgeView.hidden = (action.badge.length == 0);
    [cell setTitleFirst:action.titleFirst];
    cell.glyphView.image = action.iconName
        ? [UIImage fbp_symbolNamed:action.iconName size:22]
        : nil;

    UIColor *tint = action.destructive ? UIColor.systemRedColor : UIColor.labelColor;
    cell.titleLine.textColor = tint;
    cell.glyphView.tintColor = tint;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    dispatch_block_t handler = nil;
    if (indexPath.section == 0) handler = self.actions[indexPath.row].handler;

    // Run the handler after dismissal so anything it presents has a free stack.
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler();
    }];
}

@end
