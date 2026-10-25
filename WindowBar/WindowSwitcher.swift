//
//  WindowSwitcher.swift
//  WindowBar
//

import AppKit
import Observation
import SwiftUI

/// Shows previews of the frontmost app's windows while the user cycles through them
/// with macOS's "Move focus to next window" shortcut (Command-` by default).
///
/// WindowBar only observes the shortcut; macOS still handles it and moves focus as
/// usual. The overlay appears on the first press, highlights the window macOS focused,
/// and disappears when Command is released or Escape is pressed. Clicking a preview
/// jumps to that window, including windows on other Spaces.
@MainActor
final class WindowSwitcherController {
    private let inventory: WindowInventory
    private let previewStore: WindowPreviewStore
    private let model = WindowSwitcherModel()
    private var panel: WindowSwitcherPanel?
    private var eventMonitors: [Any] = []
    private var highlightTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Front-to-back window order of the frontmost app, recorded when Command goes
    /// down, i.e. before macOS reacts to Command-` and reorders the windows.
    private var stackingSnapshot: StackingSnapshot?

    private struct StackingSnapshot {
        let processIdentifier: pid_t
        let windowIDs: [CGWindowID]
        let takenAt: Date
    }

    private static let escapeKeyCode: UInt16 = 53

    init(inventory: WindowInventory, previewStore: WindowPreviewStore) {
        self.inventory = inventory
        self.previewStore = previewStore
    }

