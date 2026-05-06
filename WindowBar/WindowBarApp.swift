//
//  WindowBar.swift
//  WindowBar
//
//  Created by Nikolaos Lappas on 4/19/26.
//

import AppKit
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

    var id: Self { self }

    var title: String {
        switch self {
        case .rememberRailScrollPosition:
            return "Remember rail scroll position"
        case .showCurrentSpaceOnly:
            return "Show only current Space"
        case .sidebarOnRight:
            return "Show sidebar on right edge"
        }
    }
}

enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    private static let topSectionHeight: CGFloat = 126
    private static let settingRowHeight: CGFloat = 30
    private static let settingSpacing: CGFloat = 18
    private static let verticalPadding: CGFloat = 48
    static let minimumHeight: CGFloat = 220
    private static let maximumScreenCoverage: CGFloat = 0.8

    static func preferredWindowSize(for screen: NSScreen?) -> CGSize {
        let settingsHeight = CGFloat(SettingsOption.allCases.count) * settingRowHeight
        let settingsSpacing = CGFloat(max(SettingsOption.allCases.count - 1, 0)) * settingSpacing
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

                ForEach(SettingsOption.allCases) { option in
                    Toggle(option.title, isOn: binding(for: option))
                        .toggleStyle(.switch)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsLayout.windowWidth, alignment: .topLeading)
    }

    private func binding(for option: SettingsOption) -> Binding<Bool> {
        switch option {
        case .rememberRailScrollPosition:
            return $rememberRailScrollPosition
        case .showCurrentSpaceOnly:
            return $showCurrentSpaceOnly
        case .sidebarOnRight:
            return $sidebarOnRight
        }
    }
}
