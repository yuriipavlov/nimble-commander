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
#include <unordered_set>
#include <cerrno>
#include <cstdio>
#include <system_error>
#include <atomic>
#include <memory>
#include <queue>
#include <sys/stat.h>

namespace nc::panel::actions {

namespace {

// Debug logging for filesystem search part of Go To palette.
static void LogGoToPaletteSearch(const char *_fmt, ...)
{
    FILE *f = std::fopen("/tmp/gotopalette_debug.txt", "a");
    if( !f )
        return;
    va_list ap;
    va_start(ap, _fmt);
    std::vfprintf(f, _fmt, ap);
    std::fprintf(f, "\n");
    va_end(ap);
    std::fclose(f);
}

// Streaming search: walk a few roots with strict limits and collect matching directories.
// Case-insensitive substring match (exact: name must contain query).
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

static void AddUniqueRoot(const std::string &_path, std::vector<std::string> &_roots, std::unordered_set<std::string> &_seen)
{
    if( _path.empty() )
        return;
    if( _seen.insert(_path).second )
        _roots.emplace_back(_path);
}

// Skip hidden folders: name starts with '.' (Unix) or BSD hidden attribute (UF_HIDDEN).
static bool IsFolderHidden(const std::filesystem::path &_p)
{
    std::string name = _p.filename().string();
    if( !name.empty() && name[0] == '.' )
        return true;
    struct stat st;
    if( ::stat(_p.c_str(), &st) != 0 )
        return false;
    return (st.st_flags & UF_HIDDEN) != 0;
}

// Budget: target ~2-3 sec index build. 70% HOME / 30% volumes. Fair split per level, BFS.
static const int kFolderSearchBudget = 2500;

// macOS TCC-protected subfolders under HOME (Documents, Desktop, etc.). Accessing them triggers
// a permission dialog when Full Disk Access is not granted. Check FDA once, then skip these if needed.
static const char* const kMacOSProtectedHomeSubdirs[] = {
    "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"
};
static bool IsMacOSProtectedHomeSubdir(const std::string &_name)
{
    for( const char* p : kMacOSProtectedHomeSubdirs ) {
        if( _name == p )
            return true;
    }
    return false;
}

// One-time probe: try to list a protected path. If we get permission denied, we do not have FDA.
// Doing this once at index build start avoids N dialogs when traversing HOME (per Apple docs).
static bool ProbeFullDiskAccess(const std::string &_home)
{
    namespace fs = std::filesystem;
    std::error_code ec;
    std::string probe = _home;
    while( !probe.empty() && (probe.back() == '/' || probe.back() == '\\') )
        probe.pop_back();
    if( probe.empty() )
        return false;
    fs::path docs(probe + "/Documents");
    if( !fs::exists(docs, ec) || !fs::is_directory(docs, ec) ) {
        ec.clear();
        return true;
    }
    fs::directory_iterator it(docs, fs::directory_options::skip_permission_denied, ec);
    if( ec && (ec == std::errc::permission_denied || ec.value() == EACCES || ec.value() == EPERM) )
        return false;
    ec.clear();
    return true;
}

// BFS + budget, collect all visited paths. Index built at palette open. Full HOME subtree when
// FDA is granted; otherwise skip TCC-protected HOME subdirs to avoid repeated permission dialogs.
static std::vector<std::string> BuildFolderIndexWithBudget(const std::vector<std::string> &_roots)
{
    namespace fs = std::filesystem;
    static const int kTotalPoints = kFolderSearchBudget;
    static const int kHomePercent = 70;
    static const int kHomeBudget = (kTotalPoints * kHomePercent) / 100;
    static const int kVolumesBudget = kTotalPoints - kHomeBudget;

    std::vector<std::string> index;
    index.reserve(kTotalPoints);
    std::unordered_set<std::string> visited;
    std::error_code ec;

    if( _roots.empty() )
        return index;

    auto normalize_path = [](std::string s) {
        while( !s.empty() && (s.back() == '/' || s.back() == '\\') )
            s.pop_back();
        return s;
    };

    std::string home_normalized = normalize_path(_roots[0]);
    const bool has_fda = ProbeFullDiskAccess(home_normalized);

    auto get_children = [&](const std::string &_dir) -> std::vector<std::string> {
        std::vector<std::string> out;
        fs::path p(_dir);
        if( !fs::exists(p, ec) || !fs::is_directory(p, ec) ) {
            ec.clear();
            return out;
        }
        fs::directory_iterator it(p, fs::directory_options::skip_permission_denied, ec);
        if( ec ) {
            ec.clear();
            return out;
        }
        for( ; it != fs::directory_iterator(); it.increment(ec) ) {
            if( ec ) {
                if( ec == std::errc::permission_denied || ec.value() == EACCES || ec.value() == EPERM )
                    break;
                ec.clear();
                continue;
            }
            if( !it->is_directory(ec) )
                continue;
            ec.clear();
            if( IsFolderHidden(it->path()) )
                continue;
            std::string name = it->path().filename().string();
            if( !has_fda && normalize_path(_dir) == home_normalized &&
                IsMacOSProtectedHomeSubdir(name) )
                continue;
            std::string child = normalize_path(it->path().lexically_normal().string());
            if( !child.empty() )
                out.push_back(child);
        }
        ec.clear();
        return out;
    };

    struct Task {
        std::string path;
        int budget;
    };
    std::queue<Task> queue;

    auto push_root = [&](const std::string &root_str, int budget) {
        std::string path_str = normalize_path(root_str);
        if( path_str.empty() || budget <= 0 )
            return;
        queue.push({path_str, budget});
    };

    if( _roots.size() == 1 ) {
        push_root(_roots[0], kHomeBudget);
    } else {
        push_root(_roots[0], kHomeBudget);
        int per_volume = kVolumesBudget / static_cast<int>(_roots.size() - 1);
        for( size_t i = 1; i < _roots.size(); ++i )
            push_root(_roots[i], per_volume);
    }

    while( !queue.empty() ) {
        Task t = queue.front();
        queue.pop();
        if( t.budget <= 0 )
            continue;
        if( !visited.insert(t.path).second )
            continue;
        index.push_back(t.path);

        int remaining = t.budget - 1;
        if( remaining <= 0 )
            continue;

        std::vector<std::string> children = get_children(t.path);
        if( children.empty() )
            continue;
        int n = static_cast<int>(children.size());
        int base = remaining / n;
        int extra = remaining % n;
        for( int i = 0; i < n; ++i ) {
            int cb = base + (i < extra ? 1 : 0);
            if( cb > 0 )
                queue.push({children[static_cast<size_t>(i)], cb});
        }
    }

    LogGoToPaletteSearch("Index built: %zu paths", index.size());
    return index;
}

// Filter index by folder name only (last path component). Case-insensitive substring. No duplicates. Max 128.
static std::vector<std::string> FilterIndexByFolderName(const std::vector<std::string> &_index,
                                                        const std::string &_needle)
{
    namespace fs = std::filesystem;
    static const std::size_t kMaxResults = 128;
    std::vector<std::string> result;
    result.reserve(std::min(kMaxResults, _index.size()));
    std::unordered_set<std::string> unique;
    if( _needle.empty() )
        return result;
    for( const auto &path_str : _index ) {
        if( result.size() >= kMaxResults )
            break;
        fs::path p(path_str);
        p = p.lexically_normal();
        std::string normalized = p.string();
        while( !normalized.empty() && (normalized.back() == '/' || normalized.back() == '\\') )
            normalized.pop_back();
        std::string dir_name = p.filename().string();
        if( dir_name.empty() && !normalized.empty() ) {
            size_t sep = normalized.find_last_of("/\\");
            dir_name = (sep != std::string::npos && sep + 1 < normalized.size())
                ? normalized.substr(sep + 1) : normalized;
        }
        if( dir_name.empty() )
            continue;
        if( !ContainsCaseInsensitive(dir_name, _needle) )
            continue;
        if( unique.insert(normalized).second )
            result.push_back(normalized);
    }
    return result;
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

    std::vector<std::string> roots;
    std::unordered_set<std::string> seen_roots;

    // HOME only (whole home tree, folders only, depth 5), then volumes.
    if( NSString *home = NSHomeDirectory() ) {
        if( const char *utf8 = home.UTF8String ) {
            std::string home_str(utf8);
            while( !home_str.empty() && home_str.back() == '/' )
                home_str.pop_back();
            if( !home_str.empty() )
                AddUniqueRoot(home_str, roots, seen_roots);
        }
    }

    // All mounted volumes (external disks + boot): each up to 5 levels.
    {
        std::error_code ec;
        std::filesystem::path volumes_path("/Volumes");
        if( std::filesystem::exists(volumes_path, ec) && std::filesystem::is_directory(volumes_path, ec) ) {
            for( std::filesystem::directory_iterator v(volumes_path, std::filesystem::directory_options::skip_permission_denied, ec); v != std::filesystem::directory_iterator(); v.increment(ec) ) {
                if( ec ) {
                    ec.clear();
                    continue;
                }
                if( !v->is_directory(ec) )
                    continue;
                if( ec ) {
                    ec.clear();
                    continue;
                }
                std::string vol = v->path().string();
                AddUniqueRoot(vol, roots, seen_roots);
            }
        }
    }

    auto roots_copy = std::make_shared<std::vector<std::string>>(roots);
    struct IndexState {
        std::vector<std::string> paths;
        std::atomic<bool> ready{false};
    };
    auto index_state = std::make_shared<IndexState>();

    GoToPaletteSearchBlock search_block = ^(NSString *query, void (^completion)(NSArray<NSString *> *paths)) {
        if( !completion )
            return;

        NSString *query_copy = query ? [query copy] : @"";
        void (^completion_copy)(NSArray<NSString *> *paths) = [completion copy];
        if( completion_copy == nil )
            return;

        const auto roots_ref = roots_copy;
        const auto state = index_state;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), [roots_ref, state, query_copy, completion_copy] {
            std::vector<std::string> matches;
            const char *q_utf8 = query_copy.lowercaseString.UTF8String;
            const std::string needle = q_utf8 ? std::string(q_utf8) : std::string();
            try {
                if( state->ready && !state->paths.empty() ) {
                    LogGoToPaletteSearch("FS search (index): query='%s'", needle.c_str());
                    matches = FilterIndexByFolderName(state->paths, needle);
                }
                // While index is building: no FS search, only history/favorites shown.
            } catch( const std::exception &e ) {
                LogGoToPaletteSearch("FS search exception: %s", e.what());
            } catch( ... ) {
                LogGoToPaletteSearch("FS search unknown exception");
            }

            NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:matches.size()];
            for( const auto &p : matches ) {
                NSString *s = [NSString stringWithUTF8String:p.c_str()];
                if( s )
                    [result addObject:s];
            }
            dispatch_async(dispatch_get_main_queue(), [result, completion_copy] {
                completion_copy(result);
            });
        });
    };

    GoToPaletteWindowController *wc = [[GoToPaletteWindowController alloc] initWithPanel:panel
                                                                                  state:_target
                                                                          networkManager:&m_NetMgr
                                                                                 entries:entries
                                                                              searchBlock:search_block];
    __weak GoToPaletteWindowController *wc_weak = wc;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), [roots_copy, index_state, wc_weak] {
        try {
            index_state->paths = BuildFolderIndexWithBudget(*roots_copy);
            index_state->ready = true;
        } catch( const std::exception &e ) {
            LogGoToPaletteSearch("Index build exception: %s", e.what());
        } catch( ... ) {
            LogGoToPaletteSearch("Index build unknown exception");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [wc_weak refilterCurrentQuery];
        });
    });
    [wc showRelativeToWindow:_target.window];
}

} // namespace nc::panel::actions
