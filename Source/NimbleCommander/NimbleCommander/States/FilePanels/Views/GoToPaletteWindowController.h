// Copyright (C) 2026. Subject to GNU General Public License version 3.
// Go To palette: fuzzy search over recent/frequent directories.

#import <Cocoa/Cocoa.h>

@class PanelController;
@class MainWindowFilePanelState;
@class AnyHolder;

@interface GoToPaletteEntry : NSObject
@property(nonatomic, copy) NSString *displayString;
@property(nonatomic, strong) AnyHolder *context;
@end

/** Block: (query, completion). Call completion on main with folder paths. */
typedef void (^GoToPaletteSearchBlock)(NSString *query, void (^completion)(NSArray<NSString *> *paths));

@interface GoToPaletteWindowController : NSWindowController <NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithPanel:(PanelController *)panel
                       state:(MainWindowFilePanelState *)state
               networkManager:(void *)networkManager
                      entries:(NSArray<GoToPaletteEntry *> *)entries
                   searchBlock:(GoToPaletteSearchBlock)searchBlock;
- (void)showRelativeToWindow:(NSWindow *)parentWindow;
/** Re-run search with current query (e.g. after index has finished building). */
- (void)refilterCurrentQuery;
/** Navigate to the currently selected row (called from panel's performKeyEquivalent for Enter). */
- (void)performGoToForSelectedRow;
@end
