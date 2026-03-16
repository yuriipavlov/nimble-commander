// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "GoToPalette.h"
#include "ShowGoToPopup.h"
#include "../MainWindowFilePanelState.h"
#include "../PanelController.h"
#include "../PanelHistory.h"
#include "../Favorites.h"
#include "../ListingPromise.h"
#include "../Helpers/LocationFormatter.h"
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Bootstrap/Config.h>
#include <NimbleCommander/Core/AnyHolder.h>
#import "../Views/GoToPaletteWindowController.h"
#include <Panel/NetworkConnectionsManager.h>
#include <Foundation/Foundation.h>
#include <Base/algo.h>
#include <Base/CommonPaths.h>
#include <Base/dispatch_cpp.h>
#include <filesystem>
#include <vector>
#include <string>
#include <algorithm>
#include <unordered_set>
#include <cerrno>
#include <system_error>
#include <chrono>
#include <cstdio>
#include <memory>
#include <mutex>
#include <queue>
#include <fnmatch.h>
#include <fstream>
#include <optional>
#include <ctime>
#include <sstream>

namespace nc::panel::actions {

namespace {

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

static bool IsFolderHidden(const std::string &_name)
{
    return !_name.empty() && _name[0] == '.';
}

static const int g_IndexTimeLimitMs = 2000;
static const int g_SystemRootsMaxDepth = 5;
static const int g_IndexCacheTTLSeconds = 900;
static const auto g_ConfigIndexLibrary = "filePanel.gotoPalette.indexLibrary";
static const auto g_ConfigExcludeNames = "filePanel.gotoPalette.excludeNames";
static const auto g_ConfigExcludeGlobs = "filePanel.gotoPalette.excludeGlobs";

struct PersistedIndex {
    std::string key;
    std::time_t saved_at = 0;
    std::vector<std::string> paths;
};

// TCC-protected HOME subdirs — accessing without FDA triggers permission dialogs.
static const char *const g_TCCProtectedHomeSubdirs[] = {
    "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"
};
static bool IsTCCProtectedHomeSubdir(const std::string &_name)
{
    for( const char *p : g_TCCProtectedHomeSubdirs ) {
        if( _name == p )
            return true;
    }
    return false;
}

// HOME subdirs that are always skipped — too large and not useful for navigation.
static const char *const g_AlwaysSkippedHomeSubdirs[] = {
    "Library"
};
static bool IsAlwaysSkippedHomeSubdir(const std::string &_name)
{
    for( const char *p : g_AlwaysSkippedHomeSubdirs ) {
        if( _name == p )
            return true;
    }
    return false;
}

static std::string BuildCacheFilePath()
{
    return nc::base::CommonPaths::AppTemporaryDirectory() + "nimble-goto-index-cache-v1.txt";
}

static uint64_t FNV1a64(std::string_view _input) noexcept
{
    uint64_t hash = 1469598103934665603ull;
    for( const unsigned char c : _input ) {
        hash ^= c;
        hash *= 1099511628211ull;
    }
    return hash;
}

static std::string Hex64(uint64_t _v)
{
    std::ostringstream oss;
    oss << std::hex << _v;
    return oss.str();
}

static std::string BuildIndexCacheKey(const std::string &_home_root,
                                      const std::vector<std::string> &_low_priority_roots,
                                      bool _index_library,
                                      std::string_view _exclude_names_csv,
                                      std::string_view _exclude_globs_csv)
{
    std::string material = _home_root;
    material += '\x1f';
    material += (_index_library ? "1" : "0");
    material += '\x1f';
    material += _exclude_names_csv;
    material += '\x1f';
    material += _exclude_globs_csv;
    material += '\x1f';
    for( const auto &r : _low_priority_roots ) {
        material += r;
        material += ';';
    }
    return Hex64(FNV1a64(material));
}

static bool IsCacheFresh(std::time_t _saved_at)
{
    if( _saved_at <= 0 )
        return false;
    const std::time_t now = std::time(nullptr);
    if( now <= _saved_at )
        return true;
    return (now - _saved_at) <= g_IndexCacheTTLSeconds;
}

static std::optional<PersistedIndex> LoadPersistedIndexCache(const std::string &_path)
{
    std::ifstream in(_path, std::ios::in | std::ios::binary);
    if( !in )
        return std::nullopt;

    std::string magic;
    std::string key;
    std::string ts_line;
    std::string count_line;
    if( !std::getline(in, magic) || !std::getline(in, key) || !std::getline(in, ts_line) || !std::getline(in, count_line) )
        return std::nullopt;
    if( magic != "NC_GOTO_INDEX_CACHE_V1" )
        return std::nullopt;

    std::time_t saved_at = 0;
    std::size_t count = 0;
    try {
        saved_at = static_cast<std::time_t>(std::stoll(ts_line));
        count = static_cast<std::size_t>(std::stoull(count_line));
    } catch( ... ) {
        return std::nullopt;
    }

    std::vector<std::string> paths;
    paths.reserve(count);
    std::string line;
    while( std::getline(in, line) ) {
        if( !line.empty() )
            paths.emplace_back(std::move(line));
    }
    if( paths.size() > count )
        paths.resize(count);

    PersistedIndex cached;
    cached.key = std::move(key);
    cached.saved_at = saved_at;
    cached.paths = std::move(paths);
    return cached;
}

static void SavePersistedIndexCache(const std::string &_path, const PersistedIndex &_cache)
{
    std::ofstream out(_path, std::ios::out | std::ios::binary | std::ios::trunc);
    if( !out )
        return;
    out << "NC_GOTO_INDEX_CACHE_V1\n";
    out << _cache.key << '\n';
    out << static_cast<long long>(_cache.saved_at) << '\n';
    out << _cache.paths.size() << '\n';
    for( const auto &p : _cache.paths )
        out << p << '\n';
}

struct InMemoryIndexCache {
    std::mutex mutex;
    std::string key;
    std::time_t saved_at = 0;
    std::vector<std::string> paths;
};

static InMemoryIndexCache &IndexCacheMemory()
{
    static InMemoryIndexCache cache;
    return cache;
}

static std::vector<std::string> ParseCSVList(std::string_view _csv)
{
    std::vector<std::string> out;
    for( const auto &token : base::SplitByDelimiters(_csv, ",", false) ) {
        if( auto trimmed = nc::base::Trim(token); !trimmed.empty() )
            out.emplace_back(trimmed);
    }
    return out;
}

static bool MatchGlobCaseInsensitive(const std::string &_candidate, const std::string &_glob)
{
    if( _candidate.empty() || _glob.empty() )
        return false;
#ifdef FNM_CASEFOLD
    return fnmatch(_glob.c_str(), _candidate.c_str(), FNM_CASEFOLD) == 0;
#else
    std::string c = _candidate;
    std::string g = _glob;
    std::transform(c.begin(), c.end(), c.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    std::transform(g.begin(), g.end(), g.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return fnmatch(g.c_str(), c.c_str(), 0) == 0;
#endif
}

static bool IsExcluded(const std::string &_dir_path,
                       const std::string &_dir_name,
                       const std::unordered_set<std::string> &_exclude_names,
                       const std::vector<std::string> &_exclude_globs)
{
    if( _exclude_names.contains(_dir_name) )
        return true;
    for( const auto &glob : _exclude_globs ) {
        if( MatchGlobCaseInsensitive(_dir_name, glob) || MatchGlobCaseInsensitive(_dir_path, glob) )
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

// BFS with time limit. HOME is traversed first (max priority), then low-priority roots with depth cap.
// When _index_library is false, ~/Library is skipped (saves time; enable in preferences if needed).
static std::vector<std::string> BuildFolderIndex(const std::string &_home_root,
                                                 const std::vector<std::string> &_low_priority_roots,
                                                 bool _index_library,
                                                 const std::unordered_set<std::string> &_exclude_names,
                                                 const std::vector<std::string> &_exclude_globs)
{
    namespace fs = std::filesystem;
    using clock = std::chrono::steady_clock;

    std::vector<std::string> index;
    index.reserve(8192);
    std::unordered_set<std::string> visited;
    std::error_code ec;

    if( _home_root.empty() )
        return index;

    auto normalize_path = [](std::string s) {
        while( !s.empty() && (s.back() == '/' || s.back() == '\\') )
            s.pop_back();
        return s;
    };

    std::string home_normalized = normalize_path(_home_root);
    const bool has_fda = ProbeFullDiskAccess(home_normalized);
    const auto deadline = clock::now() + std::chrono::milliseconds(g_IndexTimeLimitMs);

    auto get_children = [&](const std::string &_dir, bool _is_home) -> std::vector<std::string> {
        std::vector<std::string> out;
        fs::directory_iterator it(_dir, fs::directory_options::skip_permission_denied, ec);
        if( ec ) {
            ec.clear();
            return out;
        }
        for( ; it != fs::directory_iterator(); it.increment(ec) ) {
            if( ec ) {
                ec.clear();
                continue;
            }
            if( !it->is_directory(ec) )
                continue;
            ec.clear();
            std::string name = it->path().filename().string();
            if( IsFolderHidden(name) )
                continue;
            if( _is_home && !_index_library && IsAlwaysSkippedHomeSubdir(name) )
                continue;
            if( !has_fda && _is_home && IsTCCProtectedHomeSubdir(name) )
                continue;
            std::string child = _dir + "/" + name;
            if( IsExcluded(child, name, _exclude_names, _exclude_globs) )
                continue;
            out.push_back(std::move(child));
        }
        ec.clear();
        return out;
    };

    auto traverse_root = [&](const std::string &_root, bool _is_home, int _max_depth) {
        std::queue<std::pair<std::string, int>> queue;
        queue.push({normalize_path(_root), 0});
        while( !queue.empty() && clock::now() < deadline ) {
            auto [path, depth] = std::move(queue.front());
            queue.pop();
            if( !visited.insert(path).second )
                continue;
            index.push_back(path);

            if( _max_depth >= 0 && depth >= _max_depth )
                continue;

            for( auto &child : get_children(path, _is_home) )
                queue.push({std::move(child), depth + 1});
        }
    };

    // Highest priority: HOME.
    traverse_root(home_normalized, true, -1);

    // Lower priority: system roots, shallow traversal only.
    for( const auto &root : _low_priority_roots ) {
        if( clock::now() >= deadline )
            break;
        traverse_root(root, false, g_SystemRootsMaxDepth);
    }

    return index;
}

// Filter index by folder name only (last path component). Case-insensitive substring. Max 192.
static std::vector<std::string> FilterIndexByFolderName(const std::vector<std::string> &_index,
                                                        const std::string &_needle)
{
    const std::size_t max_results = 192;
    std::vector<std::string> result;
    result.reserve(std::min(max_results, _index.size()));
    if( _needle.empty() )
        return result;
    for( const auto &path_str : _index ) {
        if( result.size() >= max_results )
            break;
        size_t sep = path_str.rfind('/');
        const std::string &dir_name = (sep != std::string::npos) ? path_str.substr(sep + 1) : path_str;
        if( dir_name.empty() )
            continue;
        if( !ContainsCaseInsensitive(dir_name, _needle) )
            continue;
        result.push_back(path_str);
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
    auto normalizeForKey = [](std::string s) {
        while( !s.empty() && (s.back() == '/' || s.back() == '\\') )
            s.pop_back();
        std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return s;
    };
    std::unordered_set<std::string> seen_paths;
    NSMutableArray<GoToPaletteEntry *> *entries = [NSMutableArray array];
    const auto fmt_opts = static_cast<loc_fmt::Formatter::RenderOptions>(loc_fmt::Formatter::RenderMenuTitle |
                                                                          loc_fmt::Formatter::RenderMenuTooltip);

    // Current directory first (so list is never empty when on native FS)
    if( panel.isUniform ) {
        std::string path = panel.currentDirectoryPath;
        if( !path.empty() && seen_paths.insert(normalizeForKey(path)).second ) {
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
        std::string key = title.UTF8String ? normalizeForKey(std::string(title.UTF8String)) : std::string();
        if( !key.empty() && seen_paths.insert(key).second ) {
            GoToPaletteEntry *e = [GoToPaletteEntry new];
            e.displayString = title;
            e.context = [[AnyHolder alloc] initWithAny:std::any{promise}];
            [entries addObject:e];
        }
    }

    // Frecently used
    for( auto &loc : storage.FrecentlyUsed(80) ) {
        if( !seen_paths.insert(normalizeForKey(loc->verbose_path)).second )
            continue;
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        e.displayString = [NSString stringWithUTF8String:loc->verbose_path.c_str()];
        e.context = [[AnyHolder alloc] initWithAny:std::any{loc}];
        [entries addObject:e];
    }

    // Favorites
    for( const auto &f : storage.Favorites() ) {
        if( !seen_paths.insert(normalizeForKey(f.location->verbose_path)).second )
            continue;
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        std::string display = f.title.empty() ? f.location->verbose_path : f.title;
        e.displayString = [NSString stringWithUTF8String:display.c_str()];
        e.context = [[AnyHolder alloc] initWithAny:std::any{f.location}];
        [entries addObject:e];
    }

    std::string home_root;

    // HOME is the top-priority root.
    if( NSString *home = NSHomeDirectory() ) {
        if( const char *utf8 = home.UTF8String ) {
            std::string home_str(utf8);
            while( !home_str.empty() && home_str.back() == '/' )
                home_str.pop_back();
            home_root = std::move(home_str);
        }
    }

    std::vector<std::string> low_priority_roots;
    std::unordered_set<std::string> seen_low_priority_roots;

    // Low-priority system roots: searched only if time remains and with shallow depth.
    {
        static const char *const g_SystemRoots[] = {
            "/etc",
            "/private/etc",
            "/usr/local/etc",
            "/opt/homebrew/etc",
        };
        std::error_code ec;
        for( const char *p : g_SystemRoots ) {
            std::filesystem::path root_path(p);
            if( !std::filesystem::exists(root_path, ec) || !std::filesystem::is_directory(root_path, ec) ) {
                ec.clear();
                continue;
            }
            ec.clear();
            AddUniqueRoot(root_path.string(), low_priority_roots, seen_low_priority_roots);
        }
    }

    auto home_root_copy = std::make_shared<std::string>(home_root);
    auto low_priority_roots_copy = std::make_shared<std::vector<std::string>>(low_priority_roots);
    struct IndexState {
        std::mutex mutex;
        std::vector<std::string> paths;
        bool ready = false;
    };
    auto index_state = std::make_shared<IndexState>();

    GoToPaletteSearchBlock search_block = ^(NSString *query, void (^completion)(NSArray<NSString *> *paths)) {
        if( !completion )
            return;

        NSString *query_copy = query ? [query copy] : @"";
        void (^completion_copy)(NSArray<NSString *> *paths) = [completion copy];
        if( completion_copy == nil )
            return;

        const auto state = index_state;
        dispatch_to_default([state, query_copy, completion_copy] {
            std::vector<std::string> matches;
            const char *q_utf8 = query_copy.lowercaseString.UTF8String;
            const std::string needle = q_utf8 ? std::string(q_utf8) : std::string();
            try {
                const auto lock = std::lock_guard{state->mutex};
                if( state->ready && !state->paths.empty() )
                    matches = FilterIndexByFolderName(state->paths, needle);
            } catch( ... ) {
            }

            NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:matches.size()];
            for( const auto &p : matches ) {
                NSString *s = [NSString stringWithUTF8String:p.c_str()];
                if( s )
                    [result addObject:s];
            }
            dispatch_to_main_queue([result, completion_copy] { completion_copy(result); });
        });
    };

    GoToPaletteWindowController *wc = [[GoToPaletteWindowController alloc] initWithPanel:panel
                                                                                  state:_target
                                                                          networkManager:m_NetMgr
                                                                                 entries:entries
                                                                              searchBlock:search_block];
    static GoToPaletteWindowController *g_CurrentPalette = nil;
    if( g_CurrentPalette != nil )
        g_CurrentPalette = nil;
    g_CurrentPalette = wc;
    const bool index_library = GlobalConfig().GetBool(g_ConfigIndexLibrary);
    const std::string exclude_names_csv = GlobalConfig().GetString(g_ConfigExcludeNames);
    const std::string exclude_globs_csv = GlobalConfig().GetString(g_ConfigExcludeGlobs);
    std::unordered_set<std::string> exclude_names;
    for( const auto &name : ParseCSVList(exclude_names_csv) )
        exclude_names.insert(name);
    const std::vector<std::string> exclude_globs = ParseCSVList(exclude_globs_csv);
    const std::string cache_key =
        BuildIndexCacheKey(*home_root_copy, *low_priority_roots_copy, index_library, exclude_names_csv, exclude_globs_csv);
    const std::string cache_file_path = BuildCacheFilePath();

    bool has_initial_cache = false;
    bool cache_is_fresh = false;
    {
        auto &mem = IndexCacheMemory();
        const auto lock = std::lock_guard{mem.mutex};
        if( mem.key == cache_key && !mem.paths.empty() ) {
            index_state->paths = mem.paths;
            index_state->ready = true;
            has_initial_cache = true;
            cache_is_fresh = IsCacheFresh(mem.saved_at);
        }
    }
    if( !has_initial_cache ) {
        if( auto persisted = LoadPersistedIndexCache(cache_file_path);
            persisted && persisted->key == cache_key && !persisted->paths.empty() ) {
            index_state->paths = persisted->paths;
            index_state->ready = true;
            has_initial_cache = true;
            cache_is_fresh = IsCacheFresh(persisted->saved_at);
            auto &mem = IndexCacheMemory();
            const auto lock = std::lock_guard{mem.mutex};
            mem.key = persisted->key;
            mem.saved_at = persisted->saved_at;
            mem.paths = std::move(persisted->paths);
        }
    }
    __weak GoToPaletteWindowController *wc_weak = wc;
    if( !cache_is_fresh ) {
        dispatch_to_default([home_root_copy,
                             low_priority_roots_copy,
                             index_state,
                             wc_weak,
                             index_library,
                             exclude_names,
                             exclude_globs,
                             cache_key,
                             cache_file_path] {
        try {
            const auto t0 = std::chrono::steady_clock::now();
            auto paths =
                BuildFolderIndex(*home_root_copy, *low_priority_roots_copy, index_library, exclude_names, exclude_globs);
            const auto t1 = std::chrono::steady_clock::now();
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
            if( FILE *f = std::fopen("/tmp/nimble_goto_index_log.txt", "w") ) {
                std::fprintf(f, "index built in %lld ms, %zu folders\n", static_cast<long long>(ms), paths.size());
                std::fclose(f);
            }
            const auto lock = std::lock_guard{index_state->mutex};
            index_state->paths = std::move(paths);
            index_state->ready = true;
            PersistedIndex cache;
            cache.key = cache_key;
            cache.saved_at = std::time(nullptr);
            cache.paths = index_state->paths;
            SavePersistedIndexCache(cache_file_path, cache);
            auto &mem = IndexCacheMemory();
            const auto mem_lock = std::lock_guard{mem.mutex};
            mem.key = cache.key;
            mem.saved_at = cache.saved_at;
            mem.paths = std::move(cache.paths);
        } catch( ... ) {
        }
        dispatch_to_main_queue([wc_weak] { [wc_weak refilterCurrentQuery]; });
        });
    }
    [wc showRelativeToWindow:_target.window];
}

} // namespace nc::panel::actions
