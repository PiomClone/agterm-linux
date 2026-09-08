// Linux window-level settings application.
// Preferences construction and mutations are split across Settings*Page.swift and
// LinuxSettingsController.swift so the GTK adapter stays reviewable.
import CGtk
import agtermCore

@MainActor
extension AppController {
    func applyWindowButtonPlacement() {
        let settings = linuxSettingsStore().load()
        let hideButtons = LinuxDesktopEnvironment.hidesClientSideWindowButtons()
        let buttonsOnLeft = settings.effectiveWindowButtonsOnLeft
        let layout = hideButtons
            ? ":"
            : LinuxDesktopEnvironment.decorationLayout(buttonsOnLeft: buttonsOnLeft)
        if let settingsObj = gtk_settings_get_default() {
            "gtk-decoration-layout".withCString { cProp in
                layout.withCString { cVal in
                    let gtypeString = "gchararray".withCString { g_type_from_name($0) }
                    let gval = UnsafeMutablePointer<GValue>.allocate(capacity: 1)
                    memset(gval, 0, MemoryLayout<GValue>.size)
                    g_value_init(gval, gtypeString)
                    g_value_set_string(gval, cVal)
                    g_object_set_property(GOBJ(settingsObj), cProp, gval)
                    g_value_unset(gval)
                    gval.deallocate()
                }
            }
        }
        let showLeftOnSidebar = !hideButtons && buttonsOnLeft && store.sidebarVisible
        let showLeftOnContent = !hideButtons && buttonsOnLeft && !store.sidebarVisible
        let showRightOnContent = !hideButtons && !buttonsOnLeft

        let sidebarLayout = showLeftOnSidebar ? layout : ":"
        let contentLayout = (showLeftOnContent || showRightOnContent) ? layout : ":"

        if let sidebarHeader {
            sidebarLayout.withCString { adw_header_bar_set_decoration_layout(sidebarHeader, $0) }
            adw_header_bar_set_show_start_title_buttons(sidebarHeader, showLeftOnSidebar ? 1 : 0)
            adw_header_bar_set_show_end_title_buttons(sidebarHeader, 0)
        }
        if let contentHeader {
            contentLayout.withCString { adw_header_bar_set_decoration_layout(contentHeader, $0) }
            adw_header_bar_set_show_start_title_buttons(contentHeader, showLeftOnContent ? 1 : 0)
            adw_header_bar_set_show_end_title_buttons(contentHeader, showRightOnContent ? 1 : 0)
        }
        for header in [dashboardRuntime.header, zoomHeader].compactMap({ $0 }) {
            layout.withCString { adw_header_bar_set_decoration_layout(header, $0) }
            adw_header_bar_set_show_start_title_buttons(header, (!hideButtons && buttonsOnLeft) ? 1 : 0)
            adw_header_bar_set_show_end_title_buttons(header, (!hideButtons && !buttonsOnLeft) ? 1 : 0)
        }
    }

    func applyToolbarMode() {
        let mode = linuxSettingsStore().load().effectiveToolbarMode
        let visible: gboolean = mode == .hidden ? 0 : 1
        if let sidebarHeader { gtk_widget_set_visible(W(sidebarHeader), visible) }
        if let contentHeader { gtk_widget_set_visible(W(contentHeader), visible) }
        if let dashboardHeader = dashboardRuntime.header {
            gtk_widget_set_visible(W(dashboardHeader), visible)
        }
        if let zoomHeader { gtk_widget_set_visible(W(zoomHeader), visible) }
        if let bar = bottomBar {
            let padding: Int32 = mode == .normal ? 14 : 4
            gtk_widget_set_margin_top(W(bar), padding)
            gtk_widget_set_margin_bottom(W(bar), padding)
        }
        // The header moves the paned start child's minimum but not the CONTENT floor (it is an
        // `AdwToolbarView` top bar, not a child of `sidebarBox`), so re-lay out rather than re-measure.
        if let paned = splitView { applySidebarWidth(paned) }
    }

    func applyWindowTranslucency(settings: AppSettings? = nil) {
        let translucent = ((settings ?? linuxSettingsStore().load()).backgroundOpacity ?? 1) < 1
        "agterm-translucent".withCString {
            if translucent {
                gtk_widget_add_css_class(W(window), $0)
            } else {
                gtk_widget_remove_css_class(W(window), $0)
            }
        }
    }
}
