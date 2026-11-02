import CGtk
import agtermCore

@MainActor
enum PrimaryMenuAction: Int, CaseIterable {
    case newWindow = 1
    case newWorkspace
    case newSession
    case openDirectory
    case attachRemote
    case commandPalette
    case find
    case zoomOut
    case zoomReset
    case zoomIn
    case preferences
    case keyboardShortcuts
    case about
}

@MainActor
private final class AuxiliaryDialogContext {
    let controller: AppController
    let dialog: OpaquePointer?

    init(controller: AppController, dialog: OpaquePointer?) {
        self.controller = controller
        self.dialog = dialog
    }
}

@MainActor
extension AppController {
    func installPreferencesShortcut() {
        let action = "preferences".withCString { g_simple_action_new($0, nil) }
        attachControllerContext(to: action, windowID: windowID)
        connect(action, "activate", unsafeBitCast(onPreferencesShortcut, to: GCallback.self))
        g_action_map_add_action(window, action)

        guard let app = gApp else { return }
        "<Control>comma".withCString { accelerator in
            var accelerators: [UnsafePointer<CChar>?] = [accelerator, nil]
            "win.preferences".withCString { actionName in
                accelerators.withUnsafeMutableBufferPointer {
                    gtk_application_set_accels_for_action(APPW(app), actionName, $0.baseAddress)
                }
            }
        }
    }

    func showKeyboardShortcuts() {
        let dialog = OpaquePointer(adw_preferences_dialog_new())
        let dialogContext = prepareAuxiliaryDialog(dialog)
        let page = preferencesPage(
            "Keyboard Shortcuts", name: .keyMapping, icon: "input-keyboard-symbolic")
        let common = preferencesGroup("Resolved Bindings")
        for action in BuiltinAction.allCases {
            guard let chord = resolvedChord(for: action) else { continue }
            let row = OpaquePointer(adw_action_row_new())
            shortcutTitle(action).withCString { adw_preferences_row_set_title(cast(row), $0) }
            chord.displayString.withCString { adw_action_row_set_subtitle(cast(row), $0) }
            adw_preferences_group_add(cast(common), W(row))
        }
        for binding in fixedShortcutCatalog {
            let row = OpaquePointer(adw_action_row_new())
            binding.title.withCString { adw_preferences_row_set_title(cast(row), $0) }
            binding.shortcut.withCString { adw_action_row_set_subtitle(cast(row), $0) }
            adw_preferences_group_add(cast(common), W(row))
        }
        let preferences = OpaquePointer(adw_action_row_new())
        "Customize shortcuts".withCString { adw_preferences_row_set_title(cast(preferences), $0) }
        "Edit keymap.conf and review diagnostics".withCString {
            adw_action_row_set_subtitle(cast(preferences), $0)
        }
        adw_action_row_add_suffix(
            cast(preferences),
            W(
                preferencesButton(
                    "Open Settings", handler: unsafeBitCast(onShortcutPreferences, to: GCallback.self),
                    data: dialogContext)))
        adw_preferences_group_add(cast(common), W(preferences))
        adw_preferences_page_add(cast(page), cast(common))
        adw_preferences_dialog_add(cast(dialog), cast(page))
        adw_dialog_present(cast(dialog), W(window))
    }

    func showAbout() {
        let dialog = OpaquePointer(adw_about_dialog_new())
        "agterm".withCString { adw_about_dialog_set_application_name(dialog, $0) }
        LinuxAppMetadata.applicationID.withCString { adw_about_dialog_set_application_icon(dialog, $0) }
        "agterm-linux maintainers".withCString { adw_about_dialog_set_developer_name(dialog, $0) }
        LinuxAppMetadata.version.withCString { adw_about_dialog_set_version(dialog, $0) }
        "A workspace terminal for long-lived coding-agent and shell sessions.".withCString {
            adw_about_dialog_set_comments(dialog, $0)
        }
        "https://github.com/melonamin/agterm-linux".withCString {
            adw_about_dialog_set_website(dialog, $0)
        }
        "https://github.com/melonamin/agterm-linux/issues".withCString {
            adw_about_dialog_set_issue_url(dialog, $0)
        }
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        _ = prepareAuxiliaryDialog(dialog)
        adw_dialog_present(cast(dialog), W(window))
    }

