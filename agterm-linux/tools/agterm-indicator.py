#!/usr/bin/env python3
"""Small Ubuntu AppIndicator for Agterm agent-status sessions."""

import json
import os
import subprocess

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator
from gi.repository import GLib
from gi.repository import Gtk


AGTERMCTL = os.environ.get("AGTERMCTL", "/opt/agterm-linux/bin/agtermctl")
SOCKET = os.environ.get("AGTERM_SOCKET", os.path.expanduser("~/.local/share/agterm/agterm.sock"))


def ctl(*args):
    try:
        out = subprocess.check_output(
            [AGTERMCTL, *args, "--socket", SOCKET, "--json"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1.5,
        )
        return json.loads(out)
    except Exception:
        return None


def sessions(value, window_id):
    found = []

    def walk(node):
        if isinstance(node, dict):
            status = node.get("status")
            if status in {"active", "blocked", "completed"} and node.get("id"):
                found.append((window_id, node["id"], node.get("name") or node.get("title") or "Session", status))
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return found


class Indicator:
    def __init__(self):
        self.indicator = AppIndicator.Indicator.new(
            "agterm-agent-status", "utilities-terminal", AppIndicator.IndicatorCategory.APPLICATION_STATUS
        )
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.menu = Gtk.Menu()
        self.indicator.set_menu(self.menu)
        self.refresh()
        GLib.timeout_add(1000, self.refresh)

    def refresh(self):
        windows = ctl("window", "list") or []
        if isinstance(windows, dict):
            windows = windows.get("windows", [])
        all_sessions = []
        for window in windows:
            window_id = window.get("id") if isinstance(window, dict) else None
            if window_id:
                all_sessions.extend(sessions(ctl("tree", "--window", window_id) or {}, window_id))

        blocked = [item for item in all_sessions if item[3] == "blocked"]
        self.indicator.set_status(
            AppIndicator.IndicatorStatus.ATTENTION if blocked else AppIndicator.IndicatorStatus.ACTIVE
        )
        self.indicator.set_label(str(len(blocked)) if blocked else "", "99")
        for child in self.menu.get_children():
            self.menu.remove(child)

        title = Gtk.MenuItem(label=f"Agterm — {len(blocked)} waiting")
        title.set_sensitive(False)
        self.menu.append(title)
        self.menu.append(Gtk.SeparatorMenuItem())
        for window_id, session_id, name, status in sorted(all_sessions, key=lambda item: (item[3] != "blocked", item[2].lower())):
            item = Gtk.MenuItem(label=f"{status}: {name}")
            item.connect("activate", self.select, window_id, session_id)
            self.menu.append(item)
        self.menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Close indicator")
        quit_item.connect("activate", Gtk.main_quit)
        self.menu.append(quit_item)
        self.menu.show_all()
        return True

    @staticmethod
    def select(_item, window_id, session_id):
        subprocess.Popen(
            [AGTERMCTL, "session", "select", "--target", session_id, "--window", window_id, "--socket", SOCKET],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


Indicator()
Gtk.main()
