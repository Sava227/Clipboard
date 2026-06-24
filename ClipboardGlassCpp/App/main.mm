#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

#include "../Core/ClipboardHistory.hpp"

#include <algorithm>
#include <memory>
#include <optional>

static NSString *NSStringFromStdString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

static std::string StdStringFromNSString(NSString *value) {
    return value ? std::string([value UTF8String]) : std::string();
}

static NSString *HumanTime(std::int64_t unixTime) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:static_cast<NSTimeInterval>(unixTime)];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

static NSString * const ClipboardHistoryEnabledKey = @"ClipboardHistoryEnabled";
static NSString * const ClipboardHotKeyCodeKey = @"ClipboardHotKeyCode";
static NSString * const ClipboardHotKeyModifiersKey = @"ClipboardHotKeyModifiers";

static NSString *DecodeHTMLEntities(NSString *value) {
    return [[[[value stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"]
        stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"]
        stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""]
        stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

static UInt32 CarbonModifiersFromEventFlags(NSEventModifierFlags flags) {
    UInt32 modifiers = 0;
    if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
    if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
    if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
    if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
    return modifiers;
}

static NSString *ShortcutModifierString(UInt32 modifiers) {
    NSMutableString *result = [NSMutableString string];
    if (modifiers & controlKey) [result appendString:@"⌃"];
    if (modifiers & optionKey) [result appendString:@"⌥"];
    if (modifiers & shiftKey) [result appendString:@"⇧"];
    if (modifiers & cmdKey) [result appendString:@"⌘"];
    return result;
}

static NSString *KeyNameForKeyCode(UInt32 keyCode) {
    switch (keyCode) {
        case kVK_ANSI_A: return @"A";
        case kVK_ANSI_B: return @"B";
        case kVK_ANSI_C: return @"C";
        case kVK_ANSI_D: return @"D";
        case kVK_ANSI_E: return @"E";
        case kVK_ANSI_F: return @"F";
        case kVK_ANSI_G: return @"G";
        case kVK_ANSI_H: return @"H";
        case kVK_ANSI_I: return @"I";
        case kVK_ANSI_J: return @"J";
        case kVK_ANSI_K: return @"K";
        case kVK_ANSI_L: return @"L";
        case kVK_ANSI_M: return @"M";
        case kVK_ANSI_N: return @"N";
        case kVK_ANSI_O: return @"O";
        case kVK_ANSI_P: return @"P";
        case kVK_ANSI_Q: return @"Q";
        case kVK_ANSI_R: return @"R";
        case kVK_ANSI_S: return @"S";
        case kVK_ANSI_T: return @"T";
        case kVK_ANSI_U: return @"U";
        case kVK_ANSI_V: return @"V";
        case kVK_ANSI_W: return @"W";
        case kVK_ANSI_X: return @"X";
        case kVK_ANSI_Y: return @"Y";
        case kVK_ANSI_Z: return @"Z";
        case kVK_ANSI_0: return @"0";
        case kVK_ANSI_1: return @"1";
        case kVK_ANSI_2: return @"2";
        case kVK_ANSI_3: return @"3";
        case kVK_ANSI_4: return @"4";
        case kVK_ANSI_5: return @"5";
        case kVK_ANSI_6: return @"6";
        case kVK_ANSI_7: return @"7";
        case kVK_ANSI_8: return @"8";
        case kVK_ANSI_9: return @"9";
        case kVK_Space: return @"Space";
        case kVK_Escape: return @"Esc";
        case kVK_Return: return @"Return";
        case kVK_Tab: return @"Tab";
        case kVK_Delete: return @"Delete";
        case kVK_UpArrow: return @"↑";
        case kVK_DownArrow: return @"↓";
        case kVK_LeftArrow: return @"←";
        case kVK_RightArrow: return @"→";
        default: return [NSString stringWithFormat:@"Key %u", keyCode];
    }
}

static NSData *PNGDataFromImage(NSImage *image, CGFloat maxSide) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) {
        return nil;
    }

    CGFloat scale = MIN(1.0, maxSide / MAX(image.size.width, image.size.height));
    NSSize targetSize = NSMakeSize(MAX(1.0, image.size.width * scale), MAX(1.0, image.size.height * scale));
    NSImage *thumbnail = [[NSImage alloc] initWithSize:targetSize];
    [thumbnail lockFocus];
    [image drawInRect:NSMakeRect(0, 0, targetSize.width, targetSize.height)
             fromRect:NSZeroRect
            operation:NSCompositingOperationCopy
             fraction:1.0];
    [thumbnail unlockFocus];

    NSData *tiffData = thumbnail.TIFFRepresentation;
    if (!tiffData) {
        return nil;
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:tiffData];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static BOOL FileURLLooksLikeImage(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"heif", @"tif", @"tiff", @"bmp", @"webp"]];
    return [imageExtensions containsObject:extension];
}

@interface ClipboardRowView : NSTableCellView
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSImageView *pinView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *previewLabel;
@property(nonatomic, strong) NSTextField *metaLabel;
@end

@implementation ClipboardRowView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold];
    [self addSubview:_iconView];

    _pinView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _pinView.translatesAutoresizingMaskIntoConstraints = NO;
    _pinView.image = [NSImage imageWithSystemSymbolName:@"pin.fill" accessibilityDescription:@"Pinned"];
    _pinView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    _pinView.contentTintColor = NSColor.systemBlueColor;
    _pinView.hidden = YES;
    [self addSubview:_pinView];

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    _previewLabel = [NSTextField labelWithString:@""];
    _previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _previewLabel.font = [NSFont systemFontOfSize:12];
    _previewLabel.textColor = NSColor.secondaryLabelColor;
    _previewLabel.maximumNumberOfLines = 2;
    [self addSubview:_previewLabel];

    _metaLabel = [NSTextField labelWithString:@""];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metaLabel.font = [NSFont systemFontOfSize:10];
    _metaLabel.textColor = NSColor.tertiaryLabelColor;
    [self addSubview:_metaLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:36],
        [_iconView.heightAnchor constraintEqualToConstant:36],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_pinView.leadingAnchor constant:-8],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],

        [_pinView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [_pinView.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_pinView.widthAnchor constraintEqualToConstant:16],
        [_pinView.heightAnchor constraintEqualToConstant:16],

        [_previewLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_previewLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_previewLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],

        [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_metaLabel.topAnchor constraintEqualToAnchor:_previewLabel.bottomAnchor constant:4]
    ]];

    return self;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    NSWindow *_window;
    NSTableView *_tableView;
    NSSearchField *_searchField;
    NSSegmentedControl *_filterControl;
    NSView *_emptyStateView;
    NSScrollView *_historyScrollView;
    NSView *_quickInsertView;
    NSStackView *_quickInsertStack;
    NSTextField *_quickInsertTitle;
    NSBox *_tabUnderline;
    NSLayoutConstraint *_tabUnderlineCenterXConstraint;
    NSMutableArray<NSButton *> *_tabButtons;
    NSButton *_pinnedFilterButton;
    NSTextField *_emptyHeadlineLabel;
    NSTextField *_emptyBodyLabel;
    NSButton *_turnOnButton;
    NSTextView *_detailTextView;
    NSImageView *_detailImageView;
    NSTextField *_detailTitleLabel;
    NSTextField *_detailMetaLabel;
    NSTimer *_pasteboardTimer;
    NSInteger _lastChangeCount;
    std::unique_ptr<ClipboardHistory> _history;
    std::vector<ClipboardItem> _visibleItems;
    std::optional<ClipboardKind> _selectedKind;
    NSInteger _activeTab;
    BOOL _historyEnabled;
    BOOL _showPinnedOnly;
    NSRunningApplication *_previousApplication;
    EventHotKeyRef _hotKeyRef;
    EventHandlerRef _eventHandlerRef;
    UInt32 _hotKeyCode;
    UInt32 _hotKeyModifiers;
    id _hotKeyRecorderMonitor;
    NSAlert *_hotKeyRecorderAlert;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSString *supportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ClipboardGlassCpp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *historyPath = [supportPath stringByAppendingPathComponent:@"history.tsv"];
    _history = std::make_unique<ClipboardHistory>(StdStringFromNSString(historyPath));
    _history->load();
    _historyEnabled = [NSUserDefaults.standardUserDefaults boolForKey:ClipboardHistoryEnabledKey];
    _activeTab = 0;
    _showPinnedOnly = NO;

    _lastChangeCount = NSPasteboard.generalPasteboard.changeCount;
    [self configureStatusItem];
    [self buildWindow];
    [self loadHotKeySettings];
    [self registerHotKey];
    [self refreshVisibleItems];
    [self showWindow:nil];

    _pasteboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.55 target:self selector:@selector(checkPasteboard) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_pasteboardTimer invalidate];
    if (_hotKeyRef) UnregisterEventHotKey(_hotKeyRef);
    if (_eventHandlerRef) RemoveEventHandler(_eventHandlerRef);
}

