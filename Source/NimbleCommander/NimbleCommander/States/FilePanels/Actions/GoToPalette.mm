// Copyright (C) 2026. Subject to GNU General Public License version 3.
#include "GoToPalette.h"
#include "ShowGoToPopup.h"
#include "../MainWindowFilePanelState.h"
#include "../PanelController.h"
#include "../PanelHistory.h"
#include "../Favorites.h"
#include "../ListingPromise.h"
#include "../Helpers/LocationFormatter.h"
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Core/AnyHolder.h>
#import "../Views/GoToPaletteWindowController.h"
#include <Panel/NetworkConnectionsManager.h>
#include <Foundation/Foundation.h>
#include <Base/dispatch_cpp.h>
#include <filesystem>
#include <vector>
#include <string>
#include <algorithm>

namespace nc::panel::actions {

namespace {

// Build an in-memory index of directories under a set of roots.
static void BuildDirectoryIndex(const std::vector<std::string> &_roots, std::vector<std::string> &_out)
{
    namespace fs = std::filesystem;
    using namespace std::literals;

    static const std::size_t kMaxIndexedDirectories = 20000;
    static const int kMaxDepth = 6;

    std::error_code ec;

    for( const auto &root_str : _roots ) {
        if( root_str.empty() )
            continue;

        fs::path root_path(root_str);
        if( !fs::exists(root_path, ec) || !fs::is_directory(root_path, ec) ) {
            ec.clear();
            continue;
        }

        // Always include the root itself.
        _out.emplace_back(root_path.string());
        if( _out.size() >= kMaxIndexedDirectories )
            return;

        fs::recursive_directory_iterator it(
            root_path, fs::directory_options::skip_permission_denied, ec);
        fs::recursive_directory_iterator end;
        if( ec ) {
            ec.clear();
            continue;
        }

        for( ; it != end && _out.size() < kMaxIndexedDirectories; it.increment(ec) ) {
            if( ec ) {
                ec.clear();
                continue;
            }
            if( it.depth() > kMaxDepth )
                continue;

            const auto status = it->symlink_status(ec);
            if( ec ) {
                ec.clear();
                continue;
            }
            if( !fs::is_directory(status) )
                continue;

            _out.emplace_back(it->path().string());
        }

        if( _out.size() >= kMaxIndexedDirectories )
            return;
    }
}

// Simple case-insensitive substring match.
static bool ContainsCaseInsensitive(const std::string &_haystack, const std::string &_needle)
{
    if( _needle.empty() )
        return true;

    std::string h = _haystack;
    std::string n = _needle;
    std::transform(h.begin(), h.end(), h.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    std::transform(n.begin(), n.end(), n.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    return h.find(n) != std::string::npos;
}

} // namespace

ShowGoToPalette::ShowGoToPalette(nc::panel::NetworkConnectionsManager &_net_mgr) : m_NetMgr(_net_mgr) {}

void ShowGoToPalette::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    PanelController *panel = _target.activePanelController;
    if( !panel )
        return;

    auto &storage = *NCAppDelegate.me.favoriteLocationsStorage;
    NSMutableArray<GoToPaletteEntry *> *entries = [NSMutableArray array];
    const auto fmt_opts = static_cast<loc_fmt::Formatter::RenderOptions>(loc_fmt::Formatter::RenderMenuTitle |
                                                                          loc_fmt::Formatter::RenderMenuTooltip);

    // Current directory first (so list is never empty when on native FS)
    if( panel.isUniform ) {
        std::string path = panel.currentDirectoryPath;
        if( !path.empty() ) {
            GoToPaletteEntry *e = [GoToPaletteEntry new];
            e.displayString = [NSString stringWithUTF8String:path.c_str()];
            e.context = [[AnyHolder alloc] initWithAny:std::any{path}];
            [entries addObject:e];
        }
    }

    // History: most recent last, show in reverse so recent first
    auto history = panel.history.All();
    for( size_t i = history.size(); i > 0; ) {
        --i;
        const ListingPromise &promise = history[i].get();
        auto rep = loc_fmt::ListingPromiseFormatter::Render(fmt_opts, promise);
        NSString *title = rep.menu_title ?: @"";
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        e.displayString = title;
        e.context = [[AnyHolder alloc] initWithAny:std::any{promise}];
        [entries addObject:e];
    }

    // Frecently used
    for( auto &loc : storage.FrecentlyUsed(80) ) {
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        e.displayString = [NSString stringWithUTF8String:loc->verbose_path.c_str()];
        e.context = [[AnyHolder alloc] initWithAny:std::any{loc}];
        [entries addObject:e];
    }

    // Favorites
    for( const auto &f : storage.Favorites() ) {
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        std::string display = f.title.empty() ? f.location->verbose_path : f.title;
        e.displayString = [NSString stringWithUTF8String:display.c_str()];
        e.context = [[AnyHolder alloc] initWithAny:std::any{f.location}];
        [entries addObject:e];
    }

    // Build a per-palette directory index lazily, on a background queue, without using Spotlight.
    auto indexed_paths = std::make_shared<std::vector<std::string>>();
    std::vector<std::string> roots;

    // Current directory (if native and known).
    if( panel.isUniform ) {
        if( !panel.currentDirectoryPath.empty() )
            roots.emplace_back(panel.currentDirectoryPath);
    }

    // User's home directory as a generic useful root.
    if( NSString *home = NSHomeDirectory() ) {
        if( const char *utf8 = home.UTF8String )
            roots.emplace_back(std::string(utf8));
    }

    GoToPaletteSearchBlock search_block = ^(NSString *query, void (^completion)(NSArray<NSString *> *paths)) {
        if( !completion )
            return;

        NSString *query_copy = query ? [query copy] : @"";
        void (^completion_copy)(NSArray<NSString *> *paths) = [completion copy];
        if( completion_copy == nil )
            return;

        dispatch_to_background([indexed_paths, roots, query_copy, completion_copy] {
            @autoreleasepool {
                std::vector<std::string> matches;

                const char *q_utf8 = query_copy.lowercaseString.UTF8String;
                const std::string needle = q_utf8 ? std::string(q_utf8) : std::string();
                if( !needle.empty() ) {
                    if( indexed_paths->empty() )
                        BuildDirectoryIndex(roots, *indexed_paths);

                    for( const auto &p : *indexed_paths ) {
                        if( ContainsCaseInsensitive(p, needle) ) {
                            matches.emplace_back(p);
                            if( matches.size() >= 128 )
                                break;
                        }
                    }
                }

                dispatch_to_main_queue([matches = std::move(matches), completion_copy] {
                    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:matches.size()];
                    for( const auto &p : matches ) {
                        NSString *s = [NSString stringWithUTF8String:p.c_str()];
                        if( s )
                            [result addObject:s];
                    }
                    completion_copy(result);
                });
            }
        });
    };

    GoToPaletteWindowController *wc = [[GoToPaletteWindowController alloc] initWithPanel:panel
                                                                                  state:_target
                                                                          networkManager:&m_NetMgr
                                                                                 entries:entries
                                                                              searchBlock:search_block];
    [wc showRelativeToWindow:_target.window];
}

} // namespace nc::panel::actions
