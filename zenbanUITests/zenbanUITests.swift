//
//  zenbanUITests.swift
//  zenbanUITests
//
//  Created by Berkay Çit on 25.12.2025.
//

import AppKit
import XCTest
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers

final class zenbanUITests: XCTestCase {
    private enum TerminalRuntimeMode {
        case inheritDefault
        case forceEnabled
        case forceDisabled
    }

    private let testedAppBundleIdentifier = "com.berkaycit.zenban"
    private var temporaryDirectoryURL: URL!
    private var boardStorageDirectoryURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zuit-\(UUID().uuidString)", isDirectory: true)
        boardStorageDirectoryURL = temporaryDirectoryURL.appendingPathComponent("boards", isDirectory: true)

        try FileManager.default.createDirectory(
            at: boardStorageDirectoryURL,
            withIntermediateDirectories: true
        )
        try writeSeedBoard()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    @MainActor
    func testClaudeCardNotificationShowsOrangeOutlineInReview() throws {
        let app = launchApp()
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        let firstCard = cardElement(named: "cc-1", in: app)
        let firstCardLabel = app.staticTexts["cc-1"].firstMatch
        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }
        performStep("03-send-naber", in: app) {
            sendPrompt("naber", in: app)
        }

        let secondCard = cardElement(named: "cc-2", in: app)
        let secondCardLabel = app.staticTexts["cc-2"].firstMatch
        performStep("04-create-cc-2", in: app) {
            createCard(named: "cc-2", in: app)
        }

