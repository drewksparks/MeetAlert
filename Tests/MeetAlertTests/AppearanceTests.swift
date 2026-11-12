import AppKit
import SwiftUI
import XCTest
@testable import MeetAlert

@MainActor
final class AppearanceTests: XCTestCase {
    func testOldConfigKeepsOriginalAppearance() throws {
        let config = try JSONDecoder().decode(Store.Config.self, from: Data(##"{"ntfyTopic":"example"}"##.utf8))
        XCTAssertEqual(config.alertAppearance, AlertAppearance())
        XCTAssertEqual(config.ntfyTopic, "example")
        XCTAssertEqual(config.alertAppearance.width, 640)
        XCTAssertEqual(config.alertAppearance.height, 168)
    }

    func testAppearanceRoundTripPreservesHiddenButtonsAndColors() throws {
        var config = Store.Config()
        config.alertAppearance.width = 888
        config.alertAppearance.textScale = 150
        config.alertAppearance.showJoin = false
        config.alertAppearance.showSnooze = false
        config.alertAppearance.showDismiss = false
        config.alertAppearance.showIgnore = false
        config.alertAppearance.customColors = true
        config.alertAppearance.background = "#16324F"
        let result = try JSONDecoder().decode(Store.Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(result, config)
    }

    func testBadAppearanceFieldsDoNotResetCalendarOrPhonePreferences() throws {
        let data = Data(##"{"ntfyTopic":"keep-me","ignoreAllDay":false,"alertAppearance":{"width":-20,"height":999999,"textScale":500,"showJoin":false,"showDismiss":"bad","background":"invalid","upcoming":"#ff0088"}}"##.utf8)
        let config = try JSONDecoder().decode(Store.Config.self, from: data)
        XCTAssertEqual(config.ntfyTopic, "keep-me")
        XCTAssertFalse(config.ignoreAllDay)
        XCTAssertEqual(config.alertAppearance.width, 480)
        XCTAssertEqual(config.alertAppearance.height, 480)
        XCTAssertEqual(config.alertAppearance.textScale, 200)
        XCTAssertFalse(config.alertAppearance.showJoin)
        XCTAssertTrue(config.alertAppearance.showDismiss)
        XCTAssertEqual(config.alertAppearance.background, "#FFFFFF")
        XCTAssertEqual(config.alertAppearance.upcoming, "#FF0088")
    }

    func testMalformedAppearanceObjectFallsBackWithoutLosingOtherConfig() throws {
        let data = Data(##"{"ntfyTopic":"keep-me","alertAppearance":"bad"}"##.utf8)
        let config = try JSONDecoder().decode(Store.Config.self, from: data)
        XCTAssertEqual(config.ntfyTopic, "keep-me")
        XCTAssertEqual(config.alertAppearance, AlertAppearance())
    }

    func testCustomColorsKeepTextReadableAcrossBackgrounds() throws {
        for background in ["#FFFFFF", "#000000", "#777777", "#FFFF00", "#16324F"] {
            let bg = try XCTUnwrap(NSColor(hex: background))
            XCTAssertGreaterThanOrEqual(bg.contrastingText.contrastRatio(against: bg), 4.5)
            for color in ["#FFFFFF", "#000000", "#777777", "#FFFF00", "#FF0088", background] {
                let signal = try XCTUnwrap(NSColor(hex: color)).readable(on: bg)
                XCTAssertGreaterThanOrEqual(signal.contrastRatio(against: bg), 4.5, "\(color) on \(background)")
                XCTAssertGreaterThanOrEqual(signal.contrastingText.contrastRatio(against: signal), 4.5)
            }
        }
    }

    func testReadableCustomColorIsPreserved() throws {
        let color = try XCTUnwrap(NSColor(hex: "#006A85"))
        XCTAssertEqual(color.readable(on: .white).hexString, color.hexString)
    }

    /// Optional offscreen QA, with no real calendar, Keychain, or notification activity.
    /// MEETALERT_APPEARANCE_SCREENSHOTS=/tmp/meetalert-appearance swift test --filter AppearanceTests/testRender
    func testRender() throws {
        guard let path = ProcessInfo.processInfo.environment["MEETALERT_APPEARANCE_SCREENSHOTS"] else {
            throw XCTSkip("optional appearance screenshots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var compact = AlertAppearance(); compact.width = 480
        var largeText = compact; largeText.textScale = 200
        var hidden = compact
        hidden.showJoin = false; hidden.showSnooze = false; hidden.showDismiss = false; hidden.showIgnore = false
        var custom = AlertAppearance()
        custom.customColors = true; custom.background = "#16324F"; custom.upcoming = "#FFFF00"
        var lowContrast = compact
        lowContrast.customColors = true; lowContrast.background = "#FFFFFF"; lowContrast.upcoming = "#FFFFFF"
        for (name, appearance) in [("default", AlertAppearance()), ("compact", compact), ("large-text", largeText),
                                   ("hidden", hidden), ("custom", custom), ("low-contrast", lowContrast)] {
            let start = Date().addingTimeInterval(180)
            let meeting = Store.Meeting(key: "sample", title: "Design review and planning for the next release", start: start,
                                        end: start.addingTimeInterval(1800), hasPhysicalLocation: false,
                                        joinURL: URL(string: "https://meet.google.com/example"), seriesId: "sample",
                                        calendarTitle: "Product team calendar", calendarColor: .systemBlue)
            let host = NSHostingView(rootView: AlertContent(meeting: meeting, state: PanelState(), onJoin: {},
                onSnooze1: {}, onSnooze5: {}, onSnoozeStart: {}, onIgnore: {}, onDismiss: {}, appearance: appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: appearance.width, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            XCTAssertEqual(size.width, CGFloat(appearance.width), accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, CGFloat(appearance.height))
            XCTAssertLessThan(size.height, 700, "Popup should fit a typical laptop display")
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            print("Appearance screenshot: \(name) \(size)")
        }
    }
}
