//
//  ContentView.swift
//  WindowBar
//
//  Created by Nikolaos Lappas on 4/19/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var inventory = WindowInventory()
    @State private var sidebarSections: [SidebarSpaceSection] = []
    @State private var selectedEntryID: SidebarAppEntry.ID?
    @State private var hoveredEntryID: SidebarAppEntry.ID?
    @State private var isSidebarRevealed = false
    @State private var isHoveringSidebarRegion = false
    @State private var isSelectionTransitionInFlight = false
    @State private var dropTargetEntryID: SidebarAppEntry.ID?
    @State private var rememberedRailEntryID: SidebarAppEntry.ID?
    @State private var selectionTransitionTask: Task<Void, Never>?
    @State private var hoverExitWatchTask: Task<Void, Never>?
    @State private var hostingWindow: NSWindow?
    @State private var sidebarRegionFrame: CGRect = .zero
    @AppStorage("railVisualLeftShift") private var railVisualLeftShiftStorage: Double = 30
    @AppStorage("rememberRailScrollPosition") private var rememberRailScrollPosition = false
    @AppStorage("showCurrentSpaceOnly") private var showCurrentSpaceOnly = false
    @AppStorage("sidebarOnRight") private var sidebarOnRight = false
    private let windowPaneHeight: CGFloat = 470

    private var railVisualLeftShift: CGFloat {
        CGFloat(railVisualLeftShiftStorage)
    }

    private var apps: [SidebarApp] {
        inventory.apps
    }

    private var flatEntries: [SidebarAppEntry] {
        sidebarSections.flatMap(\.entries)
    }

    private var activeEntry: SidebarAppEntry? {
        let activeID = hoveredEntryID ?? selectedEntryID ?? flatEntries.first?.id
        return flatEntries.first(where: { $0.id == activeID })
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: sidebarOnRight ? .topTrailing : .topLeading) {
                HStack(alignment: .top, spacing: 0) {
                    if sidebarOnRight {
                        Spacer(minLength: 0)
                    }

                    if !sidebarOnRight {
                        sidebarEdgeActivator
                    }

                    if isSidebarRevealed {
                        ZStack(alignment: sidebarOnRight ? .topTrailing : .topLeading) {
                            SidebarRail(
                                sections: sidebarSections,
                                selectedEntryID: selectedEntryID,
                                hoveredEntryID: hoveredEntryID,
                                dropTargetEntryID: dropTargetEntryID,
                                onSelect: handleEntrySelection(_:),
                                onHover: handleEntryHover(_:),
                                onHide: inventory.hideApp(_:),
                                onQuit: inventory.quitApp(_:),
                                onDrop: { urls, entry in
                                    inventory.openFiles(urls, with: entry.app)
                                },
                                onDropChange: { entryID in
                                    dropTargetEntryID = entryID
                                },
                                onOpenSettings: openSettings,
                                onQuitApp: quitApp,
                                showCurrentSpaceOnly: $showCurrentSpaceOnly,
                                accessibilityEnabled: inventory.accessibilityEnabled,
                                sidebarOnRight: sidebarOnRight,
                                railVisualLeftShift: railVisualLeftShift,
                                onRailShiftChange: updateRailVisualLeftShift(_:),
                                rememberScrollPosition: rememberRailScrollPosition,
                                rememberedEntryID: $rememberedRailEntryID
                            )
                            .offset(x: sidebarOnRight ? railVisualLeftShift : -railVisualLeftShift)
                            .zIndex(1)

                            if let activeEntry {
                                WindowListPane(
                                    app: activeEntry.app,
                                    windowCountLabel: "\(activeEntry.windows.count) open windows",
                                    windows: activeEntry.windows,
                                    onWindowSelect: { window in
                                        handleWindowSelection(window, in: activeEntry.app)
                                    }
                                )
                                .offset(
                                    x: sidebarOnRight ? (railVisualLeftShift - 100) : (100 - railVisualLeftShift),
                                    y: paneOffsetY(in: proxy.size.height)
                                )
                                .transition(.move(edge: sidebarOnRight ? .trailing : .leading).combined(with: .opacity))
                                .zIndex(0)
                            }
                        }
                        // Keep the content as wide as the window list pane even when the
                        // pane is absent (e.g. a Space with no windows). Otherwise the
                        // narrow rail alone gets centered in the 452pt frame and drifts
                        // away from the screen edge.
                        .frame(minWidth: 340, alignment: sidebarOnRight ? .topTrailing : .topLeading)
                        .frame(width: 452)
                        .frame(maxHeight: .infinity, alignment: sidebarOnRight ? .topTrailing : .topLeading)
                    }

                    if sidebarOnRight {
                        sidebarEdgeActivator
                    }
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    sidebarRegionFrame = frame
                }
                .onHover(perform: handleSidebarRegionHover)
            }
            .padding(.vertical, 24)
            .coordinateSpace(name: "sidebarArea")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sidebarOnRight ? .trailing : .leading)
        .background(Color.clear)
        .background(HostingWindowReader { window in
            hostingWindow = window
        })
        .task {
            inventory.startMonitoring()
            rebuildSidebarSections()
            normalizeSelection()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                inventory.refreshAccessibilityStatus()
            }
        }
        .onChange(of: inventory.refreshToken) { _, _ in
            rebuildSidebarSections()
            normalizeSelection()
        }
        .animation(.easeOut(duration: 0.12), value: isSidebarRevealed)
        .animation(.easeOut(duration: 0.12), value: hoveredEntryID)
        .animation(.easeOut(duration: 0.12), value: dropTargetEntryID)
    }

    private var sidebarEdgeActivator: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: isSidebarRevealed ? 6 : 12)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    isSidebarRevealed = true
                }
            }
    }

    private func handleEntrySelection(_ entry: SidebarAppEntry) {
        selectedEntryID = entry.id
        beginSelectionTransition()

        if let topWindow = entry.windows.first {
            inventory.focusWindow(topWindow, in: entry.app)
        } else {
            inventory.activateApp(entry.app)
        }
    }

    private func handleWindowSelection(_ window: SidebarWindow, in app: SidebarApp) {
        beginSelectionTransition()
        inventory.focusWindow(window, in: app)
    }

    private func handleEntryHover(_ entryID: SidebarAppEntry.ID?) {
        hoveredEntryID = entryID

        if let entryID {
            selectedEntryID = entryID
        }
    }

    private func handleSidebarRegionHover(_ isHovering: Bool) {
        if isHovering {
            hoverExitWatchTask?.cancel()
            hoverExitWatchTask = nil
            isHoveringSidebarRegion = true
            return
        }

        // Switching Spaces makes the system report a hover exit even though the pointer
        // never moved. Ignore exits while the pointer is still over the sidebar so it
        // stays up through the transition, and hide it once the pointer really leaves.
        if isSidebarRevealed && isPointerInsideSidebarRegion() {
            watchForRealHoverExit()
            return
        }

        isHoveringSidebarRegion = false

        if isSelectionTransitionInFlight {
            return
        }

        hideSidebar()
    }

    /// After an ignored hover exit SwiftUI may not report another exit, so poll the
    /// pointer until it leaves the sidebar or a real hover event takes over.
    private func watchForRealHoverExit() {
        hoverExitWatchTask?.cancel()
        hoverExitWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, isSidebarRevealed else {
                    return
                }

                if !isPointerInsideSidebarRegion() {
                    hoverExitWatchTask = nil
                    handleSidebarRegionHover(false)
                    return
                }
            }
        }
    }

    private func isPointerInsideSidebarRegion() -> Bool {
        guard
            let hostingWindow,
            let contentHeight = hostingWindow.contentView?.bounds.height,
            !sidebarRegionFrame.isEmpty
        else {
            return false
        }

        // Screen coordinates have a bottom-left origin; SwiftUI's global space is
        // top-left relative to the window content, so flip the y axis.
        let windowPoint = hostingWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        let swiftUIPoint = CGPoint(x: windowPoint.x, y: contentHeight - windowPoint.y)
        return sidebarRegionFrame.contains(swiftUIPoint)
    }

    private func beginSelectionTransition() {
        selectionTransitionTask?.cancel()
        isSelectionTransitionInFlight = true

        selectionTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else {
                return
            }

            isSelectionTransitionInFlight = false

            if !isHoveringSidebarRegion {
                hideSidebar()
            }
        }
    }

    private func hideSidebar() {
        hoverExitWatchTask?.cancel()
        hoverExitWatchTask = nil
        hoveredEntryID = nil
        dropTargetEntryID = nil
        isSidebarRevealed = false
    }

    private func normalizeSelection() {
        guard !flatEntries.isEmpty else {
            selectedEntryID = nil
            hoveredEntryID = nil
            return
        }

        if let selectedEntryID, flatEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }

        selectedEntryID = flatEntries.first?.id
    }

    private func rebuildSidebarSections() {
        sidebarSections = buildSidebarSections()
    }

    private func updateRailVisualLeftShift(_ proposedValue: CGFloat) {
        railVisualLeftShiftStorage = Double(min(max(proposedValue, 0), 72))
    }

    private func openSettings() {
        AppDelegate.shared?.openSettingsWindow()
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func paneOffsetY(in totalHeight: CGFloat) -> CGFloat {
        let topInset: CGFloat = 24
        let bottomInset: CGFloat = 24
        let desiredCenterY = preferredPaneCenterY()
        let unclampedOriginY = desiredCenterY - (windowPaneHeight / 2)
        let maxOriginY = max(topInset, totalHeight - bottomInset - windowPaneHeight)
        let clampedOriginY = min(max(unclampedOriginY, topInset), maxOriginY)
        return clampedOriginY - topInset
    }

    private func preferredPaneCenterY() -> CGFloat {
        let railTopPadding: CGFloat = 18
        let iconSlotHeight: CGFloat = 34
        let iconSpacing: CGFloat = -4
        let sectionSpacing: CGFloat = 18
        let sectionLabelHeight: CGFloat = 18

        guard let activeID = hoveredEntryID ?? selectedEntryID else {
            return 160
        }

        var currentY = railTopPadding

        for (sectionIndex, section) in sidebarSections.enumerated() {
            if sectionIndex > 0 {
                currentY += sectionSpacing
            }

            currentY += sectionLabelHeight

            for entry in section.entries {
                if entry.id == activeID {
                    return currentY + (iconSlotHeight / 2)
                }

                currentY += iconSlotHeight + iconSpacing
            }
        }

        return 160
    }

    private func buildSidebarSections() -> [SidebarSpaceSection] {
        let currentSpaceIDs = Set(inventory.currentSpaceIDs())
        let appOrder = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.id, $0) })
        var windowsByAppAndSpace: [String: [SidebarWindow]] = [:]
        var appByAppAndSpace: [String: SidebarApp] = [:]
        var orderByAppAndSpace: [String: Int] = [:]
        var labelsBySpaceKey: [String: String] = [:]
        var sortKeysBySpaceKey: [String: SidebarSpaceSortKey] = [:]

        for app in apps {
            let visibleWindows = app.windows.filter { window in
                isWindowVisible(window, in: currentSpaceIDs)
            }

            for window in visibleWindows {
                for spaceGroup in spaceGroups(for: window) {
                    let compoundKey = "\(app.id)-\(spaceGroup.storageKey)"
                    windowsByAppAndSpace[compoundKey, default: []].append(window)
                    appByAppAndSpace[compoundKey] = app
                    orderByAppAndSpace[compoundKey] = appOrder[app.id] ?? .max
                    labelsBySpaceKey[spaceGroup.storageKey] = spaceGroup.label
                    sortKeysBySpaceKey[spaceGroup.storageKey] = spaceGroup.sortKey
                }
            }
        }

        let entries = windowsByAppAndSpace.compactMap { compoundKey, windows -> SidebarAppEntry? in
            guard
                let app = appByAppAndSpace[compoundKey],
                let spaceKey = compoundKey.split(separator: "-", maxSplits: 1).last.map(String.init)
            else {
                return nil
            }

            return SidebarAppEntry(
                app: app,
                spaceLabel: labelsBySpaceKey[spaceKey] ?? "Space Unknown",
                spaceKey: spaceKey,
                sortOrder: orderByAppAndSpace[compoundKey] ?? .max,
                windows: windows.sorted(by: sidebarWindowSort(lhs:rhs:)),
                isHidden: windows.allSatisfy { isWindowHidden($0, in: currentSpaceIDs) }
            )
        }

        return Dictionary(grouping: entries, by: \.spaceKey).keys
            .sorted { lhs, rhs in
                guard let lhsKey = sortKeysBySpaceKey[lhs], let rhsKey = sortKeysBySpaceKey[rhs] else {
                    return lhs < rhs
                }
                return lhsKey < rhsKey
            }
            .map { key in
                // Visible entries first, hidden ones after; app order within each group.
                let entries = (entries.filter { $0.spaceKey == key })
                    .sorted { lhs, rhs in
                        if lhs.isHidden != rhs.isHidden {
                            return !lhs.isHidden
                        }
                        return lhs.sortOrder < rhs.sortOrder
                    }
                return SidebarSpaceSection(
                    spaceKey: key,
                    label: labelsBySpaceKey[key] ?? "Space Unknown",
                    entries: entries
                )
            }
    }

    private func isWindowVisible(_ window: SidebarWindow, in currentSpaceIDs: Set<UInt64>) -> Bool {
        guard showCurrentSpaceOnly, !currentSpaceIDs.isEmpty else {
            return true
        }

        return !Set(window.rawSpaceIDs).isDisjoint(with: currentSpaceIDs)
    }

    /// A window that belongs to the current Space but isn't drawn on screen is minimized,
    /// or closed while its app keeps it alive. Windows on other Spaces are never on screen,
    /// so they can't be judged this way and count as visible.
    private func isWindowHidden(_ window: SidebarWindow, in currentSpaceIDs: Set<UInt64>) -> Bool {
        guard !window.isOnScreen else {
            return false
        }

        return !Set(window.rawSpaceIDs).isDisjoint(with: currentSpaceIDs)
    }

    private func spaceGroups(for window: SidebarWindow) -> [SidebarSpaceGroup] {
        if !window.rawSpaceIDs.isEmpty {
            return window.rawSpaceIDs.enumerated().map { index, spaceID in
                SidebarSpaceGroup(
                    storageKey: "space-\(spaceID)",
                    label: window.spaceLabels.indices.contains(index) ? window.spaceLabels[index] : "Space \(spaceID)",
                    sortKey: .space(spaceID)
                )
            }
        }

        if !window.spaceLabels.isEmpty {
            return window.spaceLabels.map { label in
                SidebarSpaceGroup(
                    storageKey: "label-\(label)",
                    label: label,
                    sortKey: .label(label)
                )
            }
        }

        return [
            SidebarSpaceGroup(
                storageKey: "unknown",
                label: "Space Unknown",
                sortKey: .unknown
            )
        ]
    }

    private func sidebarWindowSort(lhs: SidebarWindow, rhs: SidebarWindow) -> Bool {
        if lhs.isOnScreen != rhs.isOnScreen {
            return lhs.isOnScreen && !rhs.isOnScreen
        }

        return lhs.id < rhs.id
    }
}