    func start() {
        guard eventMonitors.isEmpty else {
            return
        }

        // Global monitors observe events sent to other apps without consuming them,
        // so macOS's own window cycling keeps working. They rely on Accessibility.
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            Task { @MainActor in
                self?.handleKeyDown(keyCode: keyCode, modifiers: modifiers)
            }
        }) {
            eventMonitors.append(keyMonitor)
        }

        if let flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let modifiers = event.modifierFlags
            Task { @MainActor in
                self?.handleModifiersChanged(modifiers)
            }
        }) {
            eventMonitors.append(flagsMonitor)
        }
    }

    private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if keyCode == Self.escapeKeyCode {
            hide()
            return
        }

        guard NextWindowShortcut.current.matches(keyCode: keyCode, modifiers: modifiers) else {
            return
        }

        if model.isVisible {
            // macOS has moved focus again; follow it.
            scheduleHighlightUpdate()
        } else {
            show()
        }
    }

    private func handleModifiersChanged(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if !model.isVisible {
                recordStackingOrder()
            }
            return
        }

        hide()
    }

    private func recordStackingOrder() {
        guard isEnabled, let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return
        }

        let processIdentifier = frontmostApp.processIdentifier
        stackingSnapshot = StackingSnapshot(
            processIdentifier: processIdentifier,
            windowIDs: Self.frontToBackWindowIDs(processIdentifier: processIdentifier),
            takenAt: Date()
        )
    }

    /// On-screen normal windows of the app, front to back. The window server lists
    /// on-screen windows in stacking order.
    private static func frontToBackWindowIDs(processIdentifier: pid_t) -> [CGWindowID] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard
                info[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
                info[kCGWindowLayer as String] as? Int == 0
            else {
                return nil
            }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    /// Orders windows the way Command-` visits them: front to back as they were
    /// stacked before the first press. Windows that weren't on screen (other Spaces)
    /// can't be reached by Command-` and go last, in their existing order.
    private func orderedLikeWindowCycling(_ windows: [SidebarWindow], processIdentifier: pid_t) -> [SidebarWindow] {
        let stackingOrder: [CGWindowID]
        if let snapshot = stackingSnapshot,
           snapshot.processIdentifier == processIdentifier,
           Date().timeIntervalSince(snapshot.takenAt) < 5 {
            stackingOrder = snapshot.windowIDs
        } else {
            stackingOrder = Self.frontToBackWindowIDs(processIdentifier: processIdentifier)
        }

        let rankByWindowID = Dictionary(
            stackingOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return windows.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rankByWindowID[lhs.element.id] ?? Int.max
                let rhsRank = rankByWindowID[rhs.element.id] ?? Int.max
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Previews are part of the feature, so it only runs when they are on and allowed.
    private var isEnabled: Bool {
        let previewsSetting = UserDefaults.standard.object(forKey: "showWindowPreviews") as? Bool ?? true
        return previewsSetting && SystemPermissions.isScreenRecordingGranted && inventory.accessibilityEnabled
    }

    private func show() {
        guard isEnabled, let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return
        }

        inventory.refresh()
        guard let app = inventory.apps.first(where: { $0.processIdentifier == frontmostApp.processIdentifier }) else {
            return
        }

        let currentSpaceOnly = UserDefaults.standard.bool(forKey: "showCurrentSpaceOnly")
        let windows = orderedLikeWindowCycling(
            app.windows.filter { window in
                !currentSpaceOnly || inventory.isOnVisibleSpace(window)
            },
            processIdentifier: app.processIdentifier
        )

        // With a single window there is nothing to choose between.
        guard windows.count > 1 else {
            return
        }

        model.app = app
        model.windows = windows
        model.focusedWindowID = inventory.focusedWindowID(processIdentifier: app.processIdentifier)
        model.isVisible = true

        presentPanel()
        scheduleHighlightUpdate()

        previewTask?.cancel()
        previewTask = Task { [previewStore] in
            await previewStore.loadPreviews(for: windows.map(\.id))
        }
    }

    private func hide() {
        guard model.isVisible else {
            return
        }

        model.isVisible = false
        stackingSnapshot = nil
        highlightTask?.cancel()
        previewTask?.cancel()
        panel?.orderOut(nil)
    }

    /// Highlights the window macOS has focused, which is the one that stays in front
    /// when Command is released. macOS moves focus some time after the key press, so
    /// keep checking while the overlay is up instead of reading it once.
    private func scheduleHighlightUpdate() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.model.isVisible, let app = self.model.app else {
                    return
                }

                let focusedWindowID = self.inventory.focusedWindowID(processIdentifier: app.processIdentifier)
                if focusedWindowID != self.model.focusedWindowID {
                    self.model.focusedWindowID = focusedWindowID
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func select(_ window: SidebarWindow) {
        guard let app = model.app else {
            return
        }

        hide()
        inventory.focusWindow(window, in: app)
    }

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        guard let hostingView = panel.contentView as? NSHostingView<WindowSwitcherView> else {
            return
        }

        // Size the panel to its content and center it on the screen in use.
        let size = hostingView.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            let origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }

        panel.orderFrontRegardless()
    }

    private func makePanel() -> WindowSwitcherPanel {
        let panel = WindowSwitcherPanel()
        let view = WindowSwitcherView(
            model: model,
            previewStore: previewStore,
            onSelect: { [weak self] window in
                self?.select(window)
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}

@MainActor
@Observable
final class WindowSwitcherModel {
    var app: SidebarApp?
    var windows: [SidebarWindow] = []
    var focusedWindowID: CGWindowID?
    var isVisible = false
}

/// The "Move focus to next window" shortcut from Keyboard Shortcuts settings.
private struct NextWindowShortcut {
    private static let hotKeyID = "27"
    /// macOS's default: Command plus the key above Tab (` on US layouts).
    private static let defaultShortcut = NextWindowShortcut(keyCode: 50, modifiers: .command)

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static var current: NextWindowShortcut {
        guard
            let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
            let entry = hotKeys[hotKeyID] as? [String: Any],
            let value = entry["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Int],
            parameters.count == 3
        else {
            return defaultShortcut
        }

        // Parameters are (character, key code, modifier flags).
        return NextWindowShortcut(
            keyCode: UInt16(parameters[1]),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(parameters[2]))
        )
    }

    /// Ignores Shift so Command-Shift-` (previous window) also keeps the overlay up.
    func matches(keyCode pressedKeyCode: UInt16, modifiers pressedModifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control]
        return pressedKeyCode == keyCode
            && pressedModifiers.intersection(relevant) == modifiers.intersection(relevant)
    }
}

/// A floating, non-activating panel, so showing it never takes focus from the app
/// whose windows are being cycled.
private final class WindowSwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}

struct WindowSwitcherView: View {
    let model: WindowSwitcherModel
    let previewStore: WindowPreviewStore
    let onSelect: (SidebarWindow) -> Void

    private static let cardWidth: CGFloat = 220
    private static let maxColumns = 5

    private var columnCount: Int {
        min(max(model.windows.count, 1), Self.maxColumns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let app = model.app {
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }

                    Text(app.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: 12, alignment: .top), count: columnCount),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(model.windows) { window in
                    WindowSwitcherCard(
                        window: window,
                        preview: previewStore.previews[window.id],
                        isFocused: window.id == model.focusedWindowID,
                        width: Self.cardWidth,
                        onSelect: { onSelect(window) }
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.08, green: 0.1, blue: 0.13).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
        )
        .fixedSize()
    }
}

private struct WindowSwitcherCard: View {
    let window: SidebarWindow
    let preview: NSImage?
    let isFocused: Bool
    let width: CGFloat
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06))

                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(width: width - 16, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(window.spaceLabels.joined(separator: ", "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(8)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.18 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.85 : 0.08), lineWidth: isFocused ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
