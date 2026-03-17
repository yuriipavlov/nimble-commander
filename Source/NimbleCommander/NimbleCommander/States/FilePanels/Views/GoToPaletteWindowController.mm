// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.

#import "GoToPaletteWindowController.h"
#import "../MainWindowFilePanelState.h"
#import "../PanelController.h"
#import <NimbleCommander/Core/AnyHolder.h>
#import "../Actions/ShowGoToPopup.h"
#import <Panel/NetworkConnectionsManager.h>
#include <NimbleCommander/Bootstrap/Config.h>
#include <algorithm>
#include <string>

static const CGFloat g_WindowWidth = 520.;
static const CGFloat g_SearchHeight = 28.;
static const CGFloat g_TableRowHeight = 22.;
static const CGFloat g_MaxVisibleRows = 14.;
static const CGFloat g_Padding = 8.;
static const auto g_ConfigSearchDebounceMs = "filePanel.gotoPalette.searchDebounceMs";

static NSTimeInterval SearchDebounceDelay()
{
    const int ms = GlobalConfig().Has(g_ConfigSearchDebounceMs) ? GlobalConfig().GetInt(g_ConfigSearchDebounceMs) : 80;
    const int clamped = std::max(0, std::min(1000, ms));
    return static_cast<NSTimeInterval>(clamped) / 1000.0;
}

@implementation GoToPaletteEntry
@synthesize displayString;
@synthesize context;
@end

@interface GoToPalettePanel : NSPanel
@end

@protocol GoToPalettePerforming <NSObject>
- (void)performGoToForSelectedRow;
@end

@implementation GoToPalettePanel

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if( event.keyCode == 53 ) { // Esc
        [self close];
        return YES;
    }
    if( event.keyCode == 36 ) { // Return
        id d = self.delegate;
        if( [d respondsToSelector:@selector(performGoToForSelectedRow)] )
            [static_cast<id<GoToPalettePerforming>>(d) performGoToForSelectedRow];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end

@interface GoToPaletteTableView : NSTableView
@property(nonatomic, weak) NSSearchField *paletteSearchField;
@end

@implementation GoToPaletteTableView
@synthesize paletteSearchField = _paletteSearchField;

- (void)keyDown:(NSEvent *)event
{
    if( event.keyCode == 126 && self.selectedRow <= 0 ) {
        [self.window makeFirstResponder:self.paletteSearchField];
        return;
    }
    [super keyDown:event];
}

@end

@interface GoToPaletteWindowController () <NSWindowDelegate>
@property(nonatomic, weak) PanelController *panel;
@property(nonatomic, weak) MainWindowFilePanelState *state;
@property(nonatomic, assign) nc::panel::NetworkConnectionsManager *networkManager;
@property(nonatomic, copy) NSArray<GoToPaletteEntry *> *allEntries;
@property(nonatomic, copy) NSArray<GoToPaletteEntry *> *filteredEntries;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) GoToPaletteTableView *tableView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, copy) GoToPaletteSearchBlock searchBlock;
@property(nonatomic, copy) NSArray<NSString *> *extraPathResults;
@property(nonatomic, assign) NSInteger searchGeneration;
@property(nonatomic, copy) NSString *lastAppliedQuery;
@property(nonatomic, strong) NSTimer *searchDebounceTimer;
- (void)performGoToForSelectedRow;
@end

@implementation GoToPaletteWindowController
@synthesize panel = _panel;
@synthesize state = _state;
@synthesize networkManager = _networkManager;
@synthesize allEntries = _allEntries;
@synthesize filteredEntries = _filteredEntries;
@synthesize searchField = _searchField;
@synthesize tableView = _tableView;
@synthesize scrollView = _scrollView;
@synthesize searchBlock = _searchBlock;
@synthesize extraPathResults = _extraPathResults;
@synthesize searchGeneration = _searchGeneration;
@synthesize lastAppliedQuery = _lastAppliedQuery;
@synthesize searchDebounceTimer = _searchDebounceTimer;

