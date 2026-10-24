//
//  WindowPreviewStore.swift
//  WindowBar
//

import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit

/// Captures and caches thumbnail previews of windows using ScreenCaptureKit.
///
/// Previews need Screen Recording permission. Captures happen on demand (when the
/// sidebar shows an app's windows) and are cached briefly, so hovering doesn't
/// re-capture every window on every frame.
@MainActor
@Observable
final class WindowPreviewStore {
    /// Previews keyed by Core Graphics window ID.
    private(set) var previews: [CGWindowID: NSImage] = [:]
    private(set) var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()

    /// How long a capture stays fresh before hovering the app again re-captures it.
    private let freshnessInterval: TimeInterval = 3
    /// Longest edge of a preview, in pixels. Large enough for a sharp thumbnail
    /// on Retina displays, small enough to capture quickly.
    private let maxPreviewPixelSize: CGFloat = 640
    private var captureDates: [CGWindowID: Date] = [:]

    func refreshAccessStatus() {
        hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording access, or opens System Settings if macOS won't prompt again.
    func requestAccess() {
        if SystemPermissions.requestScreenRecording() {
            hasScreenRecordingAccess = true
        }
    }

    /// Captures previews for the given windows unless a fresh capture is cached.
    func loadPreviews(for windowIDs: [CGWindowID]) async {
        refreshAccessStatus()
        guard hasScreenRecordingAccess else {
            return
        }

        let now = Date()
        let staleIDs = windowIDs.filter { windowID in
            guard let capturedAt = captureDates[windowID] else {
                return true
            }
            return now.timeIntervalSince(capturedAt) > freshnessInterval
        }

        guard !staleIDs.isEmpty else {
            return
        }

        // Include off-screen windows so windows on other Spaces can be attempted too.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return
        }

        let shareableWindows = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for windowID in staleIDs {
            guard !Task.isCancelled else {
                return
            }

            guard let shareableWindow = shareableWindows[windowID] else {
                continue
            }

            // Record the attempt even if it fails, so a window that can't be captured
            // isn't retried on every hover.
            captureDates[windowID] = Date()

            if let image = await capturePreview(of: shareableWindow) {
                previews[windowID] = image
            }
        }
    }

    /// Drops cached previews for windows that no longer exist.
    func prune(keeping windowIDs: Set<CGWindowID>) {
        previews = previews.filter { windowIDs.contains($0.key) }
        captureDates = captureDates.filter { windowIDs.contains($0.key) }
    }

    private func capturePreview(of window: SCWindow) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }

        // Scale the window down so its longest edge fits the preview size.
        let scale = min(1, maxPreviewPixelSize / max(frame.width, frame.height))
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)

        guard
            let output = try? await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration),
            let cgImage = output.sdrImage
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