- (void)configureStatusItem {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = [NSImage imageWithSystemSymbolName:@"doc.on.clipboard" accessibilityDescription:@"Clipboard Glass"];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Clipboard Glass"];
    [menu addItemWithTitle:@"Show Clipboard" action:@selector(showWindow:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Toggle Clipboard History" action:@selector(toggleClipboardHistory:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Clear Unpinned History" action:@selector(clearUnpinned:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Clear All History" action:@selector(clearAllHistory:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Clipboard Glass" action:@selector(terminate:) keyEquivalent:@"q"];
    _statusItem.menu = menu;
}

- (NSMenu *)historyContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Clipboard Item"];
    menu.delegate = self;
    [menu addItemWithTitle:@"Edit" action:@selector(editSelectedItem:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Pin" action:@selector(toggleSelectedPinned:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Remove" action:@selector(deleteSelectedItem:) keyEquivalent:@""].target = self;
    return menu;
}

- (void)buildWindow {
    const NSSize panelSize = NSMakeSize(348, 420);
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, panelSize.width, panelSize.height)
                                         styleMask:NSWindowStyleMaskBorderless
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    _window.title = @"";
    _window.movableByWindowBackground = YES;
    _window.minSize = panelSize;
    _window.maxSize = panelSize;
    _window.opaque = NO;
    _window.backgroundColor = NSColor.clearColor;
    _window.level = NSFloatingWindowLevel;
    _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorManaged;
    _window.delegate = self;
    _window.hasShadow = YES;

    [_window standardWindowButton:NSWindowCloseButton].hidden = YES;
    [_window standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [_window standardWindowButton:NSWindowZoomButton].hidden = YES;

    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    root.wantsLayer = YES;
    root.layer.cornerRadius = 18;
    root.layer.masksToBounds = YES;
    root.layer.borderWidth = 1.5;
    root.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.78].CGColor;
    _window.contentView = root;

    NSBox *grabHandle = [[NSBox alloc] initWithFrame:NSZeroRect];
    grabHandle.translatesAutoresizingMaskIntoConstraints = NO;
    grabHandle.boxType = NSBoxCustom;
    grabHandle.transparent = NO;
    grabHandle.fillColor = [NSColor colorWithWhite:0.18 alpha:0.72];
    grabHandle.cornerRadius = 1.5;
    [root addSubview:grabHandle];

    NSButton *closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"] target:self action:@selector(closePanel:)];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.bezelStyle = NSBezelStyleInline;
    closeButton.bordered = NO;
    closeButton.imageScaling = NSImageScaleProportionallyDown;
    [root addSubview:closeButton];

    NSButton *settingsButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings"] target:self action:@selector(showSettings:)];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    settingsButton.bezelStyle = NSBezelStyleInline;
    settingsButton.bordered = NO;
    settingsButton.imageScaling = NSImageScaleProportionallyDown;
    [root addSubview:settingsButton];

    NSStackView *tabBar = [[NSStackView alloc] initWithFrame:NSZeroRect];
    tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    tabBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    tabBar.alignment = NSLayoutAttributeCenterY;
    tabBar.distribution = NSStackViewDistributionEqualSpacing;
    tabBar.spacing = 20;
    [root addSubview:tabBar];
    _tabButtons = [NSMutableArray array];

    NSTextField *comingSoonLabel = [NSTextField labelWithString:@"Coming soon"];
    comingSoonLabel.translatesAutoresizingMaskIntoConstraints = NO;
    comingSoonLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    comingSoonLabel.textColor = NSColor.secondaryLabelColor;
    comingSoonLabel.alignment = NSTextAlignmentCenter;
    [root addSubview:comingSoonLabel];

    NSArray<NSDictionary *> *tabs = @[
        @{@"symbol": @"list.clipboard", @"tag": @0, @"tooltip": @"Clipboard history"}
    ];

    for (NSDictionary *tab in tabs) {
        NSButton *button;
        if (tab[@"symbol"]) {
            button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:tab[@"symbol"] accessibilityDescription:nil] target:self action:@selector(tabButtonPressed:)];
            button.imageScaling = NSImageScaleProportionallyDown;
        } else {
            button = [NSButton buttonWithTitle:tab[@"title"] target:self action:@selector(tabButtonPressed:)];
            button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        }
        button.tag = [tab[@"tag"] integerValue];
        button.toolTip = tab[@"tooltip"];
        button.bezelStyle = NSBezelStyleInline;
        button.bordered = NO;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [tabBar addArrangedSubview:button];
        [_tabButtons addObject:button];
        [button.widthAnchor constraintEqualToConstant:24].active = YES;
        [button.heightAnchor constraintEqualToConstant:24].active = YES;
    }

    _tabUnderline = [[NSBox alloc] initWithFrame:NSZeroRect];
    _tabUnderline.translatesAutoresizingMaskIntoConstraints = NO;
    _tabUnderline.boxType = NSBoxCustom;
    _tabUnderline.transparent = NO;
    _tabUnderline.fillColor = [NSColor systemBlueColor];
    _tabUnderline.cornerRadius = 1.5;
    [root addSubview:_tabUnderline];

    NSTextField *sectionTitle = [NSTextField labelWithString:@"Clipboard"];
    sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    sectionTitle.font = [NSFont systemFontOfSize:16 weight:NSFontWeightRegular];
    sectionTitle.textColor = NSColor.labelColor;
    [root addSubview:sectionTitle];

    _pinnedFilterButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"pin" accessibilityDescription:@"Pinned items"] target:self action:@selector(togglePinnedFilter:)];
    _pinnedFilterButton.translatesAutoresizingMaskIntoConstraints = NO;
    _pinnedFilterButton.bezelStyle = NSBezelStyleInline;
    _pinnedFilterButton.bordered = NO;
    _pinnedFilterButton.imageScaling = NSImageScaleProportionallyDown;
    _pinnedFilterButton.toolTip = @"Show pinned only";
    [root addSubview:_pinnedFilterButton];

    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.hidden = YES;
    _searchField.delegate = self;

    _historyScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _historyScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _historyScrollView.hasVerticalScroller = YES;
    _historyScrollView.hasHorizontalScroller = NO;
    _historyScrollView.autohidesScrollers = YES;
    _historyScrollView.drawsBackground = NO;
    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.headerView = nil;
    _tableView.rowHeight = 70;
    _tableView.backgroundColor = NSColor.clearColor;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.allowsEmptySelection = NO;
    _tableView.target = self;
    _tableView.action = @selector(tableRowClicked:);
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"history"];
    column.width = 340;
    [_tableView addTableColumn:column];
    _historyScrollView.documentView = _tableView;
    [_tableView.widthAnchor constraintEqualToAnchor:_historyScrollView.contentView.widthAnchor].active = YES;
    _tableView.menu = [self historyContextMenu];
    [root addSubview:_historyScrollView];

    _quickInsertView = [[NSView alloc] initWithFrame:NSZeroRect];
    _quickInsertView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_quickInsertView];

    _quickInsertTitle = [NSTextField labelWithString:@""];
    _quickInsertTitle.translatesAutoresizingMaskIntoConstraints = NO;
    _quickInsertTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    [_quickInsertView addSubview:_quickInsertTitle];

    _quickInsertStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _quickInsertStack.translatesAutoresizingMaskIntoConstraints = NO;
    _quickInsertStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _quickInsertStack.spacing = 10;
    [_quickInsertView addSubview:_quickInsertStack];

    _emptyStateView = [[NSView alloc] initWithFrame:NSZeroRect];
    _emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_emptyStateView];

    _emptyHeadlineLabel = [NSTextField labelWithString:@"Let's get started"];
    _emptyHeadlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyHeadlineLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightBold];
    _emptyHeadlineLabel.alignment = NSTextAlignmentCenter;
    [_emptyStateView addSubview:_emptyHeadlineLabel];

    _emptyBodyLabel = [NSTextField wrappingLabelWithString:@"Turn on clipboard history to\ncopy and view multiple items."];
    _emptyBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyBodyLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    _emptyBodyLabel.textColor = NSColor.labelColor;
    _emptyBodyLabel.alignment = NSTextAlignmentCenter;
    [_emptyStateView addSubview:_emptyBodyLabel];

    _turnOnButton = [NSButton buttonWithTitle:@"Turn on" target:self action:@selector(turnOnClipboardHistory:)];
    _turnOnButton.translatesAutoresizingMaskIntoConstraints = NO;
    _turnOnButton.bezelStyle = NSBezelStyleRounded;
    _turnOnButton.font = [NSFont systemFontOfSize:15 weight:NSFontWeightRegular];
    _turnOnButton.contentTintColor = NSColor.labelColor;
    [_emptyStateView addSubview:_turnOnButton];

    _tabUnderlineCenterXConstraint = [_tabUnderline.centerXAnchor constraintEqualToAnchor:_tabButtons.lastObject.centerXAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [grabHandle.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [grabHandle.topAnchor constraintEqualToAnchor:root.topAnchor constant:17],
        [grabHandle.widthAnchor constraintEqualToConstant:34],
        [grabHandle.heightAnchor constraintEqualToConstant:3],

        [closeButton.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [closeButton.topAnchor constraintEqualToAnchor:root.topAnchor constant:11],
        [closeButton.widthAnchor constraintEqualToConstant:24],
        [closeButton.heightAnchor constraintEqualToConstant:24],

        [settingsButton.trailingAnchor constraintEqualToAnchor:closeButton.leadingAnchor constant:-8],
        [settingsButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [settingsButton.widthAnchor constraintEqualToConstant:24],
        [settingsButton.heightAnchor constraintEqualToConstant:24],

        [comingSoonLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:31],
        [comingSoonLabel.topAnchor constraintEqualToAnchor:root.topAnchor constant:59],
        [comingSoonLabel.widthAnchor constraintEqualToConstant:180],
        [comingSoonLabel.heightAnchor constraintEqualToConstant:22],

        [tabBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-87],
        [tabBar.topAnchor constraintEqualToAnchor:root.topAnchor constant:56],
        [tabBar.widthAnchor constraintEqualToConstant:24],
        [tabBar.heightAnchor constraintEqualToConstant:26],

        [_tabUnderline.topAnchor constraintEqualToAnchor:tabBar.bottomAnchor constant:8],
        _tabUnderlineCenterXConstraint,
        [_tabUnderline.widthAnchor constraintEqualToConstant:16],
        [_tabUnderline.heightAnchor constraintEqualToConstant:3],

        [_pinnedFilterButton.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:17],
        [_pinnedFilterButton.centerYAnchor constraintEqualToAnchor:sectionTitle.centerYAnchor],
        [_pinnedFilterButton.widthAnchor constraintEqualToConstant:22],
        [_pinnedFilterButton.heightAnchor constraintEqualToConstant:22],

        [sectionTitle.leadingAnchor constraintEqualToAnchor:_pinnedFilterButton.trailingAnchor constant:8],
        [sectionTitle.topAnchor constraintEqualToAnchor:_tabUnderline.bottomAnchor constant:27],

        [_historyScrollView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14],
        [_historyScrollView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [_historyScrollView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:14],
        [_historyScrollView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],

        [_quickInsertView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:18],
        [_quickInsertView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-18],
        [_quickInsertView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:16],
        [_quickInsertView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],

        [_quickInsertTitle.leadingAnchor constraintEqualToAnchor:_quickInsertView.leadingAnchor],
        [_quickInsertTitle.trailingAnchor constraintEqualToAnchor:_quickInsertView.trailingAnchor],
        [_quickInsertTitle.topAnchor constraintEqualToAnchor:_quickInsertView.topAnchor],

        [_quickInsertStack.leadingAnchor constraintEqualToAnchor:_quickInsertView.leadingAnchor],
        [_quickInsertStack.trailingAnchor constraintEqualToAnchor:_quickInsertView.trailingAnchor],
        [_quickInsertStack.topAnchor constraintEqualToAnchor:_quickInsertTitle.bottomAnchor constant:14],

        [_emptyStateView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_emptyStateView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_emptyStateView.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:24],
        [_emptyStateView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],

        [_emptyHeadlineLabel.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [_emptyHeadlineLabel.topAnchor constraintEqualToAnchor:_emptyStateView.topAnchor constant:74],

        [_emptyBodyLabel.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [_emptyBodyLabel.topAnchor constraintEqualToAnchor:_emptyHeadlineLabel.bottomAnchor constant:7],
        [_emptyBodyLabel.widthAnchor constraintEqualToConstant:240],

        [_turnOnButton.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [_turnOnButton.topAnchor constraintEqualToAnchor:_emptyBodyLabel.bottomAnchor constant:20],
        [_turnOnButton.widthAnchor constraintEqualToConstant:94],
        [_turnOnButton.heightAnchor constraintEqualToConstant:34]
    ]];

    [self updateActiveTabIndicator];
}

- (void)registerHotKey {
    if (_hotKeyRef) {
        UnregisterEventHotKey(_hotKeyRef);
        _hotKeyRef = nullptr;
    }

    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;

    if (!_eventHandlerRef) {
        __unsafe_unretained AppDelegate *delegate = self;
        InstallEventHandler(GetApplicationEventTarget(), [](EventHandlerCallRef, EventRef, void *userData) -> OSStatus {
            AppDelegate *target = (__bridge AppDelegate *)userData;
            [target showWindow:nil];
            return noErr;
        }, 1, &eventType, (__bridge void *)delegate, &_eventHandlerRef);
    }

    EventHotKeyID hotKeyID;
    hotKeyID.signature = 'CLPG';
    hotKeyID.id = 1;
    OSStatus status = RegisterEventHotKey(_hotKeyCode, _hotKeyModifiers, hotKeyID, GetApplicationEventTarget(), 0, &_hotKeyRef);
    if (status != noErr) {
        _hotKeyRef = nullptr;
    }
}

- (void)loadHotKeySettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:ClipboardHotKeyCodeKey] && [defaults objectForKey:ClipboardHotKeyModifiersKey]) {
        _hotKeyCode = static_cast<UInt32>([defaults integerForKey:ClipboardHotKeyCodeKey]);
        _hotKeyModifiers = static_cast<UInt32>([defaults integerForKey:ClipboardHotKeyModifiersKey]);
    } else {
        _hotKeyCode = kVK_ANSI_V;
        _hotKeyModifiers = cmdKey | shiftKey;
        [self saveHotKeySettings];
    }
}

- (void)saveHotKeySettings {
    [NSUserDefaults.standardUserDefaults setInteger:_hotKeyCode forKey:ClipboardHotKeyCodeKey];
    [NSUserDefaults.standardUserDefaults setInteger:_hotKeyModifiers forKey:ClipboardHotKeyModifiersKey];
}

- (NSString *)hotKeyDisplayString {
    return [NSString stringWithFormat:@"%@%@", ShortcutModifierString(_hotKeyModifiers), KeyNameForKeyCode(_hotKeyCode)];
}

- (void)showWindow:(id)sender {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (frontmost && frontmost.processIdentifier != NSRunningApplication.currentApplication.processIdentifier) {
        _previousApplication = frontmost;
    }

    [NSApp activate];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
}

- (void)closePanel:(id)sender {
    [_window orderOut:nil];
}

- (void)showSettings:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Settings"];
    [menu addItemWithTitle:(_historyEnabled ? @"Turn Clipboard History Off" : @"Turn Clipboard History On") action:@selector(toggleClipboardHistory:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *currentHotKey = [menu addItemWithTitle:[NSString stringWithFormat:@"Trigger Keys: %@", [self hotKeyDisplayString]] action:nil keyEquivalent:@""];
    currentHotKey.enabled = NO;
    [menu addItemWithTitle:@"Change Trigger Keys..." action:@selector(beginHotKeyRecording:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Clear Unpinned History" action:@selector(clearUnpinned:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Clear All History" action:@selector(clearAllHistory:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Clipboard Glass" action:@selector(terminate:) keyEquivalent:@""];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height + 4) inView:sender];
}

- (void)beginHotKeyRecording:(id)sender {
    [self endHotKeyRecording];

    _hotKeyRecorderAlert = [[NSAlert alloc] init];
    _hotKeyRecorderAlert.messageText = @"Press trigger keys";
    _hotKeyRecorderAlert.informativeText = @"Press the shortcut you want to use to show Clipboard Glass. Use at least one modifier like Command, Option, Control, or Shift.";
    [_hotKeyRecorderAlert addButtonWithTitle:@"Cancel"];

    NSTextField *currentShortcutLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Current: %@", [self hotKeyDisplayString]]];
    currentShortcutLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    currentShortcutLabel.alignment = NSTextAlignmentCenter;
    currentShortcutLabel.frame = NSMakeRect(0, 0, 260, 34);
    _hotKeyRecorderAlert.accessoryView = currentShortcutLabel;

    __weak AppDelegate *weakSelf = self;
    _hotKeyRecorderMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return event;
        return [strongSelf handleRecordedHotKeyEvent:event] ? nil : event;
    }];

    NSModalResponse response = [_hotKeyRecorderAlert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self endHotKeyRecording];
    }
}

- (BOOL)handleRecordedHotKeyEvent:(NSEvent *)event {
    if (event.keyCode == kVK_Escape) {
        [_hotKeyRecorderAlert.window close];
        [self endHotKeyRecording];
        return YES;
    }

    UInt32 modifiers = CarbonModifiersFromEventFlags(event.modifierFlags);
    if (modifiers == 0) {
        NSSound *sound = [NSSound soundNamed:@"Funk"];
        [sound play];
        return YES;
    }

    _hotKeyCode = static_cast<UInt32>(event.keyCode);
    _hotKeyModifiers = modifiers;
    [self saveHotKeySettings];
    [self registerHotKey];
    [_hotKeyRecorderAlert.window close];
    [self endHotKeyRecording];
    return YES;
}

- (void)endHotKeyRecording {
    if (_hotKeyRecorderMonitor) {
        [NSEvent removeMonitor:_hotKeyRecorderMonitor];
        _hotKeyRecorderMonitor = nil;
    }
    _hotKeyRecorderAlert = nil;
}

- (void)turnOnClipboardHistory:(id)sender {
    [self setClipboardHistoryEnabled:YES];
    [self captureCurrentPasteboard];
    [self refreshVisibleItems];
}

- (void)toggleClipboardHistory:(id)sender {
    [self setClipboardHistoryEnabled:!_historyEnabled];
    if (_historyEnabled) {
        [self captureCurrentPasteboard];
    }
    [self refreshVisibleItems];
}

- (void)setClipboardHistoryEnabled:(BOOL)enabled {
    _historyEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ClipboardHistoryEnabledKey];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self refreshVisibleItems];
}

- (void)filterChanged:(id)sender {
    switch (_filterControl.selectedSegment) {
        case 1: _selectedKind = ClipboardKind::Text; break;
        case 2: _selectedKind = ClipboardKind::Link; break;
        case 3: _selectedKind = ClipboardKind::Image; break;
        case 4: _selectedKind = ClipboardKind::File; break;
        default: _selectedKind = std::nullopt; break;
    }
    [self refreshVisibleItems];
}

- (void)tabButtonPressed:(NSButton *)sender {
    _activeTab = sender.tag;
    _selectedKind = std::nullopt;
    [self updateActiveTabIndicator];
    [self refreshVisibleItems];
}

- (void)togglePinnedFilter:(id)sender {
    _showPinnedOnly = !_showPinnedOnly;
    _pinnedFilterButton.image = [NSImage imageWithSystemSymbolName:(_showPinnedOnly ? @"pin.fill" : @"pin") accessibilityDescription:@"Pinned items"];
    _pinnedFilterButton.contentTintColor = _showPinnedOnly ? NSColor.systemBlueColor : NSColor.secondaryLabelColor;
    _pinnedFilterButton.toolTip = _showPinnedOnly ? @"Show all items" : @"Show pinned only";
    [self refreshVisibleItems];
}

- (void)updateActiveTabIndicator {
    if (_activeTab >= 0 && _activeTab < _tabButtons.count) {
        _tabUnderlineCenterXConstraint.active = NO;
        _tabUnderlineCenterXConstraint = [_tabUnderline.centerXAnchor constraintEqualToAnchor:_tabButtons[_activeTab].centerXAnchor];
        _tabUnderlineCenterXConstraint.active = YES;
    }

    for (NSButton *button in _tabButtons) {
        button.contentTintColor = button.tag == _activeTab ? NSColor.labelColor : NSColor.secondaryLabelColor;
    }
}

- (NSArray<NSString *> *)quickInsertItemsForActiveTab {
    switch (_activeTab) {
        case 0:
            return @[@"😀", @"😂", @"😍", @"🥹", @"😎", @"😭", @"😡", @"👍", @"🙏", @"👏", @"🔥", @"✨", @"❤️", @"💀", @"✅", @"🎉", @"💡", @"🚀"];
        case 1:
            return [self loadedKaomojiItems];
        case 2:
            return @[@"★", @"☆", @"✓", @"✕", @"→", @"←", @"↑", @"↓", @"•", @"∞", @"⌘", @"⌥", @"⇧", @"⌃", @"©", @"™", @"€", @"£"];
        default:
            return @[];
    }
}

- (NSArray<NSString *> *)loadedKaomojiItems {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    NSArray<NSString *> *categoryNames = @[@"smile", @"happy", @"wink", @"niconico", @"waruikao"];
    NSArray<NSString *> *searchRoots = @[
        NSBundle.mainBundle.resourcePath ?: @"",
        NSFileManager.defaultManager.currentDirectoryPath,
        @"/Users/sava/Desktop/Clipboard for mac"
    ];

    for (NSString *root in searchRoots) {
        if (items.count >= 30) break;

        NSString *base = [root stringByAppendingPathComponent:@"kaomoji-collection-main/categories"];
        for (NSString *category in categoryNames) {
            if (items.count >= 30) break;

            NSString *path = [base stringByAppendingPathComponent:[category stringByAppendingPathExtension:@"json"]];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data) continue;

            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:NSArray.class]) continue;

            for (NSString *raw in (NSArray *)json) {
                if (![raw isKindOfClass:NSString.class]) continue;
                NSString *decoded = DecodeHTMLEntities(raw);
                if (![items containsObject:decoded]) {
                    [items addObject:decoded];
                }
                if (items.count >= 30) break;
            }
        }
    }

    if (items.count > 0) {
        return items;
    }

    return @[@":]", @"^_^", @";O)", @":-]", @"^_^", @"=)", @":O)", @":-3", @"=D", @":|", @"-.-", @">_<", @":O(", @"^^;", @"=[", @"8-)", @"^^;", @":-*", @"B-)", @"=_=", @"-O-", @":P", @"^.^", @"<3"];
}