private struct SidebarRail: View {
    let sections: [SidebarSpaceSection]
    let selectedEntryID: SidebarAppEntry.ID?
    let hoveredEntryID: SidebarAppEntry.ID?
    let dropTargetEntryID: SidebarAppEntry.ID?
    let onSelect: (SidebarAppEntry) -> Void
    let onHover: (SidebarAppEntry.ID?) -> Void
    let onHide: (SidebarApp) -> Void
    let onQuit: (SidebarApp) -> Void
    let onDrop: ([URL], SidebarAppEntry) -> Void
    let onDropChange: (SidebarAppEntry.ID?) -> Void
    let onOpenSettings: () -> Void
    let onQuitApp: () -> Void
    @Binding var showCurrentSpaceOnly: Bool
    let accessibilityEnabled: Bool
    let sidebarOnRight: Bool
    let railVisualLeftShift: CGFloat
    let onRailShiftChange: (CGFloat) -> Void
    let rememberScrollPosition: Bool
    @Binding var rememberedEntryID: SidebarAppEntry.ID?
    @State private var dragStartShift: CGFloat?
    @State private var utilityTooltipText: String?
    @State private var utilityTooltipTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 5) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if sections.isEmpty {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, alignment: .top)
                                .padding(.top, 8)
                        } else {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                if index > 0 {
                                    Divider()
                                        .overlay(.white.opacity(0.14))
                                        .padding(.vertical, 2)
                                }

                                VStack(spacing: 12) {
                                    Text(section.label)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 2)

                                    ForEach(section.entries) { entry in
                                        SidebarAppIcon(
                                        app: entry.app,
                                        badgeCount: entry.windows.count,
                                            isSelected: selectedEntryID == entry.id || hoveredEntryID == entry.id,
                                            isDropTarget: dropTargetEntryID == entry.id,
                                            isHidden: entry.isHidden,
                                            onSelect: {
                                                onSelect(entry)
                                            },
                                            onHover: { isHovering in
                                                onHover(isHovering ? entry.id : nil)
                                            },
                                            onHide: {
                                                onHide(entry.app)
                                            },
                                            onQuit: {
                                                onQuit(entry.app)
                                            },
                                            onDrop: { urls in
                                                onDrop(urls, entry)
                                            },
                                            onDropChange: { isTargeted in
                                                onDropChange(isTargeted ? entry.id : nil)
                                            }
                                        )
                                        .id(entry.id)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: RailEntryFramePreferenceKey.self,
                                                    value: [entry.id: geometry.frame(in: .named("railScrollView"))]
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .coordinateSpace(name: "railScrollView")
                .onPreferenceChange(RailEntryFramePreferenceKey.self) { frames in
                    guard rememberScrollPosition else {
                        return
                    }

                    rememberedEntryID = topVisibleEntryID(from: frames)
                }
                .onAppear {
                    restoreScrollPosition(with: proxy)
                }
                .onChange(of: sections.map(\.id)) { _, _ in
                    restoreScrollPosition(with: proxy)
                }
                .onChange(of: rememberScrollPosition) { _, isEnabled in
                    if !isEnabled {
                        rememberedEntryID = nil
                    } else {
                        restoreScrollPosition(with: proxy)
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    utilityTooltipArea(
                        accessibilityEnabled
                            ? "Show only windows from the current Space"
                            : "Accessibility access is missing, so the window list may include hidden helper windows"
                    ) {
                        compactRailToggle(
                            systemName: "square.stack.3d.up.fill",
                            helpText: "Show only current Space",
                            // Red signals that Accessibility permission is missing.
                            iconColor: accessibilityEnabled ? .white.opacity(0.8) : .red,
                            isOn: $showCurrentSpaceOnly
                        )
                    }

                    utilityTooltipArea("Open Settings") {
                        railActionButton(
                            systemName: "gearshape.fill",
                            helpText: "Open Settings",
                            action: onOpenSettings
                        )
                    }
                    utilityTooltipArea("Quit WindowBar") {
                        railActionButton(
                            systemName: "power",
                            helpText: "Quit WindowBar",
                            action: onQuitApp
                        )
                    }

                    utilityTooltipArea("Drag to fine-tune the sidebar position") {
                        SidebarPositionHandle(
                            currentShift: railVisualLeftShift,
                            sidebarOnRight: sidebarOnRight,
                            onShiftChange: onRailShiftChange,
                            dragStartShift: $dragStartShift
                        )
                    }
                }
                .overlay(alignment: .top) {
                    if let utilityTooltipText {
                        Text(utilityTooltipText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.black.opacity(0.78))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                            .frame(width: 160)
                            .offset(y: -44)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
            .frame(width: 88)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.1, blue: 0.13).opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 24, x: 8, y: 0)
            .padding(.leading, 2)
        }
    }

    private func railActionButton(
        systemName: String,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 48, height: 42)
                .overlay {
                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func compactRailToggle(
        systemName: String,
        helpText: String,
        iconColor: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(width: 48, height: 24)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .help(helpText)
    }

    private func utilityTooltipArea<Content: View>(
        _ text: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .onHover { isHovering in
                if isHovering {
                    utilityTooltipTask?.cancel()
                    utilityTooltipTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else {
                            return
                        }
                        utilityTooltipText = text
                    }
                } else {
                    utilityTooltipTask?.cancel()
                    utilityTooltipText = nil
                }
            }
    }

    private func restoreScrollPosition(with proxy: ScrollViewProxy) {
        guard rememberScrollPosition, let rememberedEntryID else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.none) {
                proxy.scrollTo(rememberedEntryID, anchor: .top)
            }
        }
    }

    private func topVisibleEntryID(from frames: [SidebarAppEntry.ID: CGRect]) -> SidebarAppEntry.ID? {
        let visibleFrames = frames.filter { $0.value.maxY > 0 }
        guard !visibleFrames.isEmpty else {
            return rememberedEntryID
        }

        return visibleFrames.min { lhs, rhs in
            let lhsDistance = lhs.value.minY >= 0 ? lhs.value.minY : abs(lhs.value.minY) + 1000
            let rhsDistance = rhs.value.minY >= 0 ? rhs.value.minY : abs(rhs.value.minY) + 1000
            return lhsDistance < rhsDistance
        }?.key
    }
}

