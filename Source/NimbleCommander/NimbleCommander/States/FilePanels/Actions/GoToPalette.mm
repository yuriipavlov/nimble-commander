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

static const int g_IndexTimeLimitMs = 8000;
static const int g_IndexQuickPassMs = 400;
static const int g_IndexBackgroundTickMs = 1000;
static const int g_SystemRootsMaxDepth = 5;
static const int g_IndexCacheTTLSeconds = 900;
static const std::size_t g_IndexMaxPaths = 20000;
static const std::size_t g_IndexMaxNodesPerTick = 4096;
static const std::size_t g_DefaultFirstLevelChildrenLimit = 96;
static const auto g_ConfigIndexLibrary = "filePanel.gotoPalette.indexLibrary";
static const auto g_ConfigExcludeNames = "filePanel.gotoPalette.excludeNames";
static const auto g_ConfigExcludeGlobs = "filePanel.gotoPalette.excludeGlobs";
static const auto g_ConfigDebugLogging = "filePanel.gotoPalette.debugLogging";

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
    [[clang::no_destroy]] static InMemoryIndexCache cache;
    return cache;
}

static std::string NormalizePath(std::string _path)
{
    while( !_path.empty() && (_path.back() == '/' || _path.back() == '\\') )
        _path.pop_back();
    return _path;
}

struct LiveQueryState {
    std::mutex mutex;
    std::string latest_query;
};

struct CrawlNode {
    std::string path;
    int depth = 0;
};

struct IndexCrawlerState {
    std::queue<CrawlNode> home_queue;
    std::queue<CrawlNode> system_queue;
    std::vector<std::string> system_roots;
    std::size_t next_system_root = 0;
    std::unordered_set<std::string> visited;
    std::string home_root;
    bool has_fda = true;
    bool index_library = false;
    const std::unordered_set<std::string> *exclude_names = nullptr;
    const std::vector<std::string> *exclude_globs = nullptr;
    std::size_t produced_paths = 0;
    bool home_done = false;
};

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

static bool IsExistingDirectory(const std::string &_path)
{
    std::error_code ec;
    const std::filesystem::path p(_path);
    return std::filesystem::exists(p, ec) && std::filesystem::is_directory(p, ec);
}

static bool PathMatchesFolderQuery(const std::string &_path, const std::string &_query)
{
    if( _query.empty() )
        return false;
    const size_t sep = _path.rfind('/');
    const std::string &name = (sep != std::string::npos) ? _path.substr(sep + 1) : _path;
    return !name.empty() && ContainsCaseInsensitive(name, _query);
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

static std::vector<std::string> GetChildrenForIndexing(const IndexCrawlerState &_state,
                                                       const std::string &_dir,
                                                       bool _is_home)
{
    namespace fs = std::filesystem;
    std::vector<std::string> out;
    std::error_code ec;
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
        if( _is_home && !_state.index_library && IsAlwaysSkippedHomeSubdir(name) )
            continue;
        if( _is_home && !_state.has_fda && IsTCCProtectedHomeSubdir(name) )
            continue;
        std::string child = _dir + "/" + name;
        if( IsExcluded(child, name, *_state.exclude_names, *_state.exclude_globs) )
            continue;
        out.push_back(std::move(child));
    }
    return out;
}

static std::queue<CrawlNode> &ActiveQueue(IndexCrawlerState &_state)
{
    if( !_state.home_done )
        return _state.home_queue;
    while( _state.system_queue.empty() && _state.next_system_root < _state.system_roots.size() ) {
        _state.system_queue.push(CrawlNode{NormalizePath(_state.system_roots[_state.next_system_root]), 0});
        ++_state.next_system_root;
    }
    return _state.system_queue;
}

static bool IsTraversalDone(IndexCrawlerState &_state)
{
    if( !_state.home_done )
        return false;
    if( !_state.system_queue.empty() )
        return false;
    return _state.next_system_root >= _state.system_roots.size();
}