- (NSString *)quickInsertTitleForActiveTab {
    switch (_activeTab) {
        case 0: return @"Emoji";
        case 1: return @"Kaomoji";
        case 2: return @"Symbols";
        default: return @"";
    }
}

- (void)rebuildQuickInsertView {
    for (NSView *view in _quickInsertStack.arrangedSubviews.copy) {
        [_quickInsertStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    _quickInsertTitle.stringValue = [self quickInsertTitleForActiveTab];
    NSArray<NSString *> *items = [self quickInsertItemsForActiveTab];

    const BOOL isKaomoji = _activeTab == 1;
    const NSInteger columns = isKaomoji ? 3 : 6;
    for (NSInteger index = 0; index < items.count; index += columns) {
        NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 8;
        row.distribution = NSStackViewDistributionFillEqually;
        [_quickInsertStack addArrangedSubview:row];

        for (NSInteger column = 0; column < columns && index + column < items.count; column++) {
            NSString *rawItem = items[index + column];
            NSString *title = rawItem;
            NSString *copyValue = rawItem;

            NSRange separator = [rawItem rangeOfString:@"|"];
            if (separator.location != NSNotFound) {
                title = [rawItem substringToIndex:separator.location];
                copyValue = [rawItem substringFromIndex:separator.location + 1];
            }

            NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(copyQuickInsertItem:)];
            button.toolTip = copyValue;
            button.bezelStyle = NSBezelStyleRounded;
            button.font = [NSFont systemFontOfSize:isKaomoji ? 15 : 20 weight:NSFontWeightRegular];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            if (isKaomoji) {
                button.wantsLayer = YES;
                button.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.78].CGColor;
                button.layer.cornerRadius = 5;
                button.layer.borderWidth = 1;
                button.layer.borderColor = [NSColor colorWithWhite:0.86 alpha:1.0].CGColor;
            }
            [row addArrangedSubview:button];
            [button.heightAnchor constraintEqualToConstant:isKaomoji ? 42 : 38].active = YES;
        }
    }
}

