//
//  zenbanUITests.swift
//  zenbanUITests
//
//  Created by Berkay Çit on 25.12.2025.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class zenbanUITests: XCTestCase {
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

    private func launchApp() -> XCUIApplication {
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

        if terminalField.waitForExistence(timeout: 5) {
            terminalField.click()
        } else {
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected app window to exist")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78)).click()
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