- (instancetype)initWithPanel:(PanelController *)panel
                        state:(MainWindowFilePanelState *)state
               networkManager:(nc::panel::NetworkConnectionsManager &)networkManager
                      entries:(NSArray<GoToPaletteEntry *> *)entries
                  searchBlock:(GoToPaletteSearchBlock)searchBlock
{
    self = [super initWithWindow:nil];
    if( self ) {
        _panel = panel;
        _state = state;
        _networkManager = &networkManager;
        _allEntries = [entries copy];
        _filteredEntries = [entries copy];
        _searchBlock = [searchBlock copy];
        _extraPathResults = @[];
    }
    return self;
}

static NSString *ShortenWithTilde(NSString *path)
{
    static NSString *homePrefix = NSHomeDirectory();
    if( !path || path.length == 0 )
        return path;
    if( [path hasPrefix:homePrefix] ) {
        NSString *rest = [path substringFromIndex:homePrefix.length];
        return [@"~" stringByAppendingString:rest];
    }
    return path;
}

static bool QueryMatches(NSString *query, NSString *candidate)
{
    if( query.length == 0 )
        return true;
    std::string q = query.lowercaseString.UTF8String ?: "";
    std::string c = candidate.lowercaseString.UTF8String ?: "";
    return c.find(q) != std::string::npos;
}

static NSString *NormalizePathForDedup(NSString *path)
{
    if( !path || path.length == 0 )
        return @"";
    NSString *s = [path copy];
    while( s.length > 1 && ([s hasSuffix:@"/"] || [s hasSuffix:@"\\"]) )
        s = [s substringToIndex:s.length - 1];
    return s.lowercaseString ?: @"";
}

static NSString *DisplayStringForFiltering(NSString *displayString)
{
    if( !displayString || displayString.length == 0 )
        return displayString;
    if( [displayString rangeOfString:@"/"].location != NSNotFound )
        return displayString.lastPathComponent;
    return displayString;
}

static NSAttributedString *AttributedStringWithHighlightedQuery(NSString *text, NSString *query)
{
    if( !text )
        return [[NSAttributedString alloc] initWithString:@""];
    NSFont *baseFont = [NSFont systemFontOfSize:12];
    if( !query || query.length == 0 ) {
        return [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: baseFont}];
    }

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text
                                                                               attributes:@{NSFontAttributeName: baseFont}];
    NSDictionary *highlightAttrs = @{
        NSBackgroundColorAttributeName: [NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.6],
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
    };
    NSString *lowerText = text.lowercaseString;
    NSString *lowerQuery = query.lowercaseString;
    NSRange searchRange = NSMakeRange(0, lowerText.length);
    for( ;; ) {
        NSRange match = [lowerText rangeOfString:lowerQuery options:0 range:searchRange];
        if( match.location == NSNotFound )
            break;
        [result setAttributes:highlightAttrs range:match];
        searchRange.location = match.location + match.length;
        searchRange.length = lowerText.length - searchRange.location;
    }
    return [result copy];
}

