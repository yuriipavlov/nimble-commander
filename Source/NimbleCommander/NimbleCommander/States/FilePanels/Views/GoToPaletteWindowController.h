// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#import <Cocoa/Cocoa.h>

@class PanelController;
@class MainWindowFilePanelState;
@class AnyHolder;

namespace nc::panel {
class NetworkConnectionsManager;
}

@interface GoToPaletteEntry : NSObject
@property(nonatomic, copy) NSString *displayString;
@property(nonatomic, strong) AnyHolder *context;
@end

/** Block: (query, completion). Call completion on main with folder paths. */
typedef void (^GoToPaletteSearchBlock)(NSString *query, void (^completion)(NSArray<NSString *> *paths));

@interface GoToPaletteWindowController
    : NSWindowController <NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithPanel:(PanelController *)panel
                        state:(MainWindowFilePanelState *)state
               networkManager:(nc::panel::NetworkConnectionsManager &)networkManager
                      entries:(NSArray<GoToPaletteEntry *> *)entries
                  searchBlock:(GoToPaletteSearchBlock)searchBlock;
- (void)showRelativeToWindow:(NSWindow *)parentWindow;
- (void)refilterCurrentQuery;
@end
