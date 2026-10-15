import Foundation
import Observation
import SwiftUI

/// The settings and the check that the update window and the settings drive.
/// Sparkle implements it in the app; the tests leave it out.
@MainActor
protocol UpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// The state of the update window: one window whose content follows the
/// update, from the check to the relaunch. The updater calls the `show…`
/// methods; the window calls the user's choices back.
@MainActor @Observable
final class UpdateModel {
    struct Release: Equatable {
        let version: String
        /// Markdown, written by hand for each version.
        let notes: String
    }

    enum Choice: Equatable {
        case install
        case later
        case skip
    }

    enum Phase: Equatable {
        case checking
        case found(Release)
        case downloading(received: UInt64, expected: UInt64?)
        /// Extracting, then installing: no progress worth showing.
        case preparing
        case ready
        case upToDate
        case failed(message: String)
    }

    static let shared = UpdateModel(
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")

    let currentVersion: String

    /// What the window shows, or nil when it is closed.
    private(set) var phase: Phase?

    /// A version found and put off with « Plus tard »: the menu item points it out.
    private(set) var deferredVersion: String?

    /// Where the releases can be downloaded by hand, for a failed update.
    var releasesURL: URL?

    weak var backend: UpdateBackend? {
        didSet { refreshSettings() }
    }

    private(set) var automaticallyChecks = false
    private(set) var automaticallyDownloads = false
    private(set) var lastCheckDate: Date?
    private(set) var canCheck = false

    @ObservationIgnored private var reply: ((Choice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    /// The user already chose to install: the update goes on without asking again.
    @ObservationIgnored private var installRequested = false
    @ObservationIgnored private var pendingVersion: String?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    // MARK: Settings

    func refreshSettings() {
        automaticallyChecks = backend?.automaticallyChecksForUpdates ?? false
        automaticallyDownloads = backend?.automaticallyDownloadsUpdates ?? false
        lastCheckDate = backend?.lastUpdateCheckDate
        canCheck = backend?.canCheckForUpdates ?? false
    }

    func setAutomaticallyChecks(_ value: Bool) {
        backend?.automaticallyChecksForUpdates = value
        refreshSettings()
    }

    func setAutomaticallyDownloads(_ value: Bool) {
        backend?.automaticallyDownloadsUpdates = value
        refreshSettings()
    }

    func checkForUpdates() {
        backend?.checkForUpdates()
        refreshSettings()
    }

    // MARK: Updater → window

    func showChecking(cancellation: @escaping () -> Void) {
        clearCallbacks()
        self.cancellation = cancellation
        phase = .checking
    }

    func showFound(_ release: Release, reply: @escaping (Choice) -> Void) {
        clearCallbacks()
        installRequested = false
        pendingVersion = release.version
        self.reply = reply
        phase = .found(release)
    }

    func showDownloadStarted(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .downloading(received: 0, expected: nil)
    }

    func setExpectedLength(_ length: UInt64) {
        guard case .downloading(let received, _) = phase else { return }
        phase = .downloading(received: received, expected: length > 0 ? length : nil)
    }

    func addReceivedLength(_ length: UInt64) {
        guard case .downloading(let received, let expected) = phase else { return }
        phase = .downloading(received: received + length, expected: expected)
    }

    func showPreparing() {
        cancellation = nil
        phase = .preparing
    }

    /// Ready to install and relaunch. When the user already asked for the
    /// install, it goes on at once; otherwise the window asks.
    func showReady(reply: @escaping (Choice) -> Void) {
        if installRequested {
            phase = .preparing
            reply(.install)
            return
        }
        clearCallbacks()
        self.reply = reply
        phase = .ready
    }

    func showUpToDate(acknowledgement: @escaping () -> Void) {
        clearCallbacks()
        self.acknowledgement = acknowledgement
        phase = .upToDate
    }

    func showFailed(_ message: String, acknowledgement: @escaping () -> Void) {
        clearCallbacks()
        self.acknowledgement = acknowledgement
        phase = .failed(message: message)
    }

    /// The updater is done or gave up: the window closes.
    func dismiss() {
        clearCallbacks()
        phase = nil
        refreshSettings()
    }

    // MARK: Window → updater

    func choose(_ choice: Choice) {
        guard let reply else { return }
        self.reply = nil
        switch choice {
        case .install:
            installRequested = true
            deferredVersion = nil
            phase = .preparing
        case .later:
            deferredVersion = pendingVersion
            phase = nil
        case .skip:
            deferredVersion = nil
            phase = nil
        }
        reply(choice)
    }

    func cancel() {
        let cancellation = cancellation
        clearCallbacks()
        phase = nil
        cancellation?()
    }

    func acknowledge() {
        let acknowledgement = acknowledgement
        clearCallbacks()
        phase = nil
        acknowledgement?()
    }

    /// A failed update, tried again from the start.
    func retry() {
        acknowledge()
        checkForUpdates()
    }

    /// The window's close button: the gentlest answer for each state.
    func windowClosed() {
        switch phase {
        case .found, .ready: choose(.later)
        case .checking, .downloading: cancel()
        case .upToDate, .failed: acknowledge()
        case .preparing, nil: break
        }
    }

    private func clearCallbacks() {
        reply = nil
        cancellation = nil
        acknowledgement = nil
    }
}
