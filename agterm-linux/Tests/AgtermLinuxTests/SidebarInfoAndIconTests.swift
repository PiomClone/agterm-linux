import Foundation
import Testing
@testable import AgtermLinux
import agtermCore

@MainActor
struct SidebarInfoAndIconTests {
    @Test("hiding sidebar row icons reflects in snapshot")
    func iconVisibilityInSnapshot() {
        let session = Session(initialCwd: "/tmp", customName: "s1")
        let workspace = Workspace(name: "w1", sessions: [session])
        let store = AppStore(workspaces: [workspace], selectedSessionID: session.id)

        var settings = AppSettings()
        let defSnap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(defSnap.sections.first?.header?.iconVisible == true)
        #expect(defSnap.sections.first?.content[session.id]?.iconVisible == true)

        settings.hiddenInterfaceElements = [InterfaceElement.workspaceIcons.rawValue, InterfaceElement.sessionIcons.rawValue]
        let hiddenSnap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(hiddenSnap.sections.first?.header?.iconVisible == false)
        #expect(hiddenSnap.sections.first?.content[session.id]?.iconVisible == false)
    }

    @Test("session info display modes in snapshot")
    func sessionInfoDisplayModes() throws {
        let session = Session(initialCwd: "/tmp", customName: "s1")
        let workspace = Workspace(name: "w1", sessions: [session])
        let store = AppStore(workspaces: [workspace], selectedSessionID: session.id)
        let info = try SessionInfo.make(source: "**status**", markdown: true, hideAfter: 0).get()
        _ = store.setInfo(info, forSession: session.id)

        // Default is .always
        var settings = AppSettings()
        var snap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(snap.sections.first?.content[session.id]?.infoSpans?.first?.text == "status")

        // Off mode
        settings.sessionInfoDisplay = SessionInfoDisplay.off.rawValue
        snap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(snap.sections.first?.content[session.id]?.infoSpans == nil)

        // Flagged mode when not in flagged view
        settings.sessionInfoDisplay = SessionInfoDisplay.flagged.rawValue
        snap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(snap.sections.first?.content[session.id]?.infoSpans == nil)

        // Flagged mode when in flagged view
        store.setSidebarMode(.flagged)
        store.setFlag(true, forSession: session.id)
        snap = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil, expandedWorkspaceIDs: [workspace.id])
        #expect(snap.sections.first?.content[session.id]?.infoSpans?.first?.text == "status")
    }

    @Test("MarkdownProbe loads valid UTF-8 markdown file")
    func markdownProbeLoads() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "# Test\n\nHello world".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = MarkdownProbe.load(path: tmp.path)
        guard case .success(let probe) = result else {
            Issue.record("Expected markdown probe success")
            return
        }
        #expect(probe.markdown.contains("Hello world"))
    }
}