- (void)filterWithQuery:(NSString *)query
{
    if( query == nil )
        query = @"";
    if( [query isEqualToString:self.lastAppliedQuery] )
        return;
    self.lastAppliedQuery = [query copy];

    if( query.length == 0 ) {
        self.filteredEntries = [self.allEntries copy];
        self.extraPathResults = @[];
    } else {
        NSMutableArray<GoToPaletteEntry *> *filtered = [NSMutableArray array];
        for( GoToPaletteEntry *e in self.allEntries ) {
            NSString *toMatch = DisplayStringForFiltering(e.displayString);
            if( QueryMatches(query, toMatch) )
                [filtered addObject:e];
        }
        self.filteredEntries = [filtered copy];
        self.extraPathResults = @[];
        if( self.searchBlock ) {
            NSInteger gen = ++_searchGeneration;
            __weak __typeof__(self) wself = self;
            self.searchBlock(query, ^(NSArray<NSString *> *paths) {
                if( !wself || gen != wself.searchGeneration )
                    return;
                NSMutableSet<NSString *> *seenNorm = [NSMutableSet set];
                NSMutableArray<NSString *> *deduped = [NSMutableArray array];
                for( NSString *path in paths ?: @[] ) {
                    NSString *norm = NormalizePathForDedup(path);
                    if( norm.length == 0 || [seenNorm containsObject:norm] )
                        continue;
                    BOOL inHistory = NO;
                    for( GoToPaletteEntry *e in wself.filteredEntries ) {
                        if( [NormalizePathForDedup(e.displayString) isEqualToString:norm] ) {
                            inHistory = YES;
                            break;
                        }
                    }
                    if( inHistory )
                        continue;
                    [seenNorm addObject:norm];
                    [deduped addObject:path];
                }
                wself.extraPathResults = [deduped copy];
                [wself.tableView reloadData];
                if( wself.filteredEntries.count + wself.extraPathResults.count > 0 )
                    [wself.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            });
        }
    }
    [self.tableView reloadData];
    NSUInteger total = self.filteredEntries.count + self.extraPathResults.count;
    if( total > 0 ) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:0];
    } else {
        [self.tableView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    [self.searchDebounceTimer invalidate];
    __weak __typeof__(self) wself = self;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:SearchDebounceDelay()
                                                                repeats:NO
                                                                  block:^(__unused NSTimer *) {
                                                                      if( !wself )
                                                                          return;
                                                                      [wself filterWithQuery:wself.searchField.stringValue];
                                                                  }];
}

- (void)refilterCurrentQuery
{
    self.lastAppliedQuery = nil;
    [self filterWithQuery:self.searchField.stringValue];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    [self.window close];
}

