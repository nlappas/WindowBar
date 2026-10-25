//
//  WindowInventory.swift
//  WindowBar
//
//  Created by Nikolaos Lappas on 4/23/26.
//

import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation
import Observation
import CoreFoundation
import OSLog

@MainActor
@Observable
final class WindowInventory {
    private static let windowWorkspaceDictionaryKey = "kCGWindowWorkspace"
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    var apps: [SidebarApp] = []
    var accessibilityEnabled = false
    var lastRefreshDate: Date?
    var refreshToken = 0

    private var refreshTask: Task<Void, Never>?
    private var spaceChangeTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var loggedUnknownSpaceWindowIDs = Set<CGWindowID>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isMonitoring = false
    private var cachedWindowTitles: [CGWindowID: String] = [:]
    private var cachedWindowTitlesBySignature: [WindowTitleSignature: String] = [:]
    private var windowUseTask: Task<Void, Never>?
    /// How recently each window was in front, as an increasing stamp. Only windows on a
    /// showing Space get restamped, so windows on other Spaces keep the order they had
    /// when the user last worked there. Not observed: it changes constantly.
    @ObservationIgnored private var windowUseStamps: [CGWindowID: UInt64] = [:]
    @ObservationIgnored private var nextWindowUseStamp: UInt64 = 0

    func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        isMonitoring = true
        accessibilityEnabled = isAccessibilityTrusted(prompt: false)
        installWorkspaceObservers()
        refresh()

