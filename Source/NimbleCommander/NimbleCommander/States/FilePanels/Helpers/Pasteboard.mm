// Copyright (C) 2017-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Pasteboard.h"
#include <VFS/VFS.h>
#include <Utility/StringExtras.h>
#include <Panel/Log.h>

namespace nc::panel {

bool PasteboardSupport::WriteFilesnamesPBoard(const std::vector<VFSListingItem> &_items, NSPasteboard *_pasteboard)
{
    if( !_pasteboard )
        return false;

    const auto filepaths = [[NSMutableArray alloc] initWithCapacity:_items.size()];
    for( auto &i : _items )
        if( i.Host()->IsNativeFS() )
            if( const auto path = [NSString stringWithUTF8StdString:i.Path()] )
                [filepaths addObject:path];

    if( filepaths.count == 0 )
        return false;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [_pasteboard clearContents];
    [_pasteboard declareTypes:@[NSFilenamesPboardType] owner:nil];
    return [_pasteboard setPropertyList:filepaths forType:NSFilenamesPboardType];
#pragma clang diagnostic pop
}

bool PasteboardSupport::WriteURLSPBoard(const std::vector<VFSListingItem> &_items, NSPasteboard *_pasteboard)
{
    if( !_pasteboard )
        return false;

    const auto urls = [[NSMutableArray alloc] initWithCapacity:_items.size()];
    for( auto &i : _items )
        if( i.Host()->IsNativeFS() )
            if( const auto path = [NSString stringWithUTF8StdString:i.Path()] )
                if( const auto url = [NSURL fileURLWithPath:path] )
                    [urls addObject:url];

    [_pasteboard clearContents];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [_pasteboard declareTypes:@[(__bridge NSString *)kUTTypeFileURL] owner:nil];
#pragma clang diagnostic pop
    return [_pasteboard writeObjects:urls];
}

void PasteboardSupport::CoordinateReading(NSArray<NSURL *> *_urls, std::function<void()> _then)
{
    if( _urls.count == 0 ) {
        _then();
        return;
    }

    NSMutableArray<NSFileAccessIntent *> *const intents = [[NSMutableArray alloc] initWithCapacity:_urls.count];
    for( NSURL *url in _urls )
        [intents addObject:[NSFileAccessIntent readingIntentWithURL:url options:0]];

    NSFileCoordinator *const coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateAccessWithIntents:intents
                                       queue:NSOperationQueue.mainQueue
                                  byAccessor:^(NSError *_error) {
                                    (void)coordinator; // keep it alive until the access is granted
                                    if( _error )
                                        Log::Warn("Coordinated reading failed: {}", _error.description.UTF8String);
                                    _then();
                                  }];
}

} // namespace nc::panel