- (void)buildWindow
{
    NSRect contentRect = NSMakeRect(0, 0, g_WindowWidth, g_SearchHeight + g_Padding * 2 + g_TableRowHeight * g_MaxVisibleRows);
    GoToPalettePanel *floatingPanel = [[GoToPalettePanel alloc] initWithContentRect:contentRect
                                                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                                            backing:NSBackingStoreBuffered
                                                                              defer:NO];
    floatingPanel.title = @"GoTo";
    floatingPanel.level = NSFloatingWindowLevel;
    floatingPanel.becomesKeyOnlyIfNeeded = NO;
    floatingPanel.hidesOnDeactivate = NO;
    floatingPanel.delegate = self;
    self.window = floatingPanel;

    NSView *content = floatingPanel.contentView;
    content.wantsLayer = YES;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(g_Padding, contentRect.size.height - g_SearchHeight - g_Padding, g_WindowWidth - g_Padding * 2, g_SearchHeight)];
    self.searchField.placeholderString = NSLocalizedString(@"Type to filter…", @"Go To palette search placeholder");
    self.searchField.delegate = self;
    NSSearchFieldCell *searchCell = static_cast<NSSearchFieldCell *>(self.searchField.cell);
    searchCell.sendsWholeSearchString = NO;
    searchCell.sendsSearchStringImmediately = YES;
    [content addSubview:self.searchField];

    CGFloat tableHeight = g_TableRowHeight * g_MaxVisibleRows;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(g_Padding, g_Padding, g_WindowWidth - g_Padding * 2, tableHeight)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autohidesScrollers = YES;

    self.tableView = [[GoToPaletteTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.paletteSearchField = self.searchField;
    self.tableView.headerView = nil;
    self.tableView.rowHeight = g_TableRowHeight;
    self.tableView.intercellSpacing = NSMakeSize(0, 0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.doubleAction = @selector(onDoubleClick:);
    self.tableView.target = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.width = g_WindowWidth - g_Padding * 2;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:col];
    self.scrollView.documentView = self.tableView;
    [content addSubview:self.scrollView];

    [self filterWithQuery:@""];
    if( self.filteredEntries.count > 0 )
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (void)showRelativeToWindow:(NSWindow *)parentWindow
{
    [self buildWindow];
    NSWindow *win = self.window;
    NSRect parentFrame = parentWindow.frame;
    NSRect winFrame = win.frame;
    CGFloat x = parentFrame.origin.x + (parentFrame.size.width - winFrame.size.width) / 2.;
    CGFloat y = parentFrame.origin.y + parentFrame.size.height - winFrame.size.height - 60.;
    [win setFrameOrigin:NSMakePoint(x, y)];
    [parentWindow addChildWindow:win ordered:NSWindowAbove];
    [win makeKeyAndOrderFront:nil];
    [self.searchField becomeFirstResponder];
    [self filterWithQuery:self.searchField.stringValue];
}

- (void)performGoToForSelectedRow
{
    NSInteger row = self.tableView.selectedRow;
    NSUInteger historyCount = self.filteredEntries.count;
    NSUInteger total = historyCount + self.extraPathResults.count;
    if( row < 0 || static_cast<size_t>(row) >= total )
        return;
    if( static_cast<size_t>(row) < historyCount ) {
        GoToPaletteEntry *entry = self.filteredEntries[row];
        if( !entry.context || !entry.context.any.has_value() )
            return;
        nc::panel::actions::PerformGoToWithContext(self.state, self.panel, *self.networkManager, entry.context.any);
    } else {
        NSString *path = self.extraPathResults[row - historyCount];
        std::string pathStr = path.UTF8String ? std::string(path.UTF8String) : std::string();
        nc::panel::actions::PerformGoToWithPath(self.state, self.panel, *self.networkManager, pathStr);
    }
    [self.window close];
}

- (void)onDoubleClick:(id)sender
{
    [self performGoToForSelectedRow];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if( control != self.searchField )
        return NO;
    if( commandSelector == @selector(cancelOperation:) ) {
        [self.window close];
        return YES;
    }
    if( commandSelector == @selector(moveDown:) ) {
        [self.window makeFirstResponder:self.tableView];
        if( self.filteredEntries.count + self.extraPathResults.count > 0 )
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        return YES;
    }
    if( commandSelector == @selector(insertNewline:) || commandSelector == @selector(insertNewlineIgnoringFieldEditor:) ) {
        [self performGoToForSelectedRow];
        return YES;
    }
    return NO;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    NSUInteger total = self.filteredEntries.count + self.extraPathResults.count;
    return row >= 0 && static_cast<size_t>(row) < total;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return static_cast<NSInteger>(self.filteredEntries.count + self.extraPathResults.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSUInteger historyCount = self.filteredEntries.count;
    NSUInteger total = historyCount + self.extraPathResults.count;
    if( row < 0 || static_cast<size_t>(row) >= total )
        return nil;
    NSString *display = nil;
    if( static_cast<size_t>(row) < historyCount ) {
        display = ShortenWithTilde(self.filteredEntries[row].displayString);
    } else {
        display = ShortenWithTilde(self.extraPathResults[row - historyCount]);
    }
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"PathCell" owner:self];
    if( !cell ) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, g_TableRowHeight)];
        cell.identifier = @"PathCell";
        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSInsetRect(cell.bounds, 4, 2)];
        textField.editable = NO;
        textField.bordered = NO;
        textField.drawsBackground = NO;
        textField.font = [NSFont systemFontOfSize:12];
        textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [cell addSubview:textField];
        cell.textField = textField;
    }
    cell.textField.attributedStringValue = AttributedStringWithHighlightedQuery(display ?: @"", self.lastAppliedQuery);
    return cell;
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    NSWindow *win = self.window;
    if( win.parentWindow )
        [win.parentWindow removeChildWindow:win];
}

@end
