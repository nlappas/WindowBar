//
//  WindowBar.swift
//  WindowBar
//
//  Created by Nikolaos Lappas on 4/19/26.
//

import AppKit
import ApplicationServices
import SwiftUI

@main
struct WindowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

enum SettingsOption: CaseIterable, Identifiable {
    case rememberRailScrollPosition
    case showCurrentSpaceOnly
    case sidebarOnRight
    case showWindowPreviews

    var id: Self { self }

    var title: String {
        switch self {
        case .rememberRailScrollPosition:
            return "Remember rail scroll position"
        case .showCurrentSpaceOnly:
            return "Show only current Space"
        case .sidebarOnRight:
            return "Show sidebar on right edge"
        case .showWindowPreviews:
            return "Show window previews (needs Screen Recording access)"
        }
    }
}

/// Checks and requests the two privacy permissions WindowBar uses.
enum SystemPermissions {
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    private static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt, which also adds WindowBar to the Accessibility list,
    /// then opens the list so the user can turn it on.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return
        }

        if let accessibilitySettingsURL {
            NSWorkspace.shared.open(accessibilitySettingsURL)
        }
    }

    /// macOS only shows its Screen Recording prompt the first time, so afterwards
    /// open the Screen Recording list in System Settings instead.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGRequestScreenCaptureAccess() {
            return true
        }

        if let screenRecordingSettingsURL {
            NSWorkspace.shared.open(screenRecordingSettingsURL)
        }
        return false
    }
}

/// Limits for how many windows the window list shows before it scrolls.
enum WindowGridSettings {
    static let maxColumnsKey = "maxPreviewColumns"
    static let maxRowsKey = "maxPreviewRows"
    static let defaultMaxColumns = 3
    static let defaultMaxRows = 2
    static let columnRange = 1...4
    static let rowRange = 1...4

    /// Rail plus a single-column window list; each extra column adds `columnStride`.
    static let baseSidebarWidth: CGFloat = 508
    static let columnStride: CGFloat = 308 + 10

    /// The saved column limit, clamped to the allowed range.
    static var storedMaxColumns: Int {
        let stored = UserDefaults.standard.object(forKey: maxColumnsKey) as? Int ?? defaultMaxColumns
        return min(max(stored, columnRange.lowerBound), columnRange.upperBound)
    }

    /// The most columns that fit on a screen of the given width.
    static func columnsThatFit(screenWidth: CGFloat) -> Int {
        let extraColumns = Int(((screenWidth - baseSidebarWidth) / columnStride).rounded(.down))
        return max(1, extraColumns + 1)
    }
}

enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    private static let topSectionHeight: CGFloat = 126
    private static let settingRowHeight: CGFloat = 30
    private static let settingSpacing: CGFloat = 18
    /// The two permission rows above the toggles and the two window-grid steppers below.
    private static let stepperRowCount = 2
    private static let permissionRowCount = 2
    private static let permissionRowHeight: CGFloat = 38
    private static let verticalPadding: CGFloat = 48
    static let minimumHeight: CGFloat = 220
    private static let maximumScreenCoverage: CGFloat = 0.8

    static func preferredWindowSize(for screen: NSScreen?) -> CGSize {
        let rowCount = SettingsOption.allCases.count + stepperRowCount + permissionRowCount
        let settingsHeight = CGFloat(SettingsOption.allCases.count + stepperRowCount) * settingRowHeight
            + CGFloat(permissionRowCount) * permissionRowHeight
        let settingsSpacing = CGFloat(max(rowCount - 1, 0)) * settingSpacing
        let idealHeight = topSectionHeight + settingsHeight + settingsSpacing + verticalPadding
        let screenHeight = screen?.visibleFrame.height ?? 900
        let cappedHeight = min(idealHeight, floor(screenHeight * maximumScreenCoverage))

        return CGSize(width: windowWidth, height: max(minimumHeight, cappedHeight))
    }

    static func maxScrollableContentHeight(for screen: NSScreen?) -> CGFloat {
        preferredWindowSize(for: screen).height - verticalPadding
    }
}

struct SettingsView: View {
    @AppStorage("rememberRailScrollPosition") private var rememberRailScrollPosition = false
    @AppStorage("showCurrentSpaceOnly") private var showCurrentSpaceOnly = false
    @AppStorage("sidebarOnRight") private var sidebarOnRight = false
    @AppStorage("showWindowPreviews") private var showWindowPreviews = true
    @AppStorage(WindowGridSettings.maxColumnsKey) private var maxPreviewColumns = WindowGridSettings.defaultMaxColumns
    @AppStorage(WindowGridSettings.maxRowsKey) private var maxPreviewRows = WindowGridSettings.defaultMaxRows
    @State private var accessibilityGranted = SystemPermissions.isAccessibilityGranted
    @State private var screenRecordingGranted = SystemPermissions.isScreenRecordingGranted

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("WindowBar Settings")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("Sidebar behavior, exclusions, and multi-display options will live here.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Window inventory and focusing are active from the sidebar panel.", systemImage: "sidebar.leading")
                    Label("Accessibility and Space-switch controls are configured from the main app process.", systemImage: "hand.raised.fill")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

                permissionRow(
                    title: "Accessibility",
                    detail: "Needed to list, focus, and switch between windows.",
                    isGranted: accessibilityGranted,
                    action: { SystemPermissions.requestAccessibility() }
                )

                permissionRow(
                    title: "Screen Recording",
                    detail: "Needed for window previews. macOS may ask you to relaunch WindowBar.",
                    isGranted: screenRecordingGranted,
                    action: { SystemPermissions.requestScreenRecording() }
                )

                ForEach(SettingsOption.allCases) { option in
                    Toggle(option.title, isOn: binding(for: option))
                        .toggleStyle(.switch)
                        .font(.system(size: 14, weight: .semibold))
                }

                Stepper(value: $maxPreviewColumns, in: WindowGridSettings.columnRange) {
                    Text("Windows shown across: \(maxPreviewColumns)")
                }
                .font(.system(size: 14, weight: .semibold))
                .help("The window list grows sideways up to this many columns")

                Stepper(value: $maxPreviewRows, in: WindowGridSettings.rowRange) {
                    Text("Windows shown down before scrolling: \(maxPreviewRows)")
                }
                .font(.system(size: 14, weight: .semibold))
                .help("The window list grows downward up to this many rows, then scrolls")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsLayout.windowWidth, alignment: .topLeading)
        .task {
            // Permissions change in System Settings, outside the app, so poll while
            // this view is on screen to keep the status current.
            while !Task.isCancelled {
                accessibilityGranted = SystemPermissions.isAccessibilityGranted
                screenRecordingGranted = SystemPermissions.isScreenRecordingGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isGranted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant Access…", action: action)
            }
        }
    }

    private func binding(for option: SettingsOption) -> Binding<Bool> {
        switch option {
        case .rememberRailScrollPosition:
            return $rememberRailScrollPosition
        case .showCurrentSpaceOnly:
            return $showCurrentSpaceOnly
        case .sidebarOnRight:
            return $sidebarOnRight
        case .showWindowPreviews:
            return $showWindowPreviews
        }
    }
}