    private func prepareAuxiliaryDialog(_ dialog: OpaquePointer?) -> UnsafeMutableRawPointer {
        attachControllerContext(to: dialog, windowID: windowID)
        let context = AuxiliaryDialogContext(controller: self, dialog: dialog)
        let data = Unmanaged.passRetained(context).toOpaque()
        connect(
            dialog, "closed", unsafeBitCast(onAuxiliaryDialogClosed, to: GCallback.self),
            data)
        if let dialog { auxiliaryDialogs.append(dialog) }
        noteUserActivity()
        suppressAutoFollow()
        return data
    }

    /// Force-close every auxiliary dialog (Keyboard Shortcuts, About) this window still owns: like the
    /// Settings dialog they are hosted AdwDialogs holding a `passRetained` on "closed", so that signal must
    /// be emitted at a point we control (see `.claude/rules/main-loop.md`). Tracked as a set because they are
    /// built ad hoc, with no single dialog slot to dismiss.
    func dismissAuxiliaryDialogs() {
        let open = auxiliaryDialogs
        auxiliaryDialogs.removeAll()
        for dialog in open { adw_dialog_force_close(cast(dialog)) }
    }

    /// An auxiliary dialog emitted "closed": drop it from the tracked set so a later dismissal cannot
    /// force-close a dialog libadwaita already destroyed. Idempotent — the window-close sweep clears the
    /// set first, so the handler it triggers finds nothing left to remove.
    func auxiliaryDialogDidClose(_ dialog: OpaquePointer?) {
        guard let dialog else { return }
        auxiliaryDialogs.removeAll { $0 == dialog }
    }

    func installPrimaryMenu(in header: OpaquePointer?) {
        let btn = linuxHeaderToggle(header, "open-menu-symbolic", "Main Menu", onPrimaryMenuToggle)
        if let btn {
            "primary-menu-button".withCString { gtk_widget_set_name(W(btn), $0) }
        }
        primaryMenuBtn = btn
    }

    var primaryMenuIsOpen: Bool {
        guard let popover = primaryMenuPopover else { return false }
        return gtk_widget_get_visible(W(popover)) != 0
    }

    func togglePrimaryMenu(anchor: OpaquePointer?) {
        if primaryMenuIsOpen {
            dismissPrimaryMenu()
        } else {
            showPrimaryMenu(anchor: anchor)
        }
    }

