// Copyright (C) 2026. Subject to GNU General Public License version 3.
// Go To palette.

#import "GoToPaletteWindowController.h"
#import "../MainWindowFilePanelState.h"
#import "../PanelController.h"
#import <NimbleCommander/Core/AnyHolder.h>
#import "../Actions/ShowGoToPopup.h"
#import <Panel/NetworkConnectionsManager.h>
#import <algorithm>
#import <string>

static const CGFloat kWindowWidth = 520.;
static const CGFloat kSearchHeight = 28.;
static const CGFloat kTableRowHeight = 22.;
static const CGFloat kMaxVisibleRows = 14.;
static const CGFloat kPadding = 8.;

static void GoToPaletteLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void GoToPaletteLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSData *data = [[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    static NSFileHandle *fh;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/gotopalette_debug.txt" contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/gotopalette_debug.txt"];
        [fh seekToEndOfFile];
    });
    if( fh )
        [fh writeData:data];
}

@implementation GoToPaletteEntry
@synthesize displayString;
@synthesize context;
@end

@interface GoToPaletteWindowController () <NSWindowDelegate>
@property(nonatomic, weak) PanelController *panel;
@property(nonatomic, weak) MainWindowFilePanelState *state;
@property(nonatomic, assign) nc::panel::NetworkConnectionsManager *networkManager;
@property(nonatomic, copy) NSArray<GoToPaletteEntry *> *allEntries;
@property(nonatomic, copy) NSArray<GoToPaletteEntry *> *filteredEntries;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) id eventMonitor;
@property(nonatomic, strong) id textChangeObserver;
@property(nonatomic, copy) GoToPaletteSearchBlock searchBlock;
@property(nonatomic, copy) NSArray<NSString *> *extraPathResults;
@property(nonatomic, assign) NSInteger searchGeneration;
@property(nonatomic, strong) NSTimer *filterTimer;
@property(nonatomic, copy) NSString *lastAppliedQuery;
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
@synthesize eventMonitor = _eventMonitor;
@synthesize textChangeObserver = _textChangeObserver;
@synthesize searchBlock = _searchBlock;
@synthesize extraPathResults = _extraPathResults;
@synthesize searchGeneration = _searchGeneration;
@synthesize filterTimer = _filterTimer;
@synthesize lastAppliedQuery = _lastAppliedQuery;

- (instancetype)initWithPanel:(PanelController *)panel
                       state:(MainWindowFilePanelState *)state
               networkManager:(void *)networkManager
                      entries:(NSArray<GoToPaletteEntry *> *)entries
                   searchBlock:(GoToPaletteSearchBlock)searchBlock
{
    self = [super initWithWindow:nil];
    if( self ) {
        _panel = panel;
        _state = state;
        _networkManager = static_cast<nc::panel::NetworkConnectionsManager *>(networkManager);
        _allEntries = [entries copy];
        _filteredEntries = [entries copy];
        _searchBlock = [searchBlock copy];
        _extraPathResults = @[];
    }
    return self;
}

static bool QueryMatches(NSString *query, NSString *candidate)
{
    if( query.length == 0 )
        return true;
    std::string q = query.lowercaseString.UTF8String ?: "";
    std::string c = candidate.lowercaseString.UTF8String ?: "";
    return c.find(q) != std::string::npos;
}

// Use folder name (last path component) for matching when candidate looks like a path,
// so "va" matches "Valerii" but not "LeadsMarket" (path contains "yuriipavlov").
static NSString *DisplayStringForFiltering(NSString *displayString)
{
    if( !displayString || displayString.length == 0 )
        return displayString;
    if( [displayString rangeOfString:@"/"].location != NSNotFound )
        return displayString.lastPathComponent;
    return displayString;
}