- (void)copyQuickInsertItem:(NSButton *)sender {
    NSString *value = sender.toolTip ?: sender.title;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:value forType:NSPasteboardTypeString];
    _lastChangeCount = pasteboard.changeCount;
    [self pasteIntoPreviousApplication];
}

- (void)pasteIntoPreviousApplication {
    [_window orderOut:nil];

    NSRunningApplication *target = _previousApplication;
    if (target && !target.terminated) {
        [target activateWithOptions:0];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef keyDown = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, true);
        CGEventRef keyUp = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, false);

        if (keyDown && keyUp) {
            CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
            CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, keyDown);
            CGEventPost(kCGHIDEventTap, keyUp);
        }

        if (keyDown) CFRelease(keyDown);
        if (keyUp) CFRelease(keyUp);
        if (source) CFRelease(source);
    });
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == _tableView.menu) {
        NSInteger row = _tableView.clickedRow;
        if (row >= 0 && row < _tableView.numberOfRows) {
            [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        }

        auto selected = [self selectedItem];
        if (menu.itemArray.count >= 3 && selected.has_value()) {
            [menu itemAtIndex:0].enabled = selected->kind == ClipboardKind::Text || selected->kind == ClipboardKind::Link;
            [menu itemAtIndex:1].title = selected->pinned ? @"Unpin" : @"Pin";
        }
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_visibleItems.size());
}