static std::vector<std::string> BuildFolderIndexPass(IndexCrawlerState &_state,
                                                     int _time_budget_ms,
                                                     std::size_t _max_nodes_this_pass,
                                                     bool &_done)
{
    using clock = std::chrono::steady_clock;
    std::vector<std::string> appended;
    appended.reserve(1024);
    const auto deadline = clock::now() + std::chrono::milliseconds(_time_budget_ms);
    std::size_t processed = 0;

    while( processed < _max_nodes_this_pass && clock::now() < deadline ) {
        auto &queue = ActiveQueue(_state);
        if( queue.empty() ) {
            if( !_state.home_done ) {
                _state.home_done = true;
                continue;
            }
            if( IsTraversalDone(_state) )
                break;
            continue;
        }

        CrawlNode node = std::move(queue.front());
        queue.pop();
        ++processed;

        const bool is_home = !_state.home_done;
        const int max_depth = is_home ? -1 : g_SystemRootsMaxDepth;

        if( !IsExistingDirectory(node.path) )
            continue;
        if( !_state.visited.insert(node.path).second )
            continue;
        if( _state.produced_paths < g_IndexMaxPaths ) {
            appended.emplace_back(node.path);
            ++_state.produced_paths;
        }
        if( _state.produced_paths >= g_IndexMaxPaths )
            break;

        if( max_depth >= 0 && node.depth >= max_depth )
            continue;
        for( auto &child : GetChildrenForIndexing(_state, node.path, is_home) )
            queue.push(CrawlNode{std::move(child), node.depth + 1});
    }

    _done = (_state.produced_paths >= g_IndexMaxPaths) || IsTraversalDone(_state);
    return appended;
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
    const auto add_plain_path_entry = [&](const std::string &_path) {
        if( _path.empty() )
            return;
        const std::string norm = normalizeForKey(_path);
        if( norm.empty() || !seen_paths.insert(norm).second )
            return;
        GoToPaletteEntry *e = [GoToPaletteEntry new];
        e.displayString = [NSString stringWithUTF8String:_path.c_str()];
        e.context = [[AnyHolder alloc] initWithAny:std::any{_path}];
        [entries addObject:e];
    };

    // Current directory first (so list is never empty when on native FS)
    if( panel.isUniform ) {
        std::string path = panel.currentDirectoryPath;
        add_plain_path_entry(path);
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

    // Go To palette's own most recent successful native paths.
    for( const auto &p : RecentGoToPaths() )
        add_plain_path_entry(p);

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

    // Stable first-tier paths for instant navigation (no deep indexing needed).
    {
        std::vector<std::string> defaults = {
            "/",
            "/Applications",
            "/System",
            "/Library",
            "/Users",
            "/Volumes",
            "/etc",
            "/private/etc",
            "/usr/local/etc",
            "/opt/homebrew/etc",
        };
        if( !home_root.empty() ) {
            defaults.emplace_back(home_root);
            defaults.emplace_back(home_root + "/Desktop");
            defaults.emplace_back(home_root + "/Downloads");
            defaults.emplace_back(home_root + "/Documents");
        }
        for( const auto &p : defaults ) {
            if( IsExistingDirectory(p) )
                add_plain_path_entry(p);
        }
    }

    // One-level children for key system roots (explicitly shallow).
    {
        const std::vector<std::string> shallow_roots = {
            "/",
            "/Applications",
            "/System",
            "/Library",
            "/Users",
            "/Volumes",
        };
        for( const auto &root : shallow_roots ) {
            if( !IsExistingDirectory(root) )
                continue;
            std::error_code ec;
            std::size_t added = 0;
            for( std::filesystem::directory_iterator it(root, std::filesystem::directory_options::skip_permission_denied, ec);
                 it != std::filesystem::directory_iterator();
                 it.increment(ec) ) {
                if( ec ) {
                    ec.clear();
                    continue;
                }
                if( !it->is_directory(ec) ) {
                    ec.clear();
                    continue;
                }
                std::string child = it->path().string();
                if( child.empty() )
                    continue;
                const std::string child_name = it->path().filename().string();
                if( IsFolderHidden(child_name) )
                    continue;
                add_plain_path_entry(child);
                if( ++added >= g_DefaultFirstLevelChildrenLimit )
                    break;
            }
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
    auto live_query = std::make_shared<LiveQueryState>();

    GoToPaletteSearchBlock search_block = ^(NSString *query, void (^completion)(NSArray<NSString *> *paths)) {
        if( !completion )
            return;

        NSString *query_copy = query ? [query copy] : @"";
        void (^completion_copy)(NSArray<NSString *> *paths) = [completion copy];
        if( completion_copy == nil )
            return;

        const char *q_utf8 = query_copy.lowercaseString.UTF8String;
        const std::string needle = q_utf8 ? std::string(q_utf8) : std::string();
        {
            const auto lock = std::lock_guard{live_query->mutex};
            live_query->latest_query = needle;
        }

        const auto state = index_state;
        dispatch_to_default([state, needle, completion_copy] {
            std::vector<std::string> matches;
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
    std::time_t cached_saved_at = 0;
    const bool debug_logging = GlobalConfig().Has(g_ConfigDebugLogging) && GlobalConfig().GetBool(g_ConfigDebugLogging);
    {
        auto &mem = IndexCacheMemory();
        const auto lock = std::lock_guard{mem.mutex};
        if( mem.key == cache_key && !mem.paths.empty() ) {
            index_state->paths.assign(mem.paths.begin(), mem.paths.begin() + std::min(mem.paths.size(), g_IndexMaxPaths));
            index_state->ready = !index_state->paths.empty();
            has_initial_cache = true;
            cache_is_fresh = IsCacheFresh(mem.saved_at);
            cached_saved_at = mem.saved_at;
        }
    }
    if( !has_initial_cache ) {
        if( auto persisted = LoadPersistedIndexCache(cache_file_path);
            persisted && persisted->key == cache_key && !persisted->paths.empty() ) {
            if( persisted->paths.size() > g_IndexMaxPaths )
                persisted->paths.resize(g_IndexMaxPaths);
            index_state->paths = persisted->paths;
            index_state->ready = !index_state->paths.empty();
            has_initial_cache = true;
            cache_is_fresh = IsCacheFresh(persisted->saved_at);
            cached_saved_at = persisted->saved_at;
            auto &mem = IndexCacheMemory();
            const auto lock = std::lock_guard{mem.mutex};
            mem.key = persisted->key;
            mem.saved_at = persisted->saved_at;
            mem.paths = std::move(persisted->paths);
        }
    }

    if( debug_logging ) {
        if( FILE *f = std::fopen("/tmp/nimble_goto_index_log.txt", "a") ) {
            std::fprintf(f,
                         "[GoTo] open: cache_key=%s, initial_paths=%zu, has_initial_cache=%d, cache_is_fresh=%d, "
                         "cached_saved_at=%lld\n",
                         cache_key.c_str(),
                         index_state->paths.size(),
                         has_initial_cache ? 1 : 0,
                         cache_is_fresh ? 1 : 0,
                         static_cast<long long>(cached_saved_at));
            std::fclose(f);
        }
    }

    __weak GoToPaletteWindowController *wc_weak = wc;
    const std::time_t now = std::time(nullptr);
    const bool refresh_due = !cache_is_fresh || cached_saved_at == 0 || (now - cached_saved_at) >= 60;
    if( refresh_due ) {
        dispatch_to_default([home_root_copy,
                             low_priority_roots_copy,
                             index_state,
                             live_query,
                             wc_weak,
                             index_library,
                             exclude_names,
                             exclude_globs,
                             has_initial_cache,
                             cache_key,
                             cache_file_path,
                             debug_logging] {
            try {
                const auto t_global_start = std::chrono::steady_clock::now();
                IndexCrawlerState crawler;
                crawler.home_root = NormalizePath(*home_root_copy);
                crawler.index_library = index_library;
                crawler.exclude_names = &exclude_names;
                crawler.exclude_globs = &exclude_globs;
                crawler.system_roots = *low_priority_roots_copy;
                if( !crawler.home_root.empty() )
                    crawler.home_queue.push(CrawlNode{crawler.home_root, 0});
                else
                    crawler.home_done = true;
                crawler.has_fda = crawler.home_root.empty() ? true : ProbeFullDiskAccess(crawler.home_root);

                std::vector<std::string> rebuilt_paths;
                rebuilt_paths.reserve(8192);

                std::unordered_set<std::string> seen_for_ui;
                {
                    const auto lock = std::lock_guard{index_state->mutex};
                    seen_for_ui.reserve(index_state->paths.size() * 2 + 1);
                    for( const auto &p : index_state->paths )
                        seen_for_ui.insert(p);
                }

                auto publish_delta = [&](const std::vector<std::string> &_batch) {
                    if( _batch.empty() )
                        return;
                    std::vector<std::string> delta;
                    delta.reserve(_batch.size());
                    for( const auto &p : _batch ) {
                        if( seen_for_ui.insert(p).second )
                            delta.push_back(p);
                    }
                    if( delta.empty() )
                        return;

                    {
                        const auto lock = std::lock_guard{index_state->mutex};
                        if( index_state->paths.size() < g_IndexMaxPaths ) {
                            const std::size_t room = g_IndexMaxPaths - index_state->paths.size();
                            index_state->paths.insert(index_state->paths.end(),
                                                      delta.begin(),
                                                      delta.begin() + std::min(room, delta.size()));
                        }
                        index_state->ready = true;
                    }

                    std::string current_query;
                    {
                        const auto lock = std::lock_guard{live_query->mutex};
                        current_query = live_query->latest_query;
                    }
                    const bool should_refilter =
                        !current_query.empty() &&
                        std::any_of(delta.begin(), delta.end(), [&](const std::string &p) {
                            return PathMatchesFolderQuery(p, current_query);
                        });
                    if( should_refilter )
                        dispatch_to_main_queue([wc_weak] { [wc_weak refilterCurrentQuery]; });
                };

                bool done = false;
                const int quick_budget = std::min(g_IndexQuickPassMs, g_IndexTimeLimitMs);
                const auto t_quick_start = std::chrono::steady_clock::now();
                auto quick = BuildFolderIndexPass(crawler, quick_budget, g_IndexMaxNodesPerTick, done);
                const auto t_quick_end = std::chrono::steady_clock::now();
                rebuilt_paths.insert(rebuilt_paths.end(), quick.begin(), quick.end());
                publish_delta(quick);

                int remaining_budget = g_IndexTimeLimitMs - quick_budget;
                int ticks = 0;
                while( !done && remaining_budget > 0 ) {
                    const int tick_budget = std::min(g_IndexBackgroundTickMs, remaining_budget);
                    auto batch = BuildFolderIndexPass(crawler, tick_budget, g_IndexMaxNodesPerTick, done);
                    rebuilt_paths.insert(rebuilt_paths.end(), batch.begin(), batch.end());
                    publish_delta(batch);
                    remaining_budget -= tick_budget;
                    ++ticks;
                }
                const auto t_global_end = std::chrono::steady_clock::now();

                {
                    const auto lock = std::lock_guard{index_state->mutex};
                    index_state->paths = rebuilt_paths;
                    if( index_state->paths.size() > g_IndexMaxPaths )
                        index_state->paths.resize(g_IndexMaxPaths);
                    index_state->ready = !index_state->paths.empty() || has_initial_cache;
                }

                PersistedIndex cache;
                cache.key = cache_key;
                cache.saved_at = std::time(nullptr);
                cache.paths = rebuilt_paths;
                if( cache.paths.size() > g_IndexMaxPaths )
                    cache.paths.resize(g_IndexMaxPaths);
                SavePersistedIndexCache(cache_file_path, cache);

                auto &mem = IndexCacheMemory();
                const auto mem_lock = std::lock_guard{mem.mutex};
                mem.key = cache.key;
                mem.saved_at = cache.saved_at;
                mem.paths = cache.paths;

                if( debug_logging ) {
                    const auto quick_ms =
                        std::chrono::duration_cast<std::chrono::milliseconds>(t_quick_end - t_quick_start).count();
                    const auto total_ms =
                        std::chrono::duration_cast<std::chrono::milliseconds>(t_global_end - t_global_start).count();
                    if( FILE *f = std::fopen("/tmp/nimble_goto_index_log.txt", "a") ) {
                        std::fprintf(f,
                                     "[GoTo] rebuild: cache_key=%s, total_paths=%zu, quick_ms=%lld, total_ms=%lld, "
                                     "ticks=%d, truncated=%d\n",
                                     cache_key.c_str(),
                                     rebuilt_paths.size(),
                                     static_cast<long long>(quick_ms),
                                     static_cast<long long>(total_ms),
                                     ticks,
                                     rebuilt_paths.size() > g_IndexMaxPaths ? 1 : 0);
                        std::fclose(f);
                    }
                }
            } catch( ... ) {
            }
            dispatch_to_main_queue([wc_weak] { [wc_weak refilterCurrentQuery]; });
        });
    }
    [wc showRelativeToWindow:_target.window];
}

} // namespace nc::panel::actions