- (void)filterWithQuery:(NSString *)query
{
    if( query == nil )
        query = @"";
    if( [query isEqualToString:self.lastAppliedQuery] )
        return;
    self.lastAppliedQuery = [query copy];

    GoToPaletteLog(@"filterWithQuery: '%@' allEntries=%lu", query, static_cast<unsigned long>(self.allEntries.count));

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
        GoToPaletteLog(@"  filtered from history: %lu", static_cast<unsigned long>(self.filteredEntries.count));
        // Always ask external search for non-empty queries so filesystem results are visible
        // even when there are some matches in history/frecents/favorites.
        if( self.searchBlock ) {
            NSInteger gen = ++_searchGeneration;
            __weak __typeof__(self) wself = self;
            GoToPaletteLog(@"  calling search block gen=%ld", static_cast<long>(gen));
            self.searchBlock(query, ^(NSArray<NSString *> *paths) {
                GoToPaletteLog(@"  search completion: %lu paths wself=%p gen=%ld self.gen=%ld",
                            static_cast<unsigned long>(paths ? paths.count : 0),
                            (__bridge void *)wself, static_cast<long>(gen),
                            wself ? static_cast<long>(wself.searchGeneration) : -1L);
                if( !wself )
                    return;
                if( gen != wself.searchGeneration )
                    GoToPaletteLog(@"  applying stale search results gen=%ld self.gen=%ld",
                                   static_cast<long>(gen),
                                   static_cast<long>(wself.searchGeneration));
                wself.extraPathResults = paths ?: @[];
                GoToPaletteLog(@"  set extraPathResults=%lu totalRows=%lu",
                               static_cast<unsigned long>(wself.extraPathResults.count),
                               static_cast<unsigned long>(wself.filteredEntries.count + wself.extraPathResults.count));
                [wself.tableView reloadData];
                if( wself.filteredEntries.count + wself.extraPathResults.count > 0 )
                    [wself.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            });
        }
    }
    [self.tableView reloadData];
    NSUInteger total = self.filteredEntries.count + self.extraPathResults.count;
    GoToPaletteLog(@"  total rows: %lu", static_cast<unsigned long>(total));
    self.window.title = [NSString stringWithFormat:NSLocalizedString(@"Go To (%lu)", nil), static_cast<unsigned long>(total)];
    if( total > 0 ) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:0];
    } else {
        [self.tableView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    [self filterWithQuery:self.searchField.stringValue];
}

- (void)applyFilterFromSearchFieldTimer:(NSTimer *)timer
{
    [self filterWithQuery:self.searchField.stringValue];
}

- (void)refilterCurrentQuery
{
    self.lastAppliedQuery = nil;
    [self filterWithQuery:self.searchField.stringValue];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    self.window.delegate = self;
}

- (void)buildWindow
{
    NSRect contentRect = NSMakeRect(0, 0, kWindowWidth, kSearchHeight + kPadding * 2 + kTableRowHeight * kMaxVisibleRows);
    NSPanel *floatingPanel = [[NSPanel alloc] initWithContentRect:contentRect
                                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    floatingPanel.title = NSLocalizedString(@"Go To", @"Go To palette title");
    floatingPanel.level = NSFloatingWindowLevel;
    floatingPanel.becomesKeyOnlyIfNeeded = NO;
    floatingPanel.hidesOnDeactivate = NO;
    floatingPanel.delegate = self;
    self.window = floatingPanel;

    NSView *content = floatingPanel.contentView;
    content.wantsLayer = YES;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(kPadding, contentRect.size.height - kSearchHeight - kPadding, kWindowWidth - kPadding * 2, kSearchHeight)];
    self.searchField.placeholderString = NSLocalizedString(@"Type to filter…", @"Go To palette search placeholder");
    self.searchField.delegate = self;
    __weak __typeof__(self) wself = self;
    self.textChangeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSControlTextDidChangeNotification
                    object:self.searchField
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *_Nonnull __unused note) {
                    [wself filterWithQuery:wself.searchField.stringValue];
                }];
    NSSearchFieldCell *searchCell = static_cast<NSSearchFieldCell *>(self.searchField.cell);
    searchCell.sendsWholeSearchString = NO;
    searchCell.sendsSearchStringImmediately = YES;
    [content addSubview:self.searchField];

    CGFloat tableHeight = kTableRowHeight * kMaxVisibleRows;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(kPadding, kPadding, kWindowWidth - kPadding * 2, tableHeight)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autohidesScrollers = YES;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.headerView = nil;
    self.tableView.rowHeight = kTableRowHeight;
    self.tableView.intercellSpacing = NSMakeSize(0, 0);
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.doubleAction = @selector(onDoubleClick:);
    self.tableView.target = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.width = kWindowWidth - kPadding * 2;
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
    __weak __typeof__(self) wself = self;
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventTypeKeyDown
                                                              handler:^NSEvent *(NSEvent *ev) {
                                                                  if( ev.window != wself.window )
                                                                      return ev;
                                                                  if( ev.keyCode == 53 ) { // Esc
                                                                      [wself.window close];
                                                                      return nil;
                                                                  }
                                                                  if( ev.keyCode == 36 ) { // Enter
                                                                      [wself performGoToForSelectedRow];
                                                                      return nil;
                                                                  }
                                                                  return ev;
                                                              }];
    [win makeKeyAndOrderFront:nil];
    [self.searchField becomeFirstResponder];
    [self filterWithQuery:self.searchField.stringValue];
    self.filterTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                        target:self
                                                      selector:@selector(applyFilterFromSearchFieldTimer:)
                                                      userInfo:nil
                                                       repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.filterTimer forMode:NSRunLoopCommonModes];
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

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    // allow arrow keys to move selection
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
        display = self.filteredEntries[row].displayString;
    } else {
        // Mark filesystem search results explicitly so it's clear they are not from history/favorites.
        NSString *path = self.extraPathResults[row - historyCount];
        display = [NSString stringWithFormat:@"[FS] %@", path ?: @""];
    }
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"PathCell" owner:self];
    if( !cell ) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, kTableRowHeight)];
        cell.identifier = @"PathCell";
        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSInsetRect(cell.bounds, 4, 2)];
        textField.editable = NO;
        textField.bordered = NO;
        textField.drawsBackground = NO;
        textField.font = [NSFont systemFontOfSize:12];
        [cell addSubview:textField];
        cell.textField = textField;
    }
    cell.textField.stringValue = display ?: @"";
    return cell;
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self.filterTimer invalidate];
    self.filterTimer = nil;
    if( self.textChangeObserver ) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.textChangeObserver];
        self.textChangeObserver = nil;
    }
    if( self.eventMonitor ) {
        [NSEvent removeMonitor:self.eventMonitor];
        self.eventMonitor = nil;
    }
    NSWindow *win = self.window;
    if( win.parentWindow )
        [win.parentWindow removeChildWindow:win];
}

@end
