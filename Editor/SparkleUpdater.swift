import AppKit
import KayakomaKit
import os
import Sparkle

/// Sparkle behind the update window: it checks, downloads, verifies the
/// signature, installs outside the sandbox and relaunches; this user driver
/// hands each step to the model, which the window shows.
@MainActor
final class SparkleUpdater: NSObject, SPUUserDriver, UpdateBackend {
    private let model: UpdateModel
    private let windowController: UpdateWindowController
    private var updater: SPUUpdater?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.kayakoma", category: "updates")

    init(model: UpdateModel, accent: SoftAccent, notesTheme: Theme) {
        self.model = model
        windowController = UpdateWindowController(model: model, accent: accent, notesTheme: notesTheme)
        super.init()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            // A build without a signing key, for instance: no updates, no window.
            log.error("Updates disabled: \(error.localizedDescription, privacy: .public)")
        }
        // The feed is …/releases/latest/download/appcast.xml; the page is …/releases/latest.
        model.releasesURL = updater.feedURL?.deletingLastPathComponent().deletingLastPathComponent()
        model.backend = self
    }

    // MARK: UpdateBackend

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Not asked: SUEnableAutomaticChecks turns the checks on from the start.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.showChecking(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let release = UpdateModel.Release(version: appcastItem.displayVersionString,
                                          notes: appcastItem.itemDescription ?? "")
        let informationOnly = appcastItem.isInformationOnlyUpdate
        let infoURL = appcastItem.infoURL
        model.showFound(release) { choice in
            switch choice {
            case .install where informationOnly:
                // Nothing to download: the release page tells the rest.
                if let infoURL { NSWorkspace.shared.open(infoURL) }
                reply(.dismiss)
            case .install: reply(.install)
            case .later: reply(.dismiss)
            case .skip: reply(.skip)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The notes are part of the feed, never a separate download.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        if reason == .systemIsTooOld || reason == .systemIsTooNew {
            model.showFailed(error.localizedDescription, acknowledgement: acknowledgement)
        } else {
            model.showUpToDate(acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log.error("Update failed: \(error.localizedDescription, privacy: .public)")
        model.showFailed(error.localizedDescription, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        model.showDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.setExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        model.addReceivedLength(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        model.showPreparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.showReady { choice in
            switch choice {
            case .install: reply(.install)
            case .later: reply(.dismiss)
            case .skip: reply(.skip)
            }
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        model.showPreparing()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        model.dismiss()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        model.dismiss()
    }

    func showUpdateInFocus() {
        windowController.showInFocus()
    }
}