- (void)tableRowClicked:(NSTableView *)tableView {
    NSInteger row = tableView.clickedRow;
    if (row < 0 || static_cast<std::size_t>(row) >= _visibleItems.size()) {
        return;
    }

    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [self copySelectedItem];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    ClipboardRowView *view = [tableView makeViewWithIdentifier:@"ClipboardRow" owner:self];
    if (!view) {
        view = [[ClipboardRowView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 76)];
        view.identifier = @"ClipboardRow";
    }

    const auto& item = _visibleItems[static_cast<std::size_t>(row)];
    view.titleLabel.stringValue = NSStringFromStdString(item.title);
    view.pinView.hidden = !item.pinned;
    view.previewLabel.stringValue = NSStringFromStdString(item.preview);
    view.metaLabel.stringValue = [NSString stringWithFormat:@"%@  %@", NSStringFromStdString(clipboardKindName(item.kind)), HumanTime(item.createdAt)];

    if (!item.imageBase64.empty()) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:NSStringFromStdString(item.imageBase64) options:0];
        view.iconView.image = [[NSImage alloc] initWithData:data];
        view.iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        view.iconView.wantsLayer = YES;
        view.iconView.layer.cornerRadius = 5;
        view.iconView.layer.masksToBounds = YES;
    } else if (item.kind == ClipboardKind::File) {
        view.iconView.image = [NSImage imageWithSystemSymbolName:@"doc.fill" accessibilityDescription:@"File"];
        view.iconView.imageScaling = NSImageScaleProportionallyDown;
        view.iconView.wantsLayer = NO;
    } else {
        view.iconView.image = [NSImage imageWithSystemSymbolName:NSStringFromStdString(clipboardKindIconName(item.kind)) accessibilityDescription:nil];
        view.iconView.imageScaling = NSImageScaleProportionallyDown;
        view.iconView.wantsLayer = NO;
    }

    return view;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateDetail];
}

