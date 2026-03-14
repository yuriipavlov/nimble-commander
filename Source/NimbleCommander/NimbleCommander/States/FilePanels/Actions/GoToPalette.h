// Copyright (C) 2026. Subject to GNU General Public License version 3.
// Go To palette: fuzzy search over recent/frequent directories.

#pragma once

#include "DefaultAction.h"
#include <Panel/NetworkConnectionsManager.h>

namespace nc::panel::actions {

struct ShowGoToPalette final : StateAction {
    ShowGoToPalette(nc::panel::NetworkConnectionsManager &_net_mgr);
    void Perform(MainWindowFilePanelState *_target, id _sender) const override;

private:
    nc::panel::NetworkConnectionsManager &m_NetMgr;
};

} // namespace nc::panel::actions
