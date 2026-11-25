// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Testing
@testable import TotalDropMac

/// Deterministic mock bridge delegating stateless helpers to `LiveRustMacBridge`
/// while capturing session lifecycle calls without opening external sockets.
final class MockSessionBridge: MacBridgeProtocol, @unchecked Sendable {
    private let live = LiveRustMacBridge()
    private let lock = NSLock()
    private var nextHandle: UInt64 = 100
    var startedSendFiles: [[String]] = []
    var startedSendTexts: [String] = []
    var startedReceives: [String] = []
    var acceptedHandles: [(UInt64, String?)] = []
    var declinedHandles: [UInt64] = []
    var stoppedHandles: [UInt64] = []
    var destroyedHandles: [UInt64] = []
    var queuedEvents: [UInt64: [RustSessionEvent]] = [:]

    func versionInfo() -> RustVersionInfo? { live.versionInfo() }

    func loadUIBundle(preferredLanguages: [String], numericLocale: String?) -> RustUIBundle {
        live.loadUIBundle(preferredLanguages: preferredLanguages, numericLocale: numericLocale)
    }

    func handleURL(
        rawURL: String,
        activity: String,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustHandleURLResult? {
        live.handleURL(
            rawURL: rawURL,
            activity: activity,
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        )
    }

    func extractClipboardCode(_ rawText: String) -> RustExtractedCode? {
        live.extractClipboardCode(rawText)
    }

    func validateFinderURLs(
        _ urls: [String],
        activity: String,
        verifyOnDisk: Bool,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFinderBatch? {
        live.validateFinderURLs(
            urls,
            activity: activity,
            verifyOnDisk: verifyOnDisk,
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        )
    }

    func sanitizeFilename(_ rawName: String) -> RustSanitizedFilename? {
        live.sanitizeFilename(rawName)
    }

    func sanitizeText(_ rawText: String) -> RustSanitizedText? {
        live.sanitizeText(rawText)
    }

    func formatProgress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFormattedProgress? {
        live.formatProgress(
            doneBytes: doneBytes,
            totalBytes: totalBytes,
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        )
    }

    func startSendFiles(
        paths: [String],
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            startedSendFiles.append(paths)
            return h
        }
    }

    func startSendText(
        text: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            startedSendTexts.append(text)
            return h
        }
    }

    func startReceive(
        codeOrLink: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            startedReceives.append(codeOrLink)
            return h
        }
    }

    func acceptOffer(handle: UInt64, destDir: String?) -> Int32 {
        lock.withLock {
            acceptedHandles.append((handle, destDir))
            return 0
        }
    }

    func declineOffer(handle: UInt64) -> Int32 {
        lock.withLock {
            declinedHandles.append(handle)
            return 0
        }
    }

    func stopSession(handle: UInt64) -> Int32 {
        lock.withLock {
            stoppedHandles.append(handle)
            return 0
        }
    }

    func pollEvents(handle: UInt64) -> [RustSessionEvent] {
        lock.withLock {
            let evs = queuedEvents[handle] ?? []
            queuedEvents[handle] = []
            return evs
        }
    }

    func destroySession(handle: UInt64) -> Int32 {
        lock.withLock {
            destroyedHandles.append(handle)
            return 0
        }
    }
}

@Suite("TotalDropMac Rust FFI, Link, Finder & Session Tests")
struct LinkAndShareTests {
    @Test("Live Rust FFI reports aligned version and numeric CFBundleVersion")
    func rustVersionParity() throws {
        let bridge = LiveRustMacBridge()
        let info = try #require(bridge.versionInfo())
        #expect(info.ok)
        #expect(info.appVersion == "0.3.0-beta.6")
        #expect(info.coreVersion == "0.2.0-beta.5")
        #expect(info.bundleVersion == "6")
        let isNumericBuild = info.bundleVersion.allSatisfy(\.isNumber)
        #expect(isNumericBuild)
    }

