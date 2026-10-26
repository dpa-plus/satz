#!/usr/bin/env python3
"""Regenerate the checked-in Finder layout; normal packaging needs no module.

Development dependency: ds-store==1.3.1, mac-alias==2.2.3.
"""

from pathlib import Path

from ds_store import DSStore

destination = Path(__file__).with_name("dmg-layout.dsstore")
with DSStore.open(str(destination), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{240, 160}, {600, 330}}",
        "ShowToolbar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "SidebarWidth": 0,
        "ContainerShowSidebar": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 1,
        "backgroundColorRed": 0.97,
        "backgroundColorGreen": 0.98,
        "backgroundColorBlue": 0.99,
        "iconSize": 112.0,
        "textSize": 14.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showItemInfo": False,
        "showIconPreview": False,
        "labelOnBottom": True,
    }
    store["satz.app"]["Iloc"] = (165, 148)
    store["Applications"]["Iloc"] = (435, 148)
print(destination)