        // Refresh as soon as the user switches Spaces instead of waiting for the next
        // periodic refresh, so the "current Space only" list updates immediately.
        // Space-change messages are only posted on NSWorkspace's own notification center.
        spaceChangeTask = Task { [weak self] in
            let workspace = NSWorkspace.shared
            let spaceChanges = workspace.notificationCenter.messages(of: workspace, for: .activeSpaceDidChange)
            for await _ in spaceChanges {
                guard let self, !Task.isCancelled else {
                    return
                }
                self.refresh()
            }
        }

        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self.refresh()
            }
        }

        // Track window use more often than the full refresh, so a window the user
        // touched just before switching Spaces is still recorded as the latest.
        windowUseTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self.recordWindowUse()
            }
        }
    }

    func refresh() {
        refreshAccessibilityStatus()
        apps = loadApps()
        recordWindowUse()
        pruneWindowUseStamps()
        lastRefreshDate = Date()
        refreshToken += 1
    }

    /// The window among `windows` that was most recently in front, or nil if none of
    /// them has been seen on screen yet.
    func mostRecentlyUsedWindow(in windows: [SidebarWindow]) -> SidebarWindow? {
        windows
            .filter { windowUseStamps[$0.id] != nil }
            .max { (windowUseStamps[$0.id] ?? 0) < (windowUseStamps[$1.id] ?? 0) }
    }

    /// Stamps every on-screen window in stacking order, frontmost newest. Within one app
    /// on one Space, the stacking order is the order the user last used its windows.
    private func recordWindowUse() {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        let frontToBackWindowIDs = windowInfo.compactMap { info -> CGWindowID? in
            guard info[kCGWindowLayer as String] as? Int == 0 else {
                return nil
            }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }

        for windowID in frontToBackWindowIDs.reversed() {
            nextWindowUseStamp += 1
            windowUseStamps[windowID] = nextWindowUseStamp
        }
    }

    private func pruneWindowUseStamps() {
        let knownWindowIDs = Set(apps.flatMap { $0.windows.map(\.id) })
        windowUseStamps = windowUseStamps.filter { knownWindowIDs.contains($0.key) }
    }

    func requestAccessibilityAccess() {
        accessibilityEnabled = isAccessibilityTrusted(prompt: true)
    }

    func refreshAccessibilityStatus() {
        accessibilityEnabled = isAccessibilityTrusted(prompt: false)
    }

    func currentSpaceIDs() -> [UInt64] {
        SpaceResolver().currentSpaceIDs()
    }

    /// Whether the window is on a Space showing on any display right now.
    func isOnVisibleSpace(_ window: SidebarWindow) -> Bool {
        !Set(window.rawSpaceIDs).isDisjoint(with: currentSpaceIDs())
    }

    /// The window number of the app's focused window, read through Accessibility.
    func focusedWindowID(processIdentifier: pid_t) -> CGWindowID? {
        guard accessibilityEnabled else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedWindow = axElementValue(for: kAXFocusedWindowAttribute, on: applicationElement) else {
            return nil
        }

        return axWindowID(of: focusedWindow)
    }

    /// The Core Graphics window number behind an Accessibility window element.
    /// Uses the private `_AXUIElementGetWindow` call, which works for all apps; the
    /// public-looking "AXWindowNumber" attribute isn't provided on this system.
    private func axWindowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        if AXUIElementGetWindowSPI(element, &windowID) == .success, windowID != 0 {
            return windowID
        }

        return axIntValue(for: "AXWindowNumber", on: element).map(CGWindowID.init)
    }

    func openAccessibilitySettings() {
        guard let settingsURL = Self.accessibilitySettingsURL else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    var accessibilityClientName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    var accessibilityBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unavailable"
    }

    var accessibilityExecutablePath: String {
        Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "Unavailable"
    }

    func activateApp(_ app: SidebarApp) {
        guard let runningApplication = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            return
        }

        runningApplication.unhide()
        runningApplication.activate()
    }

    /// Relaunching an already-running app sends it a "reopen" event, the same one a Dock
    /// click sends, so apps with no open windows bring their main window back.
    private func reopenApp(_ app: SidebarApp) {
        guard let applicationURL = app.applicationURL else {
            activateApp(app)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
    }

    func hideApp(_ app: SidebarApp) {
        NSRunningApplication(processIdentifier: app.processIdentifier)?.hide()
        refresh()
    }

    func quitApp(_ app: SidebarApp) {
        NSRunningApplication(processIdentifier: app.processIdentifier)?.terminate()
    }

    func openFiles(_ urls: [URL], with app: SidebarApp) {
        guard
            let applicationURL = app.applicationURL,
            !urls.isEmpty
        else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        for url in urls {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, _ in }
        }
    }

    func focusWindow(_ window: SidebarWindow, in app: SidebarApp) {
        guard accessibilityEnabled else {
            activateApp(app)
            return
        }

        // A new click replaces any focus still in progress, so overlapping attempts
        // can't send extra Space switches and overshoot.
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            let spaceResolver = SpaceResolver()
            let currentSpaceIDs = Set(spaceResolver.currentSpaceIDs())
            // Decide this before switching: afterwards the target Space is current.
            let isOnAnotherSpace = !window.rawSpaceIDs.isEmpty
                && Set(window.rawSpaceIDs).isDisjoint(with: currentSpaceIDs)

            focusLogger.info("focusWindow: \(app.name, privacy: .public) window \(window.id) on spaces \(window.rawSpaceIDs, privacy: .public), current spaces \(currentSpaceIDs.sorted(), privacy: .public), on another Space: \(isOnAnotherSpace)")

            if isOnAnotherSpace, let targetSpaceID = window.rawSpaceIDs.first {
                // The switch animates, and Accessibility may only list the target
                // window once its Space is showing, so wait for the switch to land.
                // Retry the swipe once if the first one didn't take.
                var didSwitch = false
                for attempt in 1...2 where !didSwitch {
                    let started = spaceResolver.switchToSpace(targetSpaceID)
                    // Each step animates, so allow up to two seconds.
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else {
                            return
                        }
                        if spaceResolver.currentSpaceIDs().contains(targetSpaceID) {
                            didSwitch = true
                            break
                        }
                    }
                    let spacesNow = Set(spaceResolver.currentSpaceIDs())
                    focusLogger.info("focusWindow: switch attempt \(attempt) started: \(started), reached target: \(didSwitch), current spaces now \(spacesNow.sorted(), privacy: .public)")

                    // Only retry if nothing moved; a partial move means the switch is
                    // working and retrying would overshoot.
                    if spacesNow != currentSpaceIDs {
                        break
                    }
                }
            }

            let exactWindow = exactWindowElement(windowID: window.id, processIdentifier: app.processIdentifier)
            let matchedWindow = exactWindow
                ?? matchingWindowElement(for: window, processIdentifier: app.processIdentifier)
            focusLogger.info("focusWindow: exact AX match: \(exactWindow != nil), any AX match: \(matchedWindow != nil)")

            guard let matchedWindow else {
                if isOnAnotherSpace {
                    // Activating or reopening the app would bring forward whichever of
                    // its windows is already visible (e.g. one on another display).
                    // Bring forward this exact window instead; macOS then switches to
                    // its Space.
                    self.focusWindowByID(window.id, processIdentifier: app.processIdentifier)
                } else {
                    // Accessibility doesn't list windows an app has closed but kept alive
                    // (Notes and Activity Monitor do this). Reopen the app like a Dock
                    // click, which makes it show its main window again.
                    self.reopenApp(app)
                }
                return
            }

            focusWindowElement(
                matchedWindow,
                windowID: window.id,
                processIdentifier: app.processIdentifier,
                isMinimized: window.isMinimized
            )
            self.refresh()
        }
    }

    private func matchingWindowElement(for window: SidebarWindow, processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowElements = accessibleWindowElements(for: applicationElement)
        guard !windowElements.isEmpty else {
            return nil
        }

        return bestMatchingWindowElement(for: window, in: windowElements)
    }

    private func exactWindowElement(windowID: CGWindowID, processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowElements = accessibleWindowElements(for: applicationElement)
        guard !windowElements.isEmpty else {
            return nil
        }

        return windowElements.first { element in
            axWindowID(of: element) == windowID
        }
    }

    private func accessibleWindowElements(for applicationElement: AXUIElement) -> [AXUIElement] {
        if let windows = axArrayValue(for: kAXWindowsAttribute, on: applicationElement), !windows.isEmpty {
            return windows
        }

        var windows: [AXUIElement] = []

        if let mainWindow = axElementValue(for: kAXMainWindowAttribute, on: applicationElement) {
            windows.append(mainWindow)
        }

        if let focusedWindow = axElementValue(for: kAXFocusedWindowAttribute, on: applicationElement),
           !windows.contains(where: { CFEqual($0, focusedWindow) }) {
            windows.append(focusedWindow)
        }

        return deduplicatedAccessibleWindowElements(windows)
    }

    private func deduplicatedAccessibleWindowElements(_ windows: [AXUIElement]) -> [AXUIElement] {
        var seenWindowNumbers = Set<Int>()
        var deduplicated: [AXUIElement] = []

        for window in windows {
            if let windowNumber = axIntValue(for: "AXWindowNumber", on: window) {
                if seenWindowNumbers.insert(windowNumber).inserted {
                    deduplicated.append(window)
                }
                continue
            }

            let title = bestAXTitle(for: window, bundleIdentifier: nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let frame = CGRect(
                origin: axPointValue(for: kAXPositionAttribute, on: window) ?? .zero,
                size: axSizeValue(for: kAXSizeAttribute, on: window) ?? .zero
            )

            let isDuplicate = deduplicated.contains { existing in
                let existingTitle = bestAXTitle(for: existing, bundleIdentifier: nil)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existingFrame = CGRect(
                    origin: axPointValue(for: kAXPositionAttribute, on: existing) ?? .zero,
                    size: axSizeValue(for: kAXSizeAttribute, on: existing) ?? .zero
                )

                return existingTitle == title && framesRoughlyMatch(existingFrame, frame)
            }

            if !isDuplicate {
                deduplicated.append(window)
            }
        }

        return deduplicated
    }

    private func focusWindowElement(
        _ element: AXUIElement,
        windowID: CGWindowID,
        processIdentifier: pid_t,
        isMinimized: Bool
    ) {
        if isMinimized {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, NSNumber(value: false))
        }

        focusWindowByID(windowID, processIdentifier: processIdentifier)

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, element)
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, NSNumber(value: true))
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, NSNumber(value: true))
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Asks the window server to bring a specific window to the front and make it key,
    /// without going through Accessibility. Works for windows on other Spaces, which
    /// macOS then switches to.
    private func focusWindowByID(_ windowID: CGWindowID, processIdentifier: pid_t) {
        var processSerialNumber = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
        guard LegacyGetProcessForPID(processIdentifier, &processSerialNumber) == noErr else {
            return
        }

        _ = PrivateWindowFocusSPI.setFrontProcessWithOptions?(&processSerialNumber, UInt32(windowID), cpsUserGenerated)
        makeKeyWindow(&processSerialNumber, windowID: windowID)
    }

    private func installWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let notificationNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for name in notificationNames {
            let observer = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func loadApps() -> [SidebarApp] {
        guard let rawWindowInfo = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        // The list can hold the same process ID more than once: apps that are quitting
        // report -1, which happens to many at once around sleep and display changes.
        // Skip those and keep the first entry for any other duplicate.
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.processIdentifier > 0 && !$0.isTerminated }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let spaceResolver = SpaceResolver()
        var cgWindowsByProcess: [pid_t: [CGWindowMetadata]] = [:]
        var appOrderByProcess: [pid_t: Int] = [:]
        // Windows skipped as invisible helpers, so Accessibility can't re-add them.
        var excludedWindowIDs = Set<CGWindowID>()

        for (index, info) in rawWindowInfo.enumerated() {
            guard
                let processID = info[kCGWindowOwnerPID as String] as? pid_t,
                processID != currentProcessID,
                let application = runningApps[processID],
                application.activationPolicy == .regular,
                !application.isHidden
            else {
                continue
            }

            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0
            else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0 {
                continue
            }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? application.localizedName ?? "Unknown App"
            if ownerName == "Window Server" || ownerName == "Dock" {
                continue
            }

            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary ?? [:]) ?? .zero
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let workspaceID = (info[Self.windowWorkspaceDictionaryKey] as? NSNumber)?.intValue
            let title = info[kCGWindowName as String] as? String
            let rawSpaceIDs = spaceResolver.rawSpaceIDs(for: windowID)

            // A window assigned to several Spaces is "sticky" (joins all Spaces). If it is
            // also off-screen it has been ordered out, so it is an invisible helper window
            // (e.g. Xcode keeps one around) rather than something the user can see or focus.
            // Including it would make the app appear to have a window on every Space.
            if !isOnScreen && rawSpaceIDs.count > 1 {
                excludedWindowIDs.insert(windowID)
                continue
            }

            // Every real window, even a hidden one, belongs to a Space. An off-screen
            // window with no Space has been ordered out entirely: a closed panel the app
            // keeps alive (e.g. Activity Monitor's CPU History) or a menu-bar strip.
            // Listing it would show a phantom entry under "Space Unknown".
            if !isOnScreen && rawSpaceIDs.isEmpty {
                excludedWindowIDs.insert(windowID)
                continue
            }

            let metadata = CGWindowMetadata(
                windowID: windowID,
                title: title,
                frame: bounds,
                isOnScreen: isOnScreen,
                fallbackWorkspaceID: workspaceID,
                spaceLabels: spaceResolver.spaceLabels(for: windowID, fallbackWorkspaceID: workspaceID),
                rawSpaceIDs: rawSpaceIDs
            )

            cgWindowsByProcess[processID, default: []].append(metadata)
            appOrderByProcess[processID] = min(appOrderByProcess[processID] ?? index, index)
        }

        if accessibilityEnabled {
            let axWindowsByProcess = accessibilityMetadata(for: runningApps).mapValues { windows in
                windows.filter { window in
                    guard let windowID = window.windowID else {
                        return true
                    }
                    return !excludedWindowIDs.contains(windowID)
                }
            }
            let apps = buildAppsFromAccessibility(
                runningApps: runningApps,
                appOrderByProcess: appOrderByProcess,
                cgWindowsByProcess: cgWindowsByProcess,
                axWindowsByProcess: axWindowsByProcess,
                spaceResolver: spaceResolver
            )

            if !apps.isEmpty {
                return removingWindowsOnUnknownSpaces(apps, spaceResolver: spaceResolver)
            }
        }

        let apps = buildAppsFromCGWindows(
            runningApps: runningApps,
            appOrderByProcess: appOrderByProcess,
            cgWindowsByProcess: cgWindowsByProcess
        )
        return removingWindowsOnUnknownSpaces(apps, spaceResolver: spaceResolver)
    }

    /// Drops windows that aren't on any Space Mission Control knows about, and apps
    /// left with no windows. Such windows can't be placed in a Space section or
    /// switched to, so they'd only appear as "Space Unknown" entries.
    private func removingWindowsOnUnknownSpaces(_ apps: [SidebarApp], spaceResolver: SpaceResolver) -> [SidebarApp] {
        apps.compactMap { app in
            let knownWindows = app.windows.filter { window in
                let isKnown = window.rawSpaceIDs.contains(where: spaceResolver.isKnownSpace)
                if !isKnown {
                    logWindowOnUnknownSpace(window, appName: app.name)
                }
                return isKnown
            }

            guard !knownWindows.isEmpty else {
                return nil
            }

            return SidebarApp(
                processIdentifier: app.processIdentifier,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                applicationURL: app.applicationURL,
                icon: app.icon,
                windows: knownWindows
            )
        }
    }

    /// Debug builds log each skipped window once, rather than on every refresh.
    private func logWindowOnUnknownSpace(_ window: SidebarWindow, appName: String) {
        #if DEBUG
        guard loggedUnknownSpaceWindowIDs.insert(window.id).inserted else {
            return
        }

        inventoryLogger.debug("Skipping \(appName, privacy: .public) window \(window.id) \"\(window.title, privacy: .public)\": unknown Space \(window.rawSpaceIDs, privacy: .public), on screen: \(window.isOnScreen), frame \(String(describing: window.frame), privacy: .public)")
        #endif
    }

    private func buildAppsFromAccessibility(
        runningApps: [pid_t: NSRunningApplication],
        appOrderByProcess: [pid_t: Int],
        cgWindowsByProcess: [pid_t: [CGWindowMetadata]],
        axWindowsByProcess: [pid_t: [AccessibilityWindowMetadata]],
        spaceResolver: SpaceResolver
    ) -> [SidebarApp] {
        let groupedApps = runningApps.values
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
            .compactMap { app -> GroupedAppWindows? in
                let processID = app.processIdentifier
                let cgWindows = cgWindowsByProcess[processID] ?? []
                let axWindows = axWindowsByProcess[processID] ?? []

                let windows: [SidebarWindow]
                if !axWindows.isEmpty {
                    var availableCGWindows = cgWindows
                    let axDerivedWindows = axWindows.enumerated().map { index, axWindow in
                        let matchedCGWindow = bestMatch(for: axWindow, candidates: availableCGWindows)
                        if let matchedCGWindow {
                            availableCGWindows.removeAll { $0.windowID == matchedCGWindow.windowID }
                        }

                        let fallbackWindowID = axWindow.windowID ?? matchedCGWindow?.windowID ?? CGWindowID(index)
                        let fallbackSpaceLabels = axWindow.windowID.map { spaceResolver.spaceLabels(for: $0, fallbackWorkspaceID: nil) } ?? []

                        return SidebarWindow(
                            id: fallbackWindowID,
                            title: resolvedWindowTitle(
                                processIdentifier: processID,
                                frame: axWindow.frame,
                                cgTitle: matchedCGWindow?.title,
                                accessibilityTitle: axWindow.title,
                                cachedTitle: matchedCGWindow.flatMap { cachedWindowTitles[$0.windowID] }
                            ),
                            ownerName: app.localizedName ?? "Unknown App",
                            frame: axWindow.frame,
                            spaceLabels: matchedCGWindow?.spaceLabels ?? fallbackSpaceLabels,
                            // Without a Core Graphics match, look the Space up by the
                            // window number Accessibility reported.
                            rawSpaceIDs: matchedCGWindow?.rawSpaceIDs
                                ?? axWindow.windowID.map { spaceResolver.rawSpaceIDs(for: $0) }
                                ?? [],
                            isOnScreen: matchedCGWindow?.isOnScreen ?? true,
                            isMinimized: false,
                            isVisibleOnCurrentDisplay: matchedCGWindow?.isVisibleOnCurrentDisplay ?? axWindow.isVisibleOnCurrentDisplay
                        )
                    }

                    let unmatchedCGWindows = availableCGWindows
                        .filter(isLikelyStandaloneCGWindow(_:))
                        .filter { cgWindow in
                            shouldIncludeUnmatchedCGWindow(cgWindow, alongside: axDerivedWindows)
                        }
                        .map { cgWindow in
                            SidebarWindow(
                                id: cgWindow.windowID,
                                title: resolvedWindowTitle(
                                    processIdentifier: processID,
                                    frame: cgWindow.frame,
                                    cgTitle: cgWindow.title,
                                    accessibilityTitle: nil,
                                    cachedTitle: cachedWindowTitles[cgWindow.windowID]
                                ),
                                ownerName: app.localizedName ?? "Unknown App",
                                frame: cgWindow.frame,
                                spaceLabels: cgWindow.spaceLabels,
                                rawSpaceIDs: cgWindow.rawSpaceIDs,
                                isOnScreen: cgWindow.isOnScreen,
                                isMinimized: !cgWindow.isOnScreen,
                                isVisibleOnCurrentDisplay: cgWindow.isVisibleOnCurrentDisplay
                            )
                        }

                    windows = filteredContainedAuxiliaryWindows(deduplicatedWindows(axDerivedWindows + unmatchedCGWindows))
                } else if !cgWindows.isEmpty {
                    let credibleCGWindows = cgWindows.filter { window in
                        isCredibleFallbackCGWindow(window)
                    }

                    guard !credibleCGWindows.isEmpty else {
                        return nil
                    }

                    windows = filteredContainedAuxiliaryWindows(credibleCGWindows.map { window in
                        SidebarWindow(
                            id: window.windowID,
                            title: resolvedWindowTitle(
                                processIdentifier: processID,
                                frame: window.frame,
                                cgTitle: window.title,
                                accessibilityTitle: nil,
                                cachedTitle: cachedWindowTitles[window.windowID]
                            ),
                            ownerName: app.localizedName ?? "Unknown App",
                            frame: window.frame,
                            spaceLabels: window.spaceLabels,
                            rawSpaceIDs: window.rawSpaceIDs,
                            isOnScreen: window.isOnScreen,
                            isMinimized: !window.isOnScreen,
                            isVisibleOnCurrentDisplay: window.isVisibleOnCurrentDisplay
                        )
                    })
                } else {
                    return nil
                }

                return GroupedAppWindows(
                    application: app,
                    order: appOrderByProcess[processID] ?? .max,
                    windows: windows
                )
            }
            .sorted { $0.order < $1.order }
            .map(sidebarApp(from:))

        return groupedApps
    }

    private func deduplicatedWindows(_ windows: [SidebarWindow]) -> [SidebarWindow] {
        var seenIDs = Set<CGWindowID>()
        var deduplicated: [SidebarWindow] = []

        for window in windows {
            if seenIDs.insert(window.id).inserted {
                deduplicated.append(window)
            }
        }

        return deduplicated
    }

    private func filteredContainedAuxiliaryWindows(_ windows: [SidebarWindow]) -> [SidebarWindow] {
        windows.filter { candidate in
            guard candidate.title == "Untitled Window", !candidate.frame.equalTo(.zero) else {
                return true
            }

            let candidateArea = candidate.frame.width * candidate.frame.height
            guard candidateArea > 0 else {
                return true
            }

            let isContainedAuxiliary = windows.contains { other in
                guard other.id != candidate.id else {
                    return false
                }

                guard other.title != "Untitled Window", !other.frame.equalTo(.zero) else {
                    return false
                }

                let sharesSpace =
                    (!candidate.rawSpaceIDs.isEmpty && !other.rawSpaceIDs.isEmpty && !Set(candidate.rawSpaceIDs).isDisjoint(with: other.rawSpaceIDs)) ||
                    (candidate.rawSpaceIDs.isEmpty && other.rawSpaceIDs.isEmpty)

                guard sharesSpace else {
                    return false
                }

                let insetFrame = other.frame.insetBy(dx: 1, dy: 1)
                guard insetFrame.contains(candidate.frame) else {
                    return false
                }

                let otherArea = other.frame.width * other.frame.height
                return otherArea >= candidateArea * 1.6
            }

            return !isContainedAuxiliary
        }
    }

    private func isLikelyStandaloneCGWindow(_ window: CGWindowMetadata) -> Bool {
        if isSyntheticDesktopSpan(window) {
            return false
        }

        if window.frame.width < 120 || window.frame.height < 80 {
            return false
        }

        if window.frame.height <= 40 {
            return false
        }

        if !window.spaceLabels.isEmpty {
            return true
        }

        return window.isOnScreen
    }

    private func isCredibleFallbackCGWindow(_ window: CGWindowMetadata) -> Bool {
        if isSyntheticDesktopSpan(window) {
            return false
        }

        if isLikelyOffSpaceApplicationWindow(window) {
            return true
        }

        if let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return true
        }

        if let cachedTitle = cachedWindowTitles[window.windowID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cachedTitle.isEmpty {
            return true
        }

        return window.isOnScreen
    }

    private func shouldIncludeUnmatchedCGWindow(_ window: CGWindowMetadata, alongside axWindows: [SidebarWindow]) -> Bool {
        let normalizedTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedTitle.isEmpty {
            return true
        }

        if isLikelyOffSpaceApplicationWindow(window) {
            return true
        }

        if axWindows.isEmpty {
            return true
        }

        let isContainedByAXWindow = axWindows.contains { axWindow in
            guard !axWindow.frame.equalTo(.zero), !window.frame.equalTo(.zero) else {
                return false
            }

            let insetFrame = axWindow.frame.insetBy(dx: 1, dy: 1)
            return insetFrame.contains(window.frame)
        }

        if isContainedByAXWindow {
            return false
        }

        let sharesSpaceWithAXWindow = axWindows.contains { axWindow in
            !Set(axWindow.rawSpaceIDs).isDisjoint(with: window.rawSpaceIDs)
        }

        if sharesSpaceWithAXWindow && !window.isOnScreen {
            return false
        }

        return true
    }

    private func isLikelyOffSpaceApplicationWindow(_ window: CGWindowMetadata) -> Bool {
        guard !window.isOnScreen else {
            return false
        }

        guard !window.rawSpaceIDs.isEmpty || !window.spaceLabels.isEmpty else {
            return false
        }

        guard window.frame.width >= 240, window.frame.height >= 120 else {
            return false
        }

        return true
    }

    private func isSyntheticDesktopSpan(_ window: CGWindowMetadata) -> Bool {
        guard !window.isOnScreen else {
            return false
        }

        let normalizedTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalizedTitle.isEmpty, window.rawSpaceIDs.isEmpty else {
            return false
        }

        let screenUnion = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard !screenUnion.isNull else {
            return false
        }

        return window.frame.width >= screenUnion.width * 0.9 &&
            window.frame.height >= screenUnion.height * 0.9
    }

    private func buildAppsFromCGWindows(
        runningApps: [pid_t: NSRunningApplication],
        appOrderByProcess: [pid_t: Int],
        cgWindowsByProcess: [pid_t: [CGWindowMetadata]]
    ) -> [SidebarApp] {
        cgWindowsByProcess.compactMap { (processID, windows) -> GroupedAppWindows? in
            guard let app = runningApps[processID] else {
                return nil
            }

            return GroupedAppWindows(
                application: app,
                order: appOrderByProcess[processID] ?? .max,
                windows: windows.map { window in
                    SidebarWindow(
                        id: window.windowID,
                        title: resolvedWindowTitle(
                            processIdentifier: processID,
                            frame: window.frame,
                            cgTitle: window.title,
                            accessibilityTitle: nil,
                            cachedTitle: cachedWindowTitles[window.windowID]
                        ),
                        ownerName: app.localizedName ?? "Unknown App",
                        frame: window.frame,
                        spaceLabels: window.spaceLabels,
                        rawSpaceIDs: window.rawSpaceIDs,
                        isOnScreen: window.isOnScreen,
                        isMinimized: !window.isOnScreen,
                        isVisibleOnCurrentDisplay: window.isVisibleOnCurrentDisplay
                    )
                }
            )
        }
        .sorted { $0.order < $1.order }
        .map(sidebarApp(from:))
    }

    private func sidebarApp(from grouped: GroupedAppWindows) -> SidebarApp {
        SidebarApp(
            processIdentifier: grouped.application.processIdentifier,
            name: grouped.application.localizedName ?? "Unknown App",
            bundleIdentifier: grouped.application.bundleIdentifier,
            applicationURL: grouped.application.bundleURL,
            icon: grouped.application.icon,
            windows: grouped.windows
        )
    }

    private func bestMatch(for axWindow: AccessibilityWindowMetadata, candidates: [CGWindowMetadata]) -> CGWindowMetadata? {
        let scoredCandidates = candidates
            .compactMap { candidate -> (CGWindowMetadata, Int)? in
                let score = matchScore(for: axWindow, candidate: candidate)
                guard score > 0 else {
                    return nil
                }
                return (candidate, score)
            }

        if let bestScoredCandidate = scoredCandidates.max(by: { lhs, rhs in lhs.1 < rhs.1 })?.0 {
            return bestScoredCandidate
        }

        return candidates.min(by: { lhs, rhs in
            frameDistance(axWindow.frame, lhs.frame) < frameDistance(axWindow.frame, rhs.frame)
        })
    }

    private func matchScore(for axWindow: AccessibilityWindowMetadata, candidate: CGWindowMetadata) -> Int {
        var score = 0

        if let axWindowID = axWindow.windowID, axWindowID == candidate.windowID {
            score += 10
        }

        if axWindow.matches(title: candidate.title, frame: candidate.frame) {
            score += 4
        }

        if axWindow.looselyMatches(frame: candidate.frame) {
            score += 2
        }

        if let axTitle = axWindow.title,
           let candidateTitle = candidate.title,
           axTitle.trimmingCharacters(in: .whitespacesAndNewlines) == candidateTitle.trimmingCharacters(in: .whitespacesAndNewlines) {
            score += 2
        }

        return score
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDistance = hypot(lhs.origin.x - rhs.origin.x, lhs.origin.y - rhs.origin.y)
        let sizeDistance = hypot(lhs.size.width - rhs.size.width, lhs.size.height - rhs.size.height)
        return originDistance + sizeDistance
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func resolvedWindowTitle(
        processIdentifier: pid_t,
        frame: CGRect,
        cgTitle: String?,
        accessibilityTitle: String?,
        cachedTitle: String? = nil
    ) -> String {
        if let accessibilityTitle, !accessibilityTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cacheWindowTitle(accessibilityTitle, processIdentifier: processIdentifier, frame: frame)
            return accessibilityTitle
        }

        if let cachedTitle, !cachedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cacheWindowTitle(cachedTitle, processIdentifier: processIdentifier, frame: frame)
            return cachedTitle
        }

        if let signatureTitle = cachedWindowTitlesBySignature[WindowTitleSignature(processIdentifier: processIdentifier, frame: frame)],
           !signatureTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return signatureTitle
        }

        guard let cgTitle, !cgTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Untitled Window"
        }

        cacheWindowTitle(cgTitle, processIdentifier: processIdentifier, frame: frame)
        return cgTitle
    }

    private func cacheWindowTitle(_ title: String, processIdentifier: pid_t, frame: CGRect) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !frame.equalTo(.zero) else {
            return
        }

        cachedWindowTitlesBySignature[WindowTitleSignature(processIdentifier: processIdentifier, frame: frame)] = normalizedTitle
    }

    private func activeScreenFrame() -> CGRect? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })?.frame
    }

    private func bestMatchingWindowElement(for window: SidebarWindow, in elements: [AXUIElement]) -> AXUIElement? {
        elements
            .compactMap { element -> (AXUIElement, Int)? in
                let score = focusMatchScore(for: window, element: element)
                guard score > 0 else {
                    return nil
                }

                return (element, score)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private func focusMatchScore(for window: SidebarWindow, element: AXUIElement) -> Int {
        var score = 0

        if let axWindowNumber = axWindowID(of: element) {
            // A known, different window number means a different window, however
            // similar its title or size (e.g. the same app's window on another display).
            guard axWindowNumber == window.id else {
                return 0
            }
            score += 10
        }

        let axTitle = bestAXTitle(for: element, bundleIdentifier: nil)
        let normalizedWindowTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAXTitle = axTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !normalizedWindowTitle.isEmpty,
           normalizedWindowTitle != "Untitled Window",
           normalizedWindowTitle == normalizedAXTitle {
            score += 4
        }

        let position = axPointValue(for: kAXPositionAttribute, on: element) ?? .zero
        let size = axSizeValue(for: kAXSizeAttribute, on: element) ?? .zero
        let elementFrame = CGRect(origin: position, size: size)

        if !window.frame.equalTo(.zero) && !elementFrame.equalTo(.zero) {
            if framesRoughlyMatch(elementFrame, window.frame) {
                score += 3
            } else if framesLooselyMatch(elementFrame, window.frame) {
                score += 1
            }
        }

        return score
    }

    private func framesRoughlyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 8 &&
        abs(lhs.origin.y - rhs.origin.y) < 8 &&
        abs(lhs.size.width - rhs.size.width) < 8 &&
        abs(lhs.size.height - rhs.size.height) < 8
    }

    private func framesLooselyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 40 &&
        abs(lhs.origin.y - rhs.origin.y) < 40 &&
        abs(lhs.size.width - rhs.size.width) < 80 &&
        abs(lhs.size.height - rhs.size.height) < 80
    }

    private func accessibilityMetadata(for runningApps: [pid_t: NSRunningApplication]) -> [pid_t: [AccessibilityWindowMetadata]] {
        guard accessibilityEnabled else {
            return [:]
        }

        var metadataByProcess: [pid_t: [AccessibilityWindowMetadata]] = [:]

        for (processID, app) in runningApps where app.activationPolicy == .regular && !app.isHidden {
            let applicationElement = AXUIElementCreateApplication(processID)
            let windowElements = accessibleWindowElements(for: applicationElement)
            guard !windowElements.isEmpty else { continue }

            let metadata = windowElements.compactMap { element -> AccessibilityWindowMetadata? in
                let title = bestAXTitle(for: element, bundleIdentifier: app.bundleIdentifier)
                let role = axStringValue(for: kAXRoleAttribute, on: element)
                let subrole = axStringValue(for: kAXSubroleAttribute, on: element)
                let documentValue = axStringValue(for: kAXDocumentAttribute, on: element)
                let filenameValue = axStringValue(for: "AXFilename", on: element)
                let urlValue = axStringValue(for: "AXURL", on: element)
                let position = axPointValue(for: kAXPositionAttribute, on: element) ?? .zero
                let size = axSizeValue(for: kAXSizeAttribute, on: element) ?? .zero
                let frame = CGRect(origin: position, size: size)
                let isMinimized = axBoolValue(for: kAXMinimizedAttribute, on: element) ?? false
                let windowID = axIntValue(for: "AXWindowNumber", on: element).flatMap(CGWindowID.init)

                guard isTopLevelAccessibilityWindow(role: role, subrole: subrole) else {
                    return nil
                }

                if isMinimized {
                    return nil
                }

                if frame.width <= 40 || frame.height <= 40 {
                    return nil
                }

                if isLikelyDesktopWindow(
                    bundleIdentifier: app.bundleIdentifier,
                    title: title,
                    role: role,
                    subrole: subrole,
                    documentValue: documentValue,
                    filenameValue: filenameValue,
                    urlValue: urlValue,
                    windowID: windowID,
                    frame: frame
                ) {
                    return nil
                }

                if title == nil && frame.equalTo(.zero) {
                    return nil
                }

                let isVisibleOnCurrentDisplay = activeScreenFrame()?.intersects(frame) == true
                return AccessibilityWindowMetadata(
                    windowID: windowID,
                    title: title,
                    frame: frame,
                    isVisibleOnCurrentDisplay: isVisibleOnCurrentDisplay
                )
            }

            if !metadata.isEmpty {
                metadataByProcess[processID] = metadata
                for window in metadata {
                    if let windowID = window.windowID,
                       let title = window.title,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cachedWindowTitles[windowID] = title
                    }

                    if let title = window.title {
                        cacheWindowTitle(title, processIdentifier: processID, frame: window.frame)
                    }
                }
            }
        }

        return metadataByProcess
    }

    private func isTopLevelAccessibilityWindow(role: String?, subrole: String?) -> Bool {
        guard let role else {
            return false
        }

        if role == kAXWindowRole as String {
            return true
        }

        if role == kAXSheetRole as String {
            return true
        }

        if role == "AXDialog" {
            return true
        }

        if role == kAXDrawerRole as String {
            return true
        }

        if subrole == kAXSystemDialogSubrole as String {
            return true
        }

        return false
    }

    private func isLikelyDesktopWindow(
        bundleIdentifier: String?,
        title: String?,
        role: String?,
        subrole: String?,
        documentValue: String?,
        filenameValue: String?,
        urlValue: String?,
        windowID: CGWindowID?,
        frame: CGRect
    ) -> Bool {
        guard bundleIdentifier == "com.apple.finder" else {
            return false
        }

        let hasMeaningfulTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasBackingMetadata =
            documentValue?.isEmpty == false ||
            filenameValue?.isEmpty == false ||
            urlValue?.isEmpty == false ||
            windowID != nil

        if hasMeaningfulTitle || hasBackingMetadata {
            return false
        }

        if role == kAXWindowRole as String, subrole == kAXStandardWindowSubrole as String {
            return false
        }

        let screenFrames = NSScreen.screens.map(\.frame)
        let matchesScreen = screenFrames.contains { screenFrame in
            abs(screenFrame.origin.x - frame.origin.x) < 4 &&
            abs(screenFrame.origin.y - frame.origin.y) < 4 &&
            abs(screenFrame.width - frame.width) < 4 &&
            abs(screenFrame.height - frame.height) < 4
        }

        return matchesScreen
    }

    private func bestAXTitle(for element: AXUIElement, bundleIdentifier: String?) -> String? {
        if let title = axStringValue(for: kAXTitleAttribute, on: element),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        if let titleElement = axElementValue(for: kAXTitleUIElementAttribute, on: element) {
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let title = axStringValue(for: attribute, on: titleElement),
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return title
                }
            }
        }

        if let documentValue = axStringValue(for: kAXDocumentAttribute, on: element),
           let documentTitle = titleFromDocumentValue(documentValue, bundleIdentifier: bundleIdentifier) {
            return documentTitle
        }

        for attribute in ["AXFilename", "AXURL"] {
            if let value = axStringValue(for: attribute, on: element),
               let title = titleFromDocumentValue(value, bundleIdentifier: bundleIdentifier) {
                return title
            }
        }

        return nil
    }

    private func titleFromDocumentValue(_ value: String, bundleIdentifier: String?) -> String? {
        guard let url = URL(string: value) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

        if bundleIdentifier == "com.apple.Safari" {
            if let host = url.host, !host.isEmpty {
                return host
            }
        }

        if !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }

        return url.host
    }

    private func axArrayValue(for attribute: String, on element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard
            error == .success,
            let array = value as? [AXUIElement]
        else {
            return nil
        }

        return array
    }

    private func axElementValue(for attribute: String, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard
            error == .success,
            let elementValue = value,
            CFGetTypeID(elementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(elementValue, to: AXUIElement.self)
    }

    private func axStringValue(for attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard
            error == .success,
            let string = value as? String
        else {
            return nil
        }

        return string
    }

    private func axBoolValue(for attribute: String, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard error == .success else {
            return nil
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return nil
    }

    private func axIntValue(for attribute: String, on element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard error == .success else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func axPointValue(for attribute: String, on element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard
            error == .success,
            let axValue = value,
            CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let unmanagedValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetType(unmanagedValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(unmanagedValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func axSizeValue(for attribute: String, on element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard
            error == .success,
            let axValue = value,
            CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let unmanagedValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetType(unmanagedValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(unmanagedValue, .cgSize, &size) else {
            return nil
        }

        return size
    }
}

struct SidebarApp: Identifiable {
    let processIdentifier: pid_t
    let name: String
    let bundleIdentifier: String?
    let applicationURL: URL?
    let icon: NSImage?
    let windows: [SidebarWindow]

    var id: pid_t { processIdentifier }
}

struct SidebarWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let ownerName: String
    let frame: CGRect
    let spaceLabels: [String]
    let rawSpaceIDs: [UInt64]
    let isOnScreen: Bool
    let isMinimized: Bool
    let isVisibleOnCurrentDisplay: Bool
}

private struct GroupedAppWindows {
    let application: NSRunningApplication
    let order: Int
    var windows: [SidebarWindow]
}

private struct CGWindowMetadata {
    let windowID: CGWindowID
    let title: String?
    let frame: CGRect
    let isOnScreen: Bool
    let fallbackWorkspaceID: Int?
    let spaceLabels: [String]
    let rawSpaceIDs: [UInt64]

    var isVisibleOnCurrentDisplay: Bool {
        guard let activeScreenFrame = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })?.frame else {
            return false
        }

        return isOnScreen && activeScreenFrame.intersects(frame)
    }
}

private struct AccessibilityWindowMetadata {
    let windowID: CGWindowID?
    let title: String?
    let frame: CGRect
    let isVisibleOnCurrentDisplay: Bool

    func matches(title candidateTitle: String?, frame candidateFrame: CGRect) -> Bool {
        let normalizedCandidateTitle = candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedCandidateTitle, !normalizedCandidateTitle.isEmpty,
           let normalizedTitle, !normalizedTitle.isEmpty,
           normalizedCandidateTitle == normalizedTitle {
            return roughlyMatches(candidateFrame)
        }

        return roughlyMatches(candidateFrame)
    }

    func looselyMatches(frame candidateFrame: CGRect) -> Bool {
        abs(frame.origin.x - candidateFrame.origin.x) < 40 &&
        abs(frame.origin.y - candidateFrame.origin.y) < 40 &&
        abs(frame.size.width - candidateFrame.size.width) < 80 &&
        abs(frame.size.height - candidateFrame.size.height) < 80
    }

    private func roughlyMatches(_ other: CGRect) -> Bool {
        abs(frame.origin.x - other.origin.x) < 12 &&
        abs(frame.origin.y - other.origin.y) < 12 &&
        abs(frame.size.width - other.size.width) < 24 &&
        abs(frame.size.height - other.size.height) < 24
    }
}

private struct WindowTitleSignature: Hashable {
    let processIdentifier: pid_t
    let minX: Int
    let minY: Int
    let width: Int
    let height: Int

    init(processIdentifier: pid_t, frame: CGRect) {
        self.processIdentifier = processIdentifier
        minX = Int((frame.origin.x / 16).rounded())
        minY = Int((frame.origin.y / 16).rounded())
        width = Int((frame.size.width / 16).rounded())
        height = Int((frame.size.height / 16).rounded())
    }
}

/// Logs window-focus and Space-switch decisions. View them with:
/// `log show --last 5m --info --predicate 'subsystem == "lapp.WindowBar"'`
private let focusLogger = Logger(subsystem: "lapp.WindowBar", category: "focus")
/// Logs windows left out of the inventory. Debug messages need `--debug` with `log show`.
private let inventoryLogger = Logger(subsystem: "lapp.WindowBar", category: "inventory")

/// A Mission Control keyboard shortcut as configured in System Settings > Keyboard >
/// Keyboard Shortcuts > Mission Control, read from the system's symbolic hot keys.
private struct MissionControlShortcut {
    private static let moveLeftHotKeyID = "79"
    private static let moveRightHotKeyID = "81"
    private static let leftArrowKeyCode: CGKeyCode = 123
    private static let rightArrowKeyCode: CGKeyCode = 124
    /// macOS's default modifiers for these shortcuts: Control plus Function (arrow keys).
    private static let defaultModifiers: CGEventFlags = [.maskControl, .maskSecondaryFn]

    let keyCode: CGKeyCode
    let modifiers: CGEventFlags

    /// The "Move left/right a space" shortcut, or nil if the user turned it off.
    static func moveOneSpace(right: Bool) -> MissionControlShortcut? {
        let hotKeyID = right ? moveRightHotKeyID : moveLeftHotKeyID
        let defaultShortcut = MissionControlShortcut(
            keyCode: right ? rightArrowKeyCode : leftArrowKeyCode,
            modifiers: defaultModifiers
        )

        guard
            let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
            let entry = hotKeys[hotKeyID] as? [String: Any]
        else {
            // Never customized: macOS uses its default, which is enabled.
            return defaultShortcut
        }

        if let enabled = entry["enabled"] as? Bool, !enabled {
            return nil
        }

        // Parameters are (character, key code, modifier flags); the flags use the
        // same bit values as CGEventFlags.
        guard
            let value = entry["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Int],
            parameters.count == 3
        else {
            return defaultShortcut
        }

        return MissionControlShortcut(
            keyCode: CGKeyCode(parameters[1]),
            modifiers: CGEventFlags(rawValue: UInt64(parameters[2]))
        )
    }

    func press() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

private typealias CGSConnectionID = Int32
private let cgsSpaceQuerySelector: Int32 = 0x7
private let cpsUserGenerated: UInt32 = 0x200
private let cgsEventTypeField = CGEventField(rawValue: 55)!
private let cgsGestureHIDTypeField = CGEventField(rawValue: 110)!
private let cgsGestureSwipeMotionField = CGEventField(rawValue: 123)!
private let cgsGestureSwipeProgressField = CGEventField(rawValue: 124)!
private let cgsGestureSwipeVelocityXField = CGEventField(rawValue: 129)!
private let cgsGesturePhaseField = CGEventField(rawValue: 132)!

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: CGSConnectionID, _ selector: Int32, _ windowIDs: CFArray) -> CFArray?

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowSPI(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
private func LegacyGetProcessForPID(_ processIdentifier: pid_t, _ processSerialNumber: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

private func makeKeyWindow(_ processSerialNumber: UnsafeMutablePointer<ProcessSerialNumber>, windowID: CGWindowID) {
    var eventBytes = [UInt8](repeating: 0, count: 0xF8)
    eventBytes[0x04] = 0xF8
    eventBytes[0x3A] = 0x10

    var mutableWindowID = UInt32(windowID)
    withUnsafeBytes(of: &mutableWindowID) { bytes in
        eventBytes.replaceSubrange(0x3C..<(0x3C + bytes.count), with: bytes)
    }

    for index in 0x20..<0x30 {
        eventBytes[index] = 0xFF
    }

    eventBytes.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }

        baseAddress[0x08] = 0x01
        _ = PrivateWindowFocusSPI.postEventRecordTo?(processSerialNumber, baseAddress)
        baseAddress[0x08] = 0x02
        _ = PrivateWindowFocusSPI.postEventRecordTo?(processSerialNumber, baseAddress)
    }
}

private enum PrivateWindowFocusSPI {
    typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    static let postEventRecordTo: PostEventRecordTo? = {
        guard let handle, let symbol = dlsym(handle, "SLPSPostEventRecordTo") else {
            return nil
        }

        return unsafeBitCast(symbol, to: PostEventRecordTo.self)
    }()

    static let setFrontProcessWithOptions: SetFrontProcessWithOptions? = {
        guard let handle, let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else {
            return nil
        }

        return unsafeBitCast(symbol, to: SetFrontProcessWithOptions.self)
    }()
}

private struct SpaceResolver {
    private let connectionID: CGSConnectionID = CGSMainConnectionID()
    private let labelsBySpaceID: [UInt64: String]
    private let displayBySpaceID: [UInt64: String]
    private let missionControlIndexBySpaceID: [UInt64: Int]

    init() {
        let mappings = Self.loadSpaceMappings(connectionID: connectionID)
        labelsBySpaceID = mappings.labelsBySpaceID
        displayBySpaceID = mappings.displayBySpaceID
        missionControlIndexBySpaceID = mappings.missionControlIndexBySpaceID
    }

    func spaceLabels(for windowID: CGWindowID, fallbackWorkspaceID: Int?) -> [String] {
        let windowIDs = [NSNumber(value: windowID)] as CFArray

        if let spaces = CGSCopySpacesForWindows(connectionID, cgsSpaceQuerySelector, windowIDs) as? [NSNumber] {
            let resolvedLabels = spaces.compactMap { labelsBySpaceID[$0.uint64Value] }
            if !resolvedLabels.isEmpty {
                return resolvedLabels
            }

            let rawLabels = spaces.map { "Space \($0.uint64Value)" }
            if !rawLabels.isEmpty {
                return rawLabels
            }
        }

        if let fallbackWorkspaceID {
            return ["Space \(fallbackWorkspaceID)"]
        }

        return []
    }

    /// Whether the Space is one of the Mission Control Spaces on a connected display.
    func isKnownSpace(_ spaceID: UInt64) -> Bool {
        labelsBySpaceID[spaceID] != nil
    }

    func rawSpaceIDs(for windowID: CGWindowID) -> [UInt64] {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(connectionID, cgsSpaceQuerySelector, windowIDs) as? [NSNumber] else {
            return []
        }

        return spaces.map(\.uint64Value)
    }

    func switchToSpace(_ spaceID: UInt64) -> Bool {
        guard let activeSpaceID = currentSpaceID(for: spaceID) else {
            return false
        }

        guard activeSpaceID != spaceID else {
            return true
        }

        guard
            let currentIndex = missionControlIndexBySpaceID[activeSpaceID],
            let targetIndex = missionControlIndexBySpaceID[spaceID]
        else {
            focusLogger.error("switchToSpace: no Mission Control index for active \(activeSpaceID) or target \(spaceID)")
            return false
        }

        let swipeCount = abs(targetIndex - currentIndex)
        guard swipeCount > 0 else {
            return true
        }

        let movesRight = targetIndex > currentIndex
        let swipeDirection = movesRight ? 1.0 : -1.0

        let originalCursorPosition = CGEvent(source: nil)?.location
        let targetFrame = targetDisplayFrame(for: spaceID)
        focusLogger.info("switchToSpace: active \(activeSpaceID) (index \(currentIndex)) -> target \(spaceID) (index \(targetIndex)), \(swipeCount) step(s), target display frame \(String(describing: targetFrame), privacy: .public)")

        // Space switching acts on the display under the pointer, so move it there first.
        // NSScreen frames use a bottom-left origin, but warping uses Core Graphics
        // coordinates with a top-left origin on the primary display, so flip y.
        if let targetFrame, let primaryHeight = NSScreen.screens.first?.frame.height {
            CGWarpMouseCursorPosition(CGPoint(x: targetFrame.midX, y: primaryHeight - targetFrame.midY))
        }

        defer {
            if let originalCursorPosition {
                CGWarpMouseCursorPosition(originalCursorPosition)
            }
        }

        // Preferred: press the "Move left/right a space" shortcut from Mission Control
        // settings. Synthetic trackpad swipes are ignored on some systems.
        if let shortcut = MissionControlShortcut.moveOneSpace(right: movesRight) {
            focusLogger.info("switchToSpace: pressing Move \(movesRight ? "right" : "left", privacy: .public) a space shortcut \(swipeCount) time(s)")
            for _ in 0..<swipeCount {
                shortcut.press()
            }
            return true
        }

        focusLogger.info("switchToSpace: Move a space shortcut is disabled, falling back to a Dock swipe")
        guard let dockSwipeEvent = CGEvent(source: nil) else {
            return false
        }

        dockSwipeEvent.setIntegerValueField(cgsEventTypeField, value: 30)
        dockSwipeEvent.setIntegerValueField(cgsGestureHIDTypeField, value: 23)
        dockSwipeEvent.setIntegerValueField(cgsGestureSwipeMotionField, value: 1)
        dockSwipeEvent.setDoubleValueField(cgsGestureSwipeProgressField, value: swipeDirection)
        dockSwipeEvent.setDoubleValueField(cgsGestureSwipeVelocityXField, value: swipeDirection * 9999.0)

        for _ in 0..<swipeCount {
            dockSwipeEvent.setIntegerValueField(cgsGesturePhaseField, value: 1)
            dockSwipeEvent.post(tap: .cgSessionEventTap)
            dockSwipeEvent.setIntegerValueField(cgsGesturePhaseField, value: 4)
            dockSwipeEvent.post(tap: .cgSessionEventTap)
        }

        // No synthetic click here: the swipe animates asynchronously, so the Space
        // hasn't changed yet at this point, and a click would land on whatever window
        // is under the display's center and could interrupt the switch. The caller
        // waits for the switch and retries the swipe if it didn't happen.

        return true
    }

    func currentSpaceIDs() -> [UInt64] {
        guard let managedDisplaySpaces = CGSCopyManagedDisplaySpaces(connectionID) as? [[String: Any]] else {
            return []
        }

        return managedDisplaySpaces.compactMap { display in
            Self.spaceID(from: display["Current Space"])
        }
    }

    private func currentSpaceID(for targetSpaceID: UInt64) -> UInt64? {
        guard let targetDisplayIdentifier = displayBySpaceID[targetSpaceID] else {
            return currentSpaceIDs().first
        }

        guard let managedDisplaySpaces = CGSCopyManagedDisplaySpaces(connectionID) as? [[String: Any]] else {
            return nil
        }

        return managedDisplaySpaces
            .first(where: { Self.displayIdentifier(from: $0["Display Identifier"]) == targetDisplayIdentifier })
            .flatMap { Self.spaceID(from: $0["Current Space"]) }
    }

    private func targetDisplayFrame(for targetSpaceID: UInt64) -> CGRect? {
        guard let targetDisplayIdentifier = displayBySpaceID[targetSpaceID] else {
            return nil
        }

        return NSScreen.screens.first { screen in
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(screenNumber.uint32Value))
            else {
                return false
            }

            return (CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?) == targetDisplayIdentifier
        }?.frame
    }

    private static func loadSpaceMappings(connectionID: CGSConnectionID) -> (
        labelsBySpaceID: [UInt64: String],
        displayBySpaceID: [UInt64: String],
        missionControlIndexBySpaceID: [UInt64: Int]
    ) {
        guard let managedDisplaySpaces = CGSCopyManagedDisplaySpaces(connectionID) as? [[String: Any]] else {
            return ([:], [:], [:])
        }

        var labelsBySpaceID: [UInt64: String] = [:]
        var displayBySpaceID: [UInt64: String] = [:]
        var missionControlIndexBySpaceID: [UInt64: Int] = [:]
        var globalIndex = 1

        for display in managedDisplaySpaces {
            guard let spaces = display["Spaces"] as? [[String: Any]] else {
                continue
            }

            let displayIdentifier = displayIdentifier(from: display["Display Identifier"])

            for space in spaces {
                let candidateID =
                    (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ??
                    (space["id64"] as? NSNumber)?.uint64Value

                guard let candidateID else {
                    continue
                }

                labelsBySpaceID[candidateID] = "Space \(globalIndex)"
                missionControlIndexBySpaceID[candidateID] = globalIndex
                if let displayIdentifier {
                    displayBySpaceID[candidateID] = displayIdentifier
                }
                globalIndex += 1
            }
        }

        return (labelsBySpaceID, displayBySpaceID, missionControlIndexBySpaceID)
    }

    private static func spaceID(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }

        if let dictionary = value as? [String: Any] {
            return (dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value ??
                (dictionary["id64"] as? NSNumber)?.uint64Value
        }

        return nil
    }

    private static func displayIdentifier(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }

        if let uuid = value as? UUID {
            return uuid.uuidString
        }

        if let cfUuid = value {
            return String(describing: cfUuid)
        }

        return nil
    }
}