        performStep("05-cc-1-moved-to-in-review", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    let firstFrame = cardFrame(for: firstCard, fallback: firstCardLabel)
                    let secondFrame = cardFrame(for: secondCard, fallback: secondCardLabel)
                    return firstFrame != nil
                        && secondFrame != nil
                        && firstFrame!.minX > secondFrame!.minX + 40
                },
                "Expected cc-1 to move into the In Review column after notification"
            )
        }

        let cardHasOutline = performStep("06-orange-outline-visible", in: app) {
            screenshotHasOrangeOutline(for: firstCard, fallback: firstCardLabel, in: app)
        }

        XCTAssertTrue(
            cardHasOutline,
            "Expected cc-1 to show an orange unread outline after the notification"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testResidentMemoryAfterOpeningFiveCards() throws {
        let app = launchApp()
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        var snapshots: [MemorySnapshot] = []
        let launchSnapshot = performStep("02-memory-after-launch", in: app) {
            recordResidentMemorySnapshot(named: "after-launch", in: app)
        }
        snapshots.append(launchSnapshot)

        var stepNumber = 3
        for cardIndex in 1...5 {
            let title = "cc-\(cardIndex)"

            performStep(String(format: "%02d-create-%@", stepNumber, title), in: app) {
                createCard(named: title, in: app)
            }
            stepNumber += 1

            let waitDuration = cardIndex == 5 ? 10.0 : 3.0
            performStep(String(format: "%02d-wait-%@", stepNumber, title), in: app) {
                RunLoop.current.run(until: Date().addingTimeInterval(waitDuration))
            }
            stepNumber += 1

            let snapshot = performStep(String(format: "%02d-memory-%@", stepNumber, title), in: app) {
                recordResidentMemorySnapshot(named: "after-opening-\(title)", in: app)
            }
            snapshots.append(snapshot)
            stepNumber += 1
        }

        attachResidentMemorySummary(snapshots)
        XCTAssertEqual(snapshots.count, 6, "Expected a launch measurement plus five card measurements")
        XCTAssertTrue(snapshots.allSatisfy { $0.bytes > 0 }, "Expected all resident memory samples to succeed")
    }

    @MainActor
    func testTerminalAcceptsCommandsInFreshCard() throws {
        let app = launchApp(terminalRuntime: .forceEnabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        let outputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)
        let command = "!echo -n ok > '\(outputURL.path)'"
        performStep("03-send-command", in: app) {
            sendPrompt(command, in: app)
        }

        performStep("04-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: outputURL.path)
                },
                "Expected terminal command to create \(outputURL.path)"
            )
        }

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(output, "ok")
    }

    @MainActor
    func testFreshCardOpensTerminalWithoutSurfaceChooser() throws {
        let app = launchApp(terminalRuntime: .forceEnabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        performStep("03-terminal-visible-without-chooser", in: app) {
            let terminalField = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "text entry area"))
                .firstMatch
            XCTAssertTrue(
                terminalField.waitForExistence(timeout: 10),
                "Expected terminal input to appear without needing an empty-pane choice"
            )
            XCTAssertFalse(app.buttons["Terminal"].exists, "Did not expect the empty-pane Terminal chooser button")
            XCTAssertFalse(app.buttons["Browser"].exists, "Did not expect the empty-pane Browser chooser button")
        }
    }

    @MainActor
    func testTerminalAcceptsCommandsAfterSwitchingCards() throws {
        let app = launchApp(terminalRuntime: .forceEnabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        performStep("03-create-cc-2", in: app) {
            createCard(named: "cc-2", in: app)
        }

        performStep("04-return-to-cc-1", in: app) {
            selectCard(named: "cc-1", in: app)
        }

        let outputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)
        let command = "!echo -n ok > '\(outputURL.path)'"
        performStep("05-send-command", in: app) {
            sendPrompt(command, in: app)
        }

        performStep("06-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: outputURL.path)
                },
                "Expected terminal command to create \(outputURL.path)"
            )
        }

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(output, "ok")
    }

    @MainActor
    func testDaemonTerminalAcceptsCommandsAfterHideShow() throws {
        let app = launchApp(terminalRuntime: .forceEnabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        let firstOutputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)
        let secondOutputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        let firstCommand = "!printf 1 > '\(firstOutputURL.path)'"
        performStep("03-send-first-command", in: app) {
            sendPrompt(firstCommand, in: app)
        }

        performStep("04-first-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: firstOutputURL.path)
                },
                "Expected terminal command to create \(firstOutputURL.path)"
            )
        }

        performStep("05-create-cc-2", in: app) {
            createCard(named: "cc-2", in: app)
        }

        performStep("06-return-to-cc-1", in: app) {
            selectCard(named: "cc-1", in: app)
        }

        let secondCommand = "!printf 2 > '\(secondOutputURL.path)'"
        performStep("07-send-second-command", in: app) {
            sendPrompt(secondCommand, in: app)
        }

        performStep("08-second-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: secondOutputURL.path)
                },
                "Expected terminal command to create \(secondOutputURL.path)"
            )
        }

    }

    @MainActor
    func testDaemonTerminalLongRunningCommandContinuesAcrossCardSwitch() throws {
        let app = launchApp(terminalRuntime: .forceEnabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        let delayedOutputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)
        let followUpOutputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        let delayedCommand = "!sleep 2; echo -n delayed > '\(delayedOutputURL.path)'"
        performStep("03-send-delayed-command", in: app) {
            sendPrompt(delayedCommand, in: app)
        }

        performStep("04-create-cc-2", in: app) {
            createCard(named: "cc-2", in: app)
        }

        performStep("05-delayed-command-finishes-while-hidden", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: delayedOutputURL.path)
                },
                "Expected delayed terminal command to finish while cc-1 is hidden"
            )
        }

        performStep("06-return-to-cc-1", in: app) {
            selectCard(named: "cc-1", in: app)
        }

        let followUpCommand = "!echo -n followup > '\(followUpOutputURL.path)'"
        performStep("07-send-followup-command", in: app) {
            sendPrompt(followUpCommand, in: app)
        }

        performStep("08-followup-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: followUpOutputURL.path)
                },
                "Expected follow-up terminal command to create \(followUpOutputURL.path)"
            )
        }

        XCTAssertEqual(try String(contentsOf: delayedOutputURL, encoding: .utf8), "delayed")
        XCTAssertEqual(try String(contentsOf: followUpOutputURL, encoding: .utf8), "followup")
    }

    @MainActor
    func testTerminalAcceptsCommandsInFreshCardWithLegacyOptOut() throws {
        let app = launchApp(terminalRuntime: .forceDisabled)
        performStep("01-board-loaded", in: app) {
            XCTAssertTrue(
                app.staticTexts["UI Test Board"].waitForExistence(timeout: 5),
                "Expected the seeded UI Test Board to load"
            )
        }

        performStep("02-create-cc-1", in: app) {
            createCard(named: "cc-1", in: app)
        }

        let outputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ztmp-\(UUID().uuidString).txt", isDirectory: false)
        let command = "!echo -n legacy > '\(outputURL.path)'"
        performStep("03-send-command", in: app) {
            sendPrompt(command, in: app)
        }

        performStep("04-command-produced-output", in: app) {
            XCTAssertTrue(
                waitForCondition(timeout: 10) {
                    FileManager.default.fileExists(atPath: outputURL.path)
                },
                "Expected terminal command to create \(outputURL.path)"
            )
        }

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(output, "legacy")
    }

    private func launchApp(terminalRuntime: TerminalRuntimeMode = .inheritDefault) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY"] = boardStorageDirectoryURL.path
        app.launchEnvironment["CMUX_UI_TEST_CARD_OUTLINE_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CARD_OUTLINE_SOURCE_TITLE"] = "cc-1"
        app.launchEnvironment["CMUX_UI_TEST_CARD_OUTLINE_TRIGGER_TITLE"] = "cc-2"
        app.launchEnvironment["CMUX_UI_TEST_CARD_OUTLINE_NOTIFICATION_TITLE"] = "Claude Code"
        app.launchEnvironment["CMUX_UI_TEST_CARD_OUTLINE_NOTIFICATION_BODY"] = "Selam! Nasıl yardımcı olabilirim?"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-notificationPaneRingEnabled", "YES",
        ]
        switch terminalRuntime {
        case .inheritDefault:
            break
        case .forceEnabled:
            app.launchEnvironment["ZENBAN_TERMINAL_RUNTIME_ENABLED"] = "1"
        case .forceDisabled:
            app.launchEnvironment["ZENBAN_TERMINAL_RUNTIME_ENABLED"] = "0"
        }
        app.launch()
        app.activate()
        return app
    }

    private func createCard(named title: String, in app: XCUIApplication) {
        let card = cardElement(named: title, in: app)
        let label = app.staticTexts[title].firstMatch
        let alreadyExists = waitForCondition(timeout: 1) {
            card.exists || label.exists
        }
        if alreadyExists {
            return
        }

        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                card.exists || label.exists
            },
            "Expected \(title) card to appear"
        )
        selectCard(named: title, in: app)
    }

    private func cardElement(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "BoardCard.\(title)")
            .firstMatch
    }

    private func selectCard(named title: String, in app: XCUIApplication) {
        let card = cardElement(named: title, in: app)
        let label = app.staticTexts[title].firstMatch

        if card.waitForExistence(timeout: 2) {
            card.click()
            return
        }

        XCTAssertTrue(label.waitForExistence(timeout: 2), "Expected \(title) label to exist")
        label.click()
    }

    private func cardFrame(for card: XCUIElement, fallback label: XCUIElement) -> CGRect? {
        if card.exists {
            return card.frame
        }
        if label.exists {
            return label.frame
        }
        return nil
    }

    private func sendPrompt(_ prompt: String, in app: XCUIApplication) {
        let terminalField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "text entry area"))
            .firstMatch

        if terminalField.waitForExistence(timeout: 10) {
            terminalField.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            terminalField.typeText(prompt + "\n")
            return
        } else {
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected app window to exist")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78)).click()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }

        app.typeText(prompt + "\n")
    }

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    @discardableResult
    private func performStep<T>(_ name: String, in app: XCUIApplication, _ body: () -> T) -> T {
        defer {
            attachStepScreenshot(named: name, in: app)
        }
        return body()
    }

    private func attachStepScreenshot(named name: String, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let screenshot = window.exists ? window.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func recordResidentMemorySnapshot(named name: String, in app: XCUIApplication) -> MemorySnapshot {
        let snapshot = settledResidentMemorySnapshot(named: name, in: app)
        let attachment = XCTAttachment(
            string: """
            label: \(snapshot.label)
            residentMemoryMB: \(formattedMegabytes(snapshot.bytes))
            residentMemoryBytes: \(snapshot.bytes)
            sampleCount: \(snapshot.sampleCount)
            settlingDurationSeconds: \(String(format: "%.2f", snapshot.settlingDuration))
            """
        )
        attachment.name = "Memory.\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return snapshot
    }

    private func settledResidentMemorySnapshot(named name: String, in app: XCUIApplication) -> MemorySnapshot {
        let startedAt = Date()
        let timeout: TimeInterval = 10
        let sampleInterval: TimeInterval = 0.25
        let stableSampleThreshold = 3
        let stabilityToleranceBytes: UInt64 = 2 * 1_048_576
        var sampleCount = 0
        var stableSamples = 0
        var previousSample: UInt64?
        var latestSample = residentMemoryInBytes(for: app)
        let deadline = startedAt.addingTimeInterval(timeout)

        repeat {
            latestSample = residentMemoryInBytes(for: app)
            sampleCount += 1

            if let previousSample,
               memoryDeltaBetween(latestSample, previousSample) <= stabilityToleranceBytes {
                stableSamples += 1
                if stableSamples >= stableSampleThreshold {
                    break
                }
            } else {
                stableSamples = 0
            }

            previousSample = latestSample
            RunLoop.current.run(until: Date().addingTimeInterval(sampleInterval))
        } while Date() < deadline

        return MemorySnapshot(
            label: name,
            bytes: latestSample,
            sampleCount: sampleCount,
            settlingDuration: Date().timeIntervalSince(startedAt)
        )
    }

    private func residentMemoryInBytes(for app: XCUIApplication) -> UInt64 {
        let processID = launchedApplicationProcessID(for: app)
        XCTAssertGreaterThan(processID, 0, "Expected the launched app to expose a valid process id")

        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout.size(ofValue: info))
        let copiedBytes = proc_pidinfo(processID, PROC_PIDTASKINFO, 0, &info, expectedSize)
        XCTAssertEqual(
            copiedBytes,
            expectedSize,
            "Expected proc_pidinfo to return a full proc_taskinfo payload for pid \(processID)"
        )

        return UInt64(info.pti_resident_size)
    }

    private func launchedApplicationProcessID(for app: XCUIApplication) -> pid_t {
        let runningApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: testedAppBundleIdentifier)
            .filter { !$0.isTerminated }

        if let activeApp = runningApps.first(where: \.isActive) {
            return activeApp.processIdentifier
        }

        if let launchedApp = runningApps.first {
            return launchedApp.processIdentifier
        }

        XCTFail("Expected \(testedAppBundleIdentifier) to be running after launch")
        return 0
    }

    private func attachResidentMemorySummary(_ snapshots: [MemorySnapshot]) {
        guard let baseline = snapshots.first else { return }

        var lines = ["Resident memory summary:"]
        for snapshot in snapshots {
            let deltaFromLaunch = Int64(snapshot.bytes) - Int64(baseline.bytes)
            lines.append(
                "\(snapshot.label): \(formattedMegabytes(snapshot.bytes)) MB (\(snapshot.bytes) bytes), " +
                "deltaFromLaunch: \(formattedMegabyteDelta(deltaFromLaunch)), " +
                "sampleCount: \(snapshot.sampleCount), " +
                "settlingDurationSeconds: \(String(format: "%.2f", snapshot.settlingDuration))"
            )
        }

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Memory.summary"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func memoryDeltaBetween(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    private func formattedMegabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_048_576)
    }

    private func formattedMegabyteDelta(_ bytes: Int64) -> String {
        String(format: "%+.2f", Double(bytes) / 1_048_576)
    }

    private func screenshotHasOrangeOutline(for card: XCUIElement, fallback label: XCUIElement, in app: XCUIApplication) -> Bool {
        if card.exists {
            return orangeOutlineExists(in: card.screenshot().pngRepresentation)
        }

        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5),
              label.exists,
              let cropped = croppedCardImage(around: label, in: window) else {
            XCTFail("Failed to capture the card region for outline verification")
            return false
        }

        return orangeOutlineExists(in: cropped)
    }

    private func orangeOutlineExists(in screenshotData: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(screenshotData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            XCTFail("Failed to decode card screenshot")
            return false
        }
        return orangeOutlineExists(in: cgImage)
    }

    private func orangeOutlineExists(in cgImage: CGImage) -> Bool {
        guard let pixelData = rgbaData(for: cgImage) else {
            XCTFail("Failed to decode card screenshot")
            return false
        }

        let width = cgImage.width
        let height = cgImage.height
        let band = max(3, min(width, height) / 24)
        var orangeCount = 0

        for y in 0..<height {
            for x in 0..<width {
                let isPerimeter = x < band || x >= width - band || y < band || y >= height - band
                guard isPerimeter else { continue }
                if isOrangePixel(atX: x, y: y, width: width, data: pixelData) {
                    orangeCount += 1
                }
            }
        }

        return orangeCount >= 80
    }

    private func croppedCardImage(around label: XCUIElement, in window: XCUIElement) -> Data? {
        let screenshot = window.screenshot()
        guard let imageSource = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        var cropRect = label.frame.insetBy(dx: -120, dy: -20)
        let windowFrame = window.frame
        cropRect.origin.x -= windowFrame.minX
        cropRect.origin.y -= windowFrame.minY
        cropRect = cropRect.intersection(CGRect(origin: .zero, size: windowFrame.size))
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(cgImage.width) / windowFrame.width
        let scaleY = CGFloat(cgImage.height) / windowFrame.height
        let pixelRect = CGRect(
            x: cropRect.minX * scaleX,
            y: cropRect.minY * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        ).integral

        guard let cropped = cgImage.cropping(to: pixelRect) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private func rgbaData(for image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func isOrangePixel(atX x: Int, y: Int, width: Int, data: [UInt8]) -> Bool {
        let offset = ((y * width) + x) * 4
        guard offset + 3 < data.count else { return false }

        let red = Int(data[offset])
        let green = Int(data[offset + 1])
        let blue = Int(data[offset + 2])
        let alpha = Int(data[offset + 3])

        guard alpha > 0 else { return false }
        return red > 150 && green > 70 && green < 220 && blue < 120 && red > green && green > blue + 20
    }

    private func writeSeedBoard() throws {
        let board = SeedBoard(name: "UI Test Board")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode([board])
        try data.write(
            to: boardStorageDirectoryURL.appendingPathComponent("boards.json"),
            options: .atomic
        )
    }
}

private struct MemorySnapshot {
    let label: String
    let bytes: UInt64
    let sampleCount: Int
    let settlingDuration: TimeInterval
}

private struct SeedBoard: Encodable {
    let id = UUID()
    let name: String
    let cards: [SeedCard] = []
    let createdAt = Date(timeIntervalSince1970: 0)
    let isPinned = false
    let repositoryPath: String? = nil
    let agent = "Claude Code"
    let devServerConfig: SeedDevServerConfig? = nil
    let agentCounters: [String: Int] = [:]
}

private struct SeedCard: Encodable {}

private struct SeedDevServerConfig: Encodable {}
