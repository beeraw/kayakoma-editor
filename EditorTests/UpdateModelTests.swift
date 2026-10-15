import XCTest

@MainActor
final class UpdateModelTests: XCTestCase {
    private let release = UpdateModel.Release(version: "1.2.0", notes: "- Find in the document.")

    func testInstallGoesOnWithoutAskingAgain() {
        let model = UpdateModel(currentVersion: "1.1.0")
        var choices: [UpdateModel.Choice] = []
        model.showFound(release) { choices.append($0) }
        XCTAssertEqual(model.phase, .found(release))

        model.choose(.install)
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(model.phase, .preparing)

        model.showDownloadStarted {}
        model.setExpectedLength(1000)
        model.addReceivedLength(400)
        XCTAssertEqual(model.phase, .downloading(received: 400, expected: 1000))

        model.showPreparing()
        var readyChoices: [UpdateModel.Choice] = []
        model.showReady { readyChoices.append($0) }
        XCTAssertEqual(readyChoices, [.install], "the user already chose to install")
        XCTAssertEqual(model.phase, .preparing)
    }

    func testReadyAsksWhenDownloadedInTheBackground() {
        let model = UpdateModel(currentVersion: "1.1.0")
        var choices: [UpdateModel.Choice] = []
        model.showReady { choices.append($0) }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(choices.isEmpty)

        model.choose(.later)
        XCTAssertEqual(choices, [.later])
        XCTAssertNil(model.phase)
    }

    func testLaterMarksTheVersionUntilInstalledOrSkipped() {
        let model = UpdateModel(currentVersion: "1.1.0")
        model.showFound(release) { _ in }
        model.choose(.later)
        XCTAssertEqual(model.deferredVersion, "1.2.0")
        XCTAssertNil(model.phase)

        model.showFound(release) { _ in }
        model.choose(.skip)
        XCTAssertNil(model.deferredVersion)
    }

    func testClosingTheWindowAnswersGently() {
        let model = UpdateModel(currentVersion: "1.1.0")
        var choices: [UpdateModel.Choice] = []
        model.showFound(release) { choices.append($0) }
        model.windowClosed()
        XCTAssertEqual(choices, [.later])

        var cancelled = false
        model.showDownloadStarted { cancelled = true }
        model.windowClosed()
        XCTAssertTrue(cancelled)

        var acknowledged = false
        model.showFailed("Offline.") { acknowledged = true }
        model.windowClosed()
        XCTAssertTrue(acknowledged)
        XCTAssertNil(model.phase)
    }

    func testEachReplyIsSentOnce() {
        let model = UpdateModel(currentVersion: "1.1.0")
        var count = 0
        model.showFound(release) { _ in count += 1 }
        model.choose(.install)
        model.choose(.install)
        model.windowClosed()
        XCTAssertEqual(count, 1)
    }

    func testSettingsFollowTheBackend() {
        let backend = FakeBackend()
        let model = UpdateModel(currentVersion: "1.1.0")
        model.backend = backend
        XCTAssertTrue(model.automaticallyChecks)
        XCTAssertFalse(model.automaticallyDownloads)

        model.setAutomaticallyDownloads(true)
        XCTAssertTrue(backend.automaticallyDownloadsUpdates)
        XCTAssertTrue(model.automaticallyDownloads)

        model.checkForUpdates()
        XCTAssertEqual(backend.checks, 1)

        model.showFailed("Offline.") {}
        model.retry()
        XCTAssertEqual(backend.checks, 2)
        XCTAssertNil(model.phase)
    }
}

@MainActor
private final class FakeBackend: UpdateBackend {
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var lastUpdateCheckDate: Date?
    var canCheckForUpdates = true
    var checks = 0

    func checkForUpdates() {
        checks += 1
    }
}