    @Test("Live Rust FFI negotiates 35-language bundles including Arabic RTL")
    func rustLocalizationAndRTL() {
        let bridge = LiveRustMacBridge()
        let en = bridge.loadUIBundle(preferredLanguages: ["en-US"], numericLocale: "en_US")
        #expect(en.locale == "en")
        #expect(!en.isRtl)
        #expect(en.strings["verificationTitle"] == "Verification words")

        let tr = bridge.loadUIBundle(preferredLanguages: ["tr-TR", "en-US"], numericLocale: "tr_TR")
        #expect(tr.locale == "tr")
        #expect(!tr.isRtl)
        #expect(!(tr.strings["verificationTitle"] ?? "").isEmpty)

        let ar = bridge.loadUIBundle(preferredLanguages: ["ar-SA"], numericLocale: "ar_SA")
        #expect(ar.locale == "ar")
        #expect(ar.isRtl)
    }

    @Test("Live Rust FFI sanitizes Bidi filenames, text, and floor-rounds progress")
    func rustSanitizationAndProgress() throws {
        let bridge = LiveRustMacBridge()
        let file = try #require(bridge.sanitizeFilename("invoice\u{202E}fdp.app"))
        #expect(file.hasHiddenControls)
        #expect(file.sanitized == "invoice<U+202E>fdp.app")

        let text = try #require(bridge.sanitizeText("hello\u{202E}world\r\nline2"))
        #expect(text.hadHiddenControls)
        #expect(!text.shortened)
        #expect(text.displayText == "hello<U+202E>world\nline2")

        let progress = try #require(
            bridge.formatProgress(
                doneBytes: 999_999,
                totalBytes: 1_000_000,
                preferredLanguages: ["de-DE"],
                numericLocale: "de_DE"
            )
        )
        #expect(progress.percentValue == 99)
        #expect(progress.doneBytesText.contains(","))
    }

    @Test("Extracts code from Universal Link fragment via Rust")
    func universalLinkFragment() throws {
        let url = try #require(URL(string: "https://totaldrop.app/r#7-harbor-rocket"))
        #expect(MacAppModel.extractTransferCode(from: url) == "7-harbor-rocket")
    }

    @Test("Extracts code from custom totaldrop scheme via Rust")
    func customScheme() throws {
        let url = try #require(URL(string: "totaldrop://r/12-harbor-rocket-meadow"))
        #expect(MacAppModel.extractTransferCode(from: url) == "12-harbor-rocket-meadow")
    }

    @Test("Rejects non-TotalDrop host via Rust")
    func untrustedHost() throws {
        let url = try #require(URL(string: "https://example.org/r#7-harbor-rocket"))
        #expect(MacAppModel.extractTransferCode(from: url) == nil)
    }

    @Test("Deduplicates APFS NFD and case-colliding Finder file URLs via Rust")
    @MainActor
    func finderBatchCollisionAndNFD() {
        let mock = MockSessionBridge()
        let model = MacAppModel(bridge: mock, preferredLanguages: ["en-US"], numericLocale: "en_US")
        let urls = [
            URL(string: "file:///Users/ada/A/Cafe%CC%81.pdf")!,
            URL(string: "file:///Users/ada/B/caf%C3%A9.pdf")!,
        ]
        model.addSharedFileURLs(urls, verifyOnDisk: false)
        #expect(model.selectedFiles.count == 1)
        #expect(model.transientBanner != nil)
    }

    @Test("Routes incoming URL to Receive when idle and preserves active send when busy")
    @MainActor
    func incomingURLIdleAndBusyRouting() throws {
        let mock = MockSessionBridge()
        let idleModel = MacAppModel(bridge: mock, preferredLanguages: ["en-US"], numericLocale: "en_US")
        let firstLink = try #require(URL(string: "https://totaldrop.app/r#7-harbor-rocket"))
        idleModel.handleIncomingURL(firstLink)
        #expect(idleModel.selectedTab == .receive)
        #expect(idleModel.receiveInputCode == "7-harbor-rocket")
        #expect(idleModel.phase == .connecting(code: "7-harbor-rocket"))
        #expect(mock.startedReceives == ["7-harbor-rocket"])
        idleModel.stopActiveTransfer()

        let busyMock = MockSessionBridge()
        let busyModel = MacAppModel(bridge: busyMock, preferredLanguages: ["en-US"], numericLocale: "en_US")
        busyModel.selectedFiles = [URL(fileURLWithPath: "/Users/ada/Documents/Notes.txt")]
        busyModel.beginSend()
        busyModel.applySessionEvent(
            .codeReady(
                displayCode: "7-harbor-rocket",
                canonicalCode: "7-840-1499",
                universalLink: "https://totaldrop.app/r#7-harbor-rocket",
                schemeLink: "totaldrop://r/7-harbor-rocket",
                shareMessage: "Get my files with TotalDrop. Code: 7-harbor-rocket",
                entries: 1,
                totalBytes: 128,
                formattedTotal: "128 B",
                skipped: 0,
                isText: false
            )
        )
        #expect(busyModel.phase.isBusy)
        #expect(busyModel.menuBarStatusTitle == "7-harbor-rocket")

        let competingLink = try #require(URL(string: "totaldrop://r/9-harbor-rocket"))
        busyModel.handleIncomingURL(competingLink)
        #expect(busyModel.selectedTab == .send)
        #expect(busyModel.receiveInputCode.isEmpty)
        #expect(busyModel.transientBanner != nil)
        busyModel.stopActiveTransfer()
        #expect(busyModel.phase == .idle)
        #expect(busyModel.menuBarStatusTitle == "TotalDrop")
    }

    @Test("Projects offer_ready -> acceptOffer -> progress -> done lifecycle")
    @MainActor
    func receiveOfferAcceptAndCompletionLifecycle() {
        let mock = MockSessionBridge()
        let model = MacAppModel(bridge: mock, preferredLanguages: ["ar-SA"], numericLocale: "ar_SA")
        #expect(model.layoutDirection == .rightToLeft)

        model.receiveInputCode = "7-harbor-rocket"
        model.startReceiveConnection()
        #expect(model.phase == .connecting(code: "7-harbor-rocket"))

        model.applySessionEvent(
            .offerReady(
                files: 1,
                dirs: 0,
                totalBytes: 2048,
                formattedSize: "2 kB",
                isText: false,
                headline: "Incoming files",
                summaryLine: "1 file · 2 kB",
                topLevelNames: ["report<U+202E>fdp.app"],
                remainingNames: 0,
                moreNamesLine: nil,
                hasHiddenControls: true,
                verificationWords: ["able", "acid", "aged", "also"],
                joinedWordsLtr: "\u{2066}able · acid · aged · also\u{2069}"
            )
        )
        #expect(model.phase.bridgeActivityName == "offer_pending")

        model.acceptPendingOffer()
        #expect(mock.acceptedHandles.count == 1)

        model.applySessionEvent(
            .progress(
                doneBytes: 1024,
                totalBytes: 2048,
                percentValue: 50,
                percentText: "50%",
                doneBytesText: "1 kB",
                totalBytesText: "2 kB",
                fractionText: "1 kB / 2 kB",
                menuBarLabel: "50% · 1 kB"
            )
        )
        #expect(model.menuBarStatusTitle == "50% · 1 kB")

        model.applySessionEvent(
            .done(
                filesOk: 1,
                filesFailed: 0,
                bytes: 2048,
                formattedBytes: "2 kB",
                isText: false,
                savedTo: "/Users/ada/Downloads/TotalDrop",
                placed: ["report.pdf"],
                receivedText: nil,
                sanitizedText: nil,
                textShortened: false,
                textHadHiddenControls: false
            )
        )
        #expect(!model.phase.isBusy)
        #expect(model.menuBarStatusTitle == "TotalDrop")
        #expect(mock.destroyedHandles.count == 1)
    }

    @Test("Rejects non-file HTTPS URLs in addSharedFileURLs via Rust")
    @MainActor
    func rejectsNonFileURLsInSharedBatch() throws {
        let mock = MockSessionBridge()
        let model = MacAppModel(bridge: mock, preferredLanguages: ["en-US"], numericLocale: "en_US")
        let remoteOne = try #require(URL(string: "https://totaldrop.app/r#7-harbor-rocket"))
        let localFile = URL(fileURLWithPath: "/Users/ada/Documents/Notes.txt")
        model.addSharedFileURLs([remoteOne, localFile], verifyOnDisk: false)
        #expect(model.selectedFiles == [localFile])
        #expect(model.transientBanner != nil)
    }
}