- (void)refreshVisibleItems {
    const BOOL showingClipboard = _activeTab == 0;
    _quickInsertView.hidden = showingClipboard;

    if (!showingClipboard) {
        _emptyStateView.hidden = YES;
        _historyScrollView.hidden = YES;
        [self rebuildQuickInsertView];
        return;
    }

    NSString *query = _searchField ? _searchField.stringValue : @"";
    _visibleItems = _historyEnabled ? _history->filtered(StdStringFromNSString(query), _selectedKind) : std::vector<ClipboardItem>();
    if (_showPinnedOnly) {
        _visibleItems.erase(std::remove_if(_visibleItems.begin(), _visibleItems.end(), [](const ClipboardItem& item) {
            return !item.pinned;
        }), _visibleItems.end());
    }
    [_tableView reloadData];

    if (!_visibleItems.empty() && _tableView.selectedRow < 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }

    const BOOL hasItems = _historyEnabled && !_visibleItems.empty();
    _emptyStateView.hidden = hasItems;
    _historyScrollView.hidden = !hasItems;
    _emptyHeadlineLabel.stringValue = _historyEnabled ? @"Clipboard is empty" : @"Let's get started";
    _emptyBodyLabel.stringValue = _historyEnabled
        ? @"Copy something and it will\nshow up here."
        : @"Turn on clipboard history to\ncopy and view multiple items.";
    _turnOnButton.hidden = _historyEnabled;
    [self updateDetail];
}