private struct SidebarPositionHandle: View {
    let currentShift: CGFloat
    let sidebarOnRight: Bool
    let onShiftChange: (CGFloat) -> Void
    @Binding var dragStartShift: CGFloat?

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.34))
            .frame(width: 22, height: 4)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startShift = dragStartShift ?? currentShift
                        if dragStartShift == nil {
                            dragStartShift = currentShift
                        }

                        let proposedShift = sidebarOnRight
                            ? (startShift + value.translation.width)
                            : (startShift - value.translation.width)
                        onShiftChange(proposedShift)
                    }
                    .onEnded { _ in
                        dragStartShift = nil
                    }
            )
            .help("Drag to move the sidebar left or right")
    }
}

private struct RailEntryFramePreferenceKey: PreferenceKey {
    static var defaultValue: [SidebarAppEntry.ID: CGRect] = [:]

    static func reduce(value: inout [SidebarAppEntry.ID: CGRect], nextValue: () -> [SidebarAppEntry.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarAppIcon: View {
    let app: SidebarApp
    let badgeCount: Int
    let isSelected: Bool
    let isDropTarget: Bool
    let isHidden: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void
    let onHide: () -> Void
    let onQuit: () -> Void
    let onDrop: ([URL]) -> Void
    let onDropChange: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        // Dim apps whose windows are all minimized or closed.
                        .opacity(isHidden ? 0.4 : 1)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                        .opacity(isHidden ? 0.4 : 1)
                }

                if badgeCount > 1 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.78), in: Capsule())
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: 48, height: 42)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.1))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDropTarget ? Color.white.opacity(0.95) : .clear, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            )
            .scaleEffect(isSelected || isDropTarget ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .help("\(app.name) • \(badgeCount) windows")
        .contextMenu {
            Button("Show Most Recent Window", action: onSelect)
            Button("Hide \(app.name)", action: onHide)
            Button("Quit \(app.name)", action: onQuit)
        }
        .onHover(perform: onHover)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { isTargeted in
            onDropChange(isTargeted)
        }
    }
}

