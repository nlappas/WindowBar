//
//  AppDelegate.swift
//  WindowBar
//
//  Created by Nikolaos Lappas on 4/19/26.
//

import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var sidebarWindowController: SidebarWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the app with TCC as soon as the real app process finishes launching.
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)

        NSApp.setActivationPolicy(.accessory)
        let controller = SidebarWindowController()
        controller.showWindow(self)
        sidebarWindowController = controller
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sidebarWindowController?.repositionWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-check once the app is foregrounded after the user visits System Settings.
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
    }

    @objc private func handleScreenParametersChange() {
        sidebarWindowController?.repositionWindow()
    }

    func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(self)
        settingsWindowController?.window?.makeKeyAndOrderFront(self)
    }
}

private final class SidebarWindowController: NSWindowController {
    // Wide enough for the rail plus the configured number of window list columns.
    // The empty part of the panel is transparent, so clicks there pass through.
    private func sidebarWidth(for screen: NSScreen) -> CGFloat {
        let width = WindowGridSettings.baseSidebarWidth
            + CGFloat(WindowGridSettings.storedMaxColumns - 1) * WindowGridSettings.columnStride
        return min(width, screen.frame.width)
    }
    private var sidebarOnRight: Bool {
        UserDefaults.standard.bool(forKey: "sidebarOnRight")
    }

    convenience init() {
        let panel = SidebarPanel()
        self.init(window: panel)

        let containerView = NSView(frame: .zero)
        let hostingView = NSHostingView(rootView: ContentView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        panel.contentView = containerView
        repositionWindow()
    }

    func repositionWindow() {
        guard let window, let screen = NSScreen.screens.first else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let sidebarWidth = sidebarWidth(for: screen)
        let frame = CGRect(
            x: sidebarOnRight ? (screen.frame.maxX - sidebarWidth) : screen.frame.minX,
            y: visibleFrame.minY,
            width: sidebarWidth,
            height: visibleFrame.height
        )

        window.setFrame(frame, display: true)
    }
}

private final class SidebarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }
}

private final class SettingsWindowController: NSWindowController {
    convenience init() {
        let preferredSize = SettingsLayout.preferredWindowSize(for: NSScreen.main ?? NSScreen.screens.first)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WindowBar Settings"
        window.titleVisibility = .visible
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: SettingsLayout.windowWidth, height: SettingsLayout.minimumHeight)
        window.contentView = NSHostingView(rootView: SettingsView())
        self.init(window: window)
    }
}