- (std::optional<ClipboardItem>)selectedItem {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || static_cast<std::size_t>(row) >= _visibleItems.size()) {
        return std::nullopt;
    }
    return _visibleItems[static_cast<std::size_t>(row)];
}

- (void)updateDetail {
    if (!_detailTitleLabel || !_detailTextView || !_detailImageView) {
        return;
    }

    auto selected = [self selectedItem];
    if (!selected.has_value()) {
        _detailTitleLabel.stringValue = @"No clipboard item";
        _detailMetaLabel.stringValue = @"";
        _detailTextView.string = @"Copy text, links, files, or images to build history.";
        _detailImageView.hidden = YES;
        return;
    }

    const auto item = *selected;
    _detailTitleLabel.stringValue = NSStringFromStdString(item.title);
    _detailMetaLabel.stringValue = [NSString stringWithFormat:@"%@  %@", NSStringFromStdString(clipboardKindName(item.kind)), HumanTime(item.createdAt)];

    if (item.kind == ClipboardKind::Image && !item.imageBase64.empty()) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:NSStringFromStdString(item.imageBase64) options:0];
        _detailImageView.image = [[NSImage alloc] initWithData:data];
        _detailImageView.hidden = NO;
        _detailTextView.enclosingScrollView.hidden = YES;
    } else {
        _detailTextView.string = NSStringFromStdString(item.content);
        _detailImageView.hidden = YES;
        _detailTextView.enclosingScrollView.hidden = NO;
    }
}

- (void)detailButtonPressed:(NSButton *)sender {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;

    const std::string id = selected->id;
    if ([sender.title isEqualToString:@"Copy"]) {
        [self copySelectedItem];
    } else if ([sender.title isEqualToString:@"Pin"]) {
        _history->togglePinned(id);
    } else if ([sender.title isEqualToString:@"Favorite"]) {
        _history->toggleFavorite(id);
    } else if ([sender.title isEqualToString:@"Delete"]) {
        _history->remove(id);
    }

    [self refreshVisibleItems];
}

- (void)clearUnpinned:(id)sender {
    _history->clearUnpinned();
    [self refreshVisibleItems];
}

- (void)clearAllHistory:(id)sender {
    _history->clearAll();
    [self refreshVisibleItems];
}

- (void)copySelectedItemAction:(id)sender {
    [self copySelectedItem];
}