private struct WindowListPane: View {
    let app: SidebarApp
    let windowCountLabel: String
    let windows: [SidebarWindow]
    let onWindowSelect: (SidebarWindow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: 48, height: 48)
                    .overlay {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .padding(7)
                        } else {
                            Image(systemName: "app.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(windowCountLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer(minLength: 0)
            }
            .padding(20)

            Divider()
                .overlay(.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(windows) { window in
                        WindowRow(window: window) {
                            onWindowSelect(window)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 470)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 0.11, green: 0.13, blue: 0.17).opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.24), radius: 24, x: 10, y: 0)
        .padding(.leading, 12)
    }
}

private struct WindowRow: View {
    let window: SidebarWindow
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(window.ownerName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Spacer(minLength: 0)

                    if window.isMinimized {
                        Image(systemName: "dock.rectangle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                HStack(spacing: 8) {
                    Label(window.isOnScreen ? "On Screen" : "Hidden", systemImage: window.isOnScreen ? "eye.fill" : "eye.slash.fill")
                    Label(window.workspaceLabel, systemImage: "square.grid.2x2")

                    if window.isVisibleOnCurrentDisplay {
                        Label("Active Display", systemImage: "display")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(window.isMinimized ? 0.09 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .opacity(window.isMinimized ? 0.72 : 1)
        }
        .buttonStyle(.plain)
    }
}

private extension SidebarWindow {
    var workspaceLabel: String {
        guard !spaceLabels.isEmpty else {
            return "Space Unknown"
        }

        return spaceLabels.joined(separator: ", ")
    }
}

private struct SidebarSpaceSection: Identifiable {
    let spaceKey: String
    let label: String
    let entries: [SidebarAppEntry]

    var id: String { spaceKey }
}

/// Reports the AppKit window hosting the SwiftUI view, so the view can convert
/// screen coordinates (such as the pointer location) into its own space.
private struct HostingWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowResolvingView {
        let view = WindowResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowResolvingView, context: Context) {
        nsView.onResolve = onResolve
    }

    final class WindowResolvingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }
}

private struct SidebarAppEntry: Identifiable {
    let app: SidebarApp
    let spaceLabel: String
    let spaceKey: String
    let sortOrder: Int
    let windows: [SidebarWindow]
    /// True when none of the entry's windows are actually drawn on screen,
    /// e.g. they are minimized or closed but kept alive by the app.
    let isHidden: Bool

    var id: String { "\(app.id)-\(spaceKey)" }
}

private struct SidebarSpaceGroup {
    let storageKey: String
    let label: String
    let sortKey: SidebarSpaceSortKey
}

private enum SidebarSpaceSortKey: Comparable {
    case space(UInt64)
    case label(String)
    case unknown

    private var rank: Int {
        switch self {
        case .space: 0
        case .label: 1
        case .unknown: 2
        }
    }

    static func < (lhs: SidebarSpaceSortKey, rhs: SidebarSpaceSortKey) -> Bool {
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }

        switch (lhs, rhs) {
        case let (.space(lhsValue), .space(rhsValue)):
            return lhsValue < rhsValue
        case let (.label(lhsValue), .label(rhsValue)):
            return lhsValue.localizedStandardCompare(rhsValue) == .orderedAscending
        default:
            return false
        }
    }
}

#Preview {
    ContentView()
}
