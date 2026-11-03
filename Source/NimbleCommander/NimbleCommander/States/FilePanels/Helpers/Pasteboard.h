// Copyright (C) 2017-2018 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Cocoa/Cocoa.h>
#include <VFS/VFS.h>
#include <functional>

namespace nc::panel {

struct PasteboardSupport {

    static bool WriteFilesnamesPBoard(const std::vector<VFSListingItem> &_items, NSPasteboard *_pasteboard);
    static bool WriteURLSPBoard(const std::vector<VFSListingItem> &_items, NSPasteboard *_pasteboard);
    static void CoordinateReading(NSArray<NSURL *> *_urls, std::function<void()> _then);
};

} // namespace nc::panel
