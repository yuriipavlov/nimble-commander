// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.

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