- (void)editSelectedItem:(id)sender {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;
    if (selected->kind != ClipboardKind::Text && selected->kind != ClipboardKind::Link) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Edit Clipboard Item";
    alert.informativeText = @"Update the text stored in this clipboard entry.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 360, 140)];
    textView.string = NSStringFromStdString(selected->content);
    textView.font = [NSFont systemFontOfSize:13];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 140)];
    scrollView.hasVerticalScroller = YES;
    scrollView.documentView = textView;
    alert.accessoryView = scrollView;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *content = textView.string ?: @"";
        NSString *trimmed = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) return;

        NSString *firstLine = [[trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject] ?: trimmed;
        NSString *title = [firstLine substringToIndex:MIN(firstLine.length, 80)];
        NSString *preview = [trimmed stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, trimmed.length)];
        preview = [preview substringToIndex:MIN(preview.length, 180)];

        _history->updateContent(selected->id, StdStringFromNSString(trimmed), StdStringFromNSString(title), StdStringFromNSString(preview));
        [self refreshVisibleItems];
    }
}

- (void)copySelectedItemAndClose:(id)sender {
    [self copySelectedItem];
    [self pasteIntoPreviousApplication];
}

- (void)toggleSelectedPinned:(id)sender {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;
    _history->togglePinned(selected->id);
    [self refreshVisibleItems];
}

- (void)toggleSelectedFavorite:(id)sender {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;
    _history->toggleFavorite(selected->id);
    [self refreshVisibleItems];
}

- (void)deleteSelectedItem:(id)sender {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;
    _history->remove(selected->id);
    [self refreshVisibleItems];
}

- (void)copySelectedItem {
    auto selected = [self selectedItem];
    if (!selected.has_value()) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];

    if (selected->kind == ClipboardKind::Image && !selected->imageBase64.empty()) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:NSStringFromStdString(selected->imageBase64) options:0];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (image) [pasteboard writeObjects:@[image]];
    } else if (selected->kind == ClipboardKind::File) {
        [pasteboard setString:NSStringFromStdString(selected->content) forType:NSPasteboardTypeFileURL];
    } else {
        [pasteboard setString:NSStringFromStdString(selected->content) forType:NSPasteboardTypeString];
    }

    _lastChangeCount = pasteboard.changeCount;
}

- (void)checkPasteboard {
    if (!_historyEnabled) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (pasteboard.changeCount == _lastChangeCount) return;
    _lastChangeCount = pasteboard.changeCount;

    [self capturePasteboard:pasteboard];
}

- (void)captureCurrentPasteboard {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    _lastChangeCount = pasteboard.changeCount;
    [self capturePasteboard:pasteboard];
}

- (void)capturePasteboard:(NSPasteboard *)pasteboard {
    auto item = [self itemFromPasteboard:pasteboard];
    if (!item.has_value()) return;

    _history->add(*item);
    [self refreshVisibleItems];
}

- (std::optional<ClipboardItem>)itemFromPasteboard:(NSPasteboard *)pasteboard {
    NSImage *clipboardImage = nil;
    NSArray<NSImage *> *images = [pasteboard readObjectsForClasses:@[NSImage.class] options:@{}];
    if (images.count > 0) {
        clipboardImage = images.firstObject;
    }

    if (!clipboardImage) {
        NSData *pngData = [pasteboard dataForType:NSPasteboardTypePNG];
        if (pngData.length > 0) {
            clipboardImage = [[NSImage alloc] initWithData:pngData];
        }
    }

    if (!clipboardImage) {
        NSData *tiffData = [pasteboard dataForType:NSPasteboardTypeTIFF];
        if (tiffData.length > 0) {
            clipboardImage = [[NSImage alloc] initWithData:tiffData];
        }
    }

    if (clipboardImage) {
        NSData *thumbnailData = PNGDataFromImage(clipboardImage, 96);
        if (thumbnailData.length > 0) {
            ClipboardItem item;
            item.id = makeClipboardID();
            item.kind = ClipboardKind::Image;
            item.title = "Image";
            item.preview = StdStringFromNSString([NSString stringWithFormat:@"%d x %d", static_cast<int>(clipboardImage.size.width), static_cast<int>(clipboardImage.size.height)]);
            item.content = "image";
            item.imageBase64 = StdStringFromNSString([thumbnailData base64EncodedStringWithOptions:0]);
            item.createdAt = currentUnixTime();
            return item;
        }
    }

    NSString *fileURL = [pasteboard stringForType:NSPasteboardTypeFileURL];
    if (fileURL.length > 0) {
        NSURL *url = [NSURL URLWithString:fileURL];
        ClipboardItem item;
        item.id = makeClipboardID();
        item.kind = ClipboardKind::File;
        item.title = StdStringFromNSString(url.lastPathComponent ?: @"File");
        item.preview = StdStringFromNSString(url.path ?: fileURL);
        item.content = StdStringFromNSString(fileURL);
        if (url.isFileURL && FileURLLooksLikeImage(url)) {
            NSImage *fileImage = [[NSImage alloc] initWithContentsOfURL:url];
            NSData *thumbnailData = PNGDataFromImage(fileImage, 96);
            if (thumbnailData.length > 0) {
                item.imageBase64 = StdStringFromNSString([thumbnailData base64EncodedStringWithOptions:0]);
            }
        }
        item.createdAt = currentUnixTime();
        return item;
    }

    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (text.length > 0) {
        std::string content = StdStringFromNSString([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (!content.empty()) {
            ClipboardItem item;
            item.id = makeClipboardID();
            item.kind = [NSURL URLWithString:text].scheme.length > 0 ? ClipboardKind::Link : ClipboardKind::Text;
            item.content = content;
            item.createdAt = currentUnixTime();

            NSString *firstLine = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
            item.title = item.kind == ClipboardKind::Link && [NSURL URLWithString:text].host.length > 0
                ? StdStringFromNSString([NSURL URLWithString:text].host)
                : StdStringFromNSString([firstLine substringToIndex:MIN(firstLine.length, 80)]);

            NSString *preview = [text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
            item.preview = StdStringFromNSString([preview substringToIndex:MIN(preview.length, 180)]);
            return item;
        }
    }

    return std::nullopt;
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        return NSApplicationMain(argc, argv);
    }
}