    func showPrimaryMenu(anchor: OpaquePointer?) {
        guard let anchor else { return }
        let heldSearchEntry = searchEntryCaptureSurvives(primaryMenuPopover)
        dismissPrimaryMenu(refocus: false)
        dismissSessionPicker(refocus: false)
        dismissContextMenu(refocus: false)

        guard let popover = op(gtk_popover_new()),
              let contentBox = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else { return }

        primaryMenuPopover = popover
        "primary-menu-popover".withCString { gtk_widget_set_name(W(popover), $0) }
        attachControllerContext(to: popover, windowID: windowID)
        connectPrimaryMenuClosed(popover)
        gtk_widget_set_parent(W(popover), W(anchor))
        gtk_popover_set_position(POPOVER(popover), GTK_POS_BOTTOM)
        gtk_widget_add_css_class(W(popover), "menu")
        gtk_widget_add_css_class(W(contentBox), "agterm-interface-panel")

        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(contentBox), 6)
        }
        gtk_widget_set_size_request(W(contentBox), interfacePanelWidth(260), -1)

        let newWindowShortcut = resolvedChord(for: .newWindow).map(LinuxChromeTooltip.label)
        let newWorkspaceShortcut = resolvedChord(for: .newWorkspace).map(LinuxChromeTooltip.label)
        let newSessionShortcut = resolvedChord(for: .newSession).map(LinuxChromeTooltip.label)
        let openDirShortcut = resolvedChord(for: .openDirectory).map(LinuxChromeTooltip.label)
        let paletteShortcut = resolvedChord(for: .commandPalette).map(LinuxChromeTooltip.label)
        let findShortcut = resolvedChord(for: .toggleSearch).map(LinuxChromeTooltip.label)

        addPrimaryMenuItem(to: contentBox, title: "New Window", action: .newWindow, shortcut: newWindowShortcut)
        addPrimaryMenuItem(to: contentBox, title: "New Workspace", action: .newWorkspace, shortcut: newWorkspaceShortcut)
        addPrimaryMenuItem(to: contentBox, title: "New Session", action: .newSession, shortcut: newSessionShortcut)
        addPrimaryMenuItem(to: contentBox, title: "Open Directory…", action: .openDirectory, shortcut: openDirShortcut)
        addPrimaryMenuItem(to: contentBox, title: "Attach Remote…", action: .attachRemote)

        addPrimaryMenuSeparator(to: contentBox)

        addPrimaryMenuItem(to: contentBox, title: "Command Palette…", action: .commandPalette, shortcut: paletteShortcut)
        addPrimaryMenuItem(to: contentBox, title: "Find in Terminal", action: .find, shortcut: findShortcut)
        addPrimaryZoomRow(to: contentBox)

        addPrimaryMenuSeparator(to: contentBox)

        addPrimaryMenuItem(to: contentBox, title: "Preferences", action: .preferences, shortcut: "Ctrl+,")
        addPrimaryMenuItem(to: contentBox, title: "Keyboard Shortcuts", action: .keyboardShortcuts)
        addPrimaryMenuItem(to: contentBox, title: "About agterm", action: .about)

        gtk_popover_set_child(POPOVER(popover), W(contentBox))
        popupPopover(popover, keepingCapture: heldSearchEntry)
    }

    func dismissPrimaryMenu(refocus: Bool = true) {
        guard let popover = primaryMenuPopover else { return }
        primaryMenuPopover = nil
        detachPopover(popover, popdown: true, refocus: refocus)
    }

    func primaryMenuDidClose(_ popover: OpaquePointer?) {
        guard let popover, popover == primaryMenuPopover else { return }
        primaryMenuPopover = nil
        detachPopover(popover, popdown: false)
    }

    func executePrimaryMenuAction(_ action: PrimaryMenuAction) {
        switch action {
        case .zoomOut:
            activeSurface()?.performBindingAction(FontBindingAction.decrease)
        case .zoomReset:
            activeSurface()?.performBindingAction(FontBindingAction.reset)
        case .zoomIn:
            activeSurface()?.performBindingAction(FontBindingAction.increase)
        case .newWindow:
            dismissPrimaryMenu()
            openNewWindow()
        case .newWorkspace:
            dismissPrimaryMenu()
            newWorkspace()
        case .newSession:
            dismissPrimaryMenu()
            newSession()
        case .openDirectory:
            dismissPrimaryMenu()
            openDirectory()
        case .attachRemote:
            dismissPrimaryMenu()
            attachRemote()
        case .commandPalette:
            dismissPrimaryMenu()
            showPalette()
        case .find:
            dismissPrimaryMenu()
            toggleSearch()
        case .preferences:
            dismissPrimaryMenu()
            showSettings()
        case .keyboardShortcuts:
            dismissPrimaryMenu()
            showKeyboardShortcuts()
        case .about:
            dismissPrimaryMenu()
            showAbout()
        }
    }

    private func addPrimaryMenuItem(
        to box: OpaquePointer?,
        title: String,
        action: PrimaryMenuAction,
        shortcut: String? = nil
    ) {
        guard let button = op(gtk_button_new()),
              let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)) else { return }
        gtk_button_set_has_frame(BUTTON(button), 0)
        gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(button), 1)

        let titleLabel = op(gtk_label_new(title))
        gtk_label_set_xalign(titleLabel, 0)
        gtk_widget_set_hexpand(W(titleLabel), 1)
        gtk_box_append(cast(row), W(titleLabel))

        if let shortcut, !shortcut.isEmpty {
            let shortcutLabel = op(gtk_label_new(shortcut))
            gtk_label_set_xalign(shortcutLabel, 1)
            gtk_widget_add_css_class(W(shortcutLabel), "dim-label")
            gtk_box_append(cast(row), W(shortcutLabel))
        }

        gtk_button_set_child(BUTTON(button), W(row))
        connect(button, "clicked", unsafeBitCast(onPrimaryMenuItemClicked as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            gpointer(bitPattern: action.rawValue))
        gtk_box_append(cast(box), W(button))
    }

    private func addPrimaryMenuSeparator(to box: OpaquePointer?) {
        guard let sep = op(gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)) else { return }
        gtk_widget_set_margin_top(W(sep), 4)
        gtk_widget_set_margin_bottom(W(sep), 4)
        gtk_box_append(cast(box), W(sep))
    }

    private func addPrimaryZoomRow(to box: OpaquePointer?) {
        guard let zoomRow = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)),
              let zoomControls = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)) else { return }
        gtk_widget_set_margin_start(W(zoomRow), 8)
        gtk_widget_set_margin_end(W(zoomRow), 8)
        gtk_widget_set_margin_top(W(zoomRow), 2)
        gtk_widget_set_margin_bottom(W(zoomRow), 2)

        let label = op(gtk_label_new("Zoom"))
        gtk_label_set_xalign(label, 0)
        gtk_widget_set_hexpand(W(label), 1)
        gtk_box_append(cast(zoomRow), W(label))

        gtk_widget_add_css_class(W(zoomControls), "linked")

        func addZoomButton(_ icon: String?, _ text: String?, _ tip: String, _ action: PrimaryMenuAction) {
            let btn: OpaquePointer?
            if let icon {
                btn = op(gtk_button_new_from_icon_name(icon))
            } else if let text {
                btn = op(gtk_button_new_with_label(text))
            } else {
                return
            }
            guard let btn else { return }
            gtk_widget_set_tooltip_text(W(btn), tip)
            gtk_button_set_has_frame(BUTTON(btn), 1)
            gtk_widget_set_focus_on_click(W(btn), 0)
            connect(btn, "clicked", unsafeBitCast(onPrimaryMenuItemClicked as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
                gpointer(bitPattern: action.rawValue))
            gtk_box_append(cast(zoomControls), W(btn))
        }

        addZoomButton("zoom-out-symbolic", nil, "Zoom Out", .zoomOut)
        addZoomButton(nil, "100%", "Normal Size", .zoomReset)
        addZoomButton("zoom-in-symbolic", nil, "Zoom In", .zoomIn)

        gtk_box_append(cast(zoomRow), W(zoomControls))
        gtk_box_append(cast(box), W(zoomRow))
    }

    private func connectPrimaryMenuClosed(_ popover: OpaquePointer) {
        connect(popover, "closed", unsafeBitCast(onPrimaryMenuClosed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
    }
}

private func shortcutTitle(_ action: BuiltinAction) -> String {
    action.rawValue.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
}

private let fixedShortcutCatalog: [(title: String, shortcut: String)] = [
    ("Preferences", "ctrl+,"),
    ("Quick switch session", "ctrl+tab"),
    ("Previous session", "ctrl+pageup"),
    ("Next session", "ctrl+pagedown"),
    ("Focus left pane", "ctrl+1 / ctrl+shift+left"),
    ("Focus right pane", "ctrl+2 / ctrl+shift+right"),
    ("Move session up", "ctrl+shift+up"),
    ("Move session down", "ctrl+shift+down"),
    ("Move workspace up", "ctrl+shift+pageup"),
    ("Move workspace down", "ctrl+shift+pagedown"),
    ("Increase font size", "ctrl+= / ctrl++"),
    ("Decrease font size", "ctrl+-"),
    ("Reset font size", "ctrl+0"),
]

private let onPreferencesShortcut: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { action, _, _ in
    MainActor.assumeIsolated { controllerForObject(action)?.showSettings() }
}
private let onShortcutPreferences: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<AuxiliaryDialogContext>.fromOpaque(data).takeUnretainedValue()
        let controller = context.controller
        let dialog = context.dialog
        adw_dialog_force_close(cast(dialog))
        controller.showSettings(page: .keyMapping)
    }
}
private let onAuxiliaryDialogClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<AuxiliaryDialogContext>.fromOpaque(data).takeRetainedValue()
        context.controller.auxiliaryDialogDidClose(context.dialog)
        context.controller.resumeAutoFollow()
    }
}
