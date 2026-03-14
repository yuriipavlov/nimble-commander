// Copyright (C) 2017 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "DefaultAction.h"
#include <string>
#include <vector>

namespace nc::panel::actions {

// external dependencies:
// config: filePanel.spotlight.format;
// config: filePanel.spotlight.maxCount;

/** Returns paths of folders matching the query (Spotlight, folders only). */
std::vector<std::string> SpotlightSearchFolders(const std::string &_query);

struct SpotlightSearch final : PanelAction {
    void Perform(PanelController *_target, id _sender) const override;
};

}; // namespace nc::panel::actions
