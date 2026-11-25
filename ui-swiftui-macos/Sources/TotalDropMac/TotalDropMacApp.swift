// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import SwiftUI

/// Primary navigation tabs inside the macOS window.
public enum MacTab: String, CaseIterable, Identifiable, Sendable {
    case send
    case receive

    public var id: String { rawValue }
}

/// Lifecycle phase of an active macOS transfer, projected directly from
/// `totaldrop-macos-ffi` NDJSON session events.
public enum MacTransferPhase: Equatable, Sendable {
    case idle
    case preparing
    case waitingForReceiver(code: String, universalLink: String, shareMessage: String)
    case connecting(code: String)
    case offerPending(
        files: Int,
        dirs: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        headline: String,
        summaryLine: String,
        words: [String],
        topLevelNames: [String],
        moreNamesLine: String?,
        hasHiddenControls: Bool
    )
    case transferring(
        doneBytes: UInt64,
        totalBytes: UInt64,
        percent: Int,
        fractionText: String,
        menuBarLabel: String,
        words: [String]
    )
    case completed(
        summaryText: String,
        savedFolder: URL?,
        receivedText: String?,
        sanitizedText: String?,
        textShortened: Bool,
        textHadHiddenControls: Bool
    )
    case failed(headline: String, cause: String?, technicalDetail: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        case .preparing, .waitingForReceiver, .connecting, .offerPending, .transferring:
            return true
        }
    }

    public var bridgeActivityName: String {
        switch self {
        case .idle, .failed:
            return "idle"
        case .completed(_, _, let receivedText, _, _, _):
            return receivedText == nil ? "idle" : "showing_received_text"
        case .offerPending:
            return "offer_pending"
        case .preparing, .waitingForReceiver, .connecting, .transferring:
            return "transfer_running"
        }
    }
}

/// Prevents idle system sleep on macOS while a file transfer is running.
@MainActor
final class MacSleepAssertion {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isHeld = false

    func acquire(reason: String) {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isHeld = true
        }
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isHeld = false
    }
}

/// Observable application coordinator backed by `totaldrop-macos-ffi` (Rust).
@Observable
@MainActor
public final class MacAppModel {
    public var selectedTab: MacTab = .send
    public var selectedFiles: [URL] = []
    public var textPayload: String = ""
    public var sendTextMode: Bool = false
    public var strongerCode: Bool = false
    public var receiveInputCode: String = ""
    public var phase: MacTransferPhase = .idle
    public var transientBanner: String?

    // Network and privacy settings (persisted in macOS UserDefaults).
    public var rendezvousServer: String = "wss://rendezvous.totaldrop.app"
    public var relayServer: String = "wss://relay.totaldrop.app"
    public var stunServer: String = "stun.cloudflare.com:3478"
    public var privacyMode: Bool = false
    public var destinationFolder: URL

    // 35-language localization bundle negotiated by Rust `totaldrop-l10n`.
    public private(set) var l10n: RustUIBundle
    public private(set) var layoutDirection: LayoutDirection
    public private(set) var localeTag: String

    private let bridge: any MacBridgeProtocol
    private let preferredLanguages: [String]
    private let numericLocale: String?
    private let sleepAssertion = MacSleepAssertion()
    private var activeSessionHandle: UInt64?
    private var pollingTask: Task<Void, Never>?
    private var activeVerificationWords: [String] = []
    private var activeOfferIsText: Bool = false

    public init(
        bridge: any MacBridgeProtocol = LiveRustMacBridge(),
        preferredLanguages: [String] = Locale.preferredLanguages,
        numericLocale: String? = Locale.current.identifier
    ) {
        self.bridge = bridge
        self.preferredLanguages = preferredLanguages.isEmpty ? ["en"] : preferredLanguages
        self.numericLocale = numericLocale
        let bundle = bridge.loadUIBundle(
            preferredLanguages: self.preferredLanguages,
            numericLocale: numericLocale
        )
        self.l10n = bundle
        self.localeTag = bundle.locale
        self.layoutDirection = bundle.isRtl ? .rightToLeft : .leftToRight
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        self.destinationFolder = downloads.appendingPathComponent("TotalDrop", isDirectory: true)
    }

    public func t(_ key: String, fallback: String) -> String {
        l10n.text(key, fallback: fallback)
    }

    /// Routes an incoming `totaldrop://r/<code>`, `totaldrop://share-handoff`,
    /// or `https://totaldrop.app/r#<code>` Universal Link strictly through Rust.
    public func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == "totaldrop" && url.host?.lowercased() == "share-handoff" {
            ingestPendingFinderShareHandoff()
            return
        }
        guard let result = bridge.handleURL(
            rawURL: url.absoluteString,
            activity: phase.bridgeActivityName,
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        ) else {
            transientBanner = t("errorInvalidCode", fallback: "That link does not hold a valid TotalDrop code.")
            return
        }
        switch result.outcome {
        case "open_receive":
            guard let displayCode = result.displayCode, !displayCode.isEmpty else {
                transientBanner = t("errorInvalidCode", fallback: "That link does not hold a valid TotalDrop code.")
                return
            }
            transientBanner = nil
            selectedTab = .receive
            receiveInputCode = displayCode
            startReceiveConnection()
        case "busy":
            transientBanner = result.message
                ?? t("linkBusy", fallback: "Finish or stop what is on the screen, then open the link again.")
        default:
            transientBanner = result.message
                ?? t("errorInvalidCode", fallback: "That link does not hold a valid TotalDrop code.")
        }
    }

    /// Consumes URLs handed off by `FinderShareExtension` through the shared App Group.
    public func ingestPendingFinderShareHandoff() {
        guard let defaults = UserDefaults(suiteName: "group.app.totaldrop.mac"),
              let rawStrings = defaults.stringArray(forKey: "pendingFinderShareURLs"),
              !rawStrings.isEmpty
        else {
            return
        }
        defaults.removeObject(forKey: "pendingFinderShareURLs")
        defaults.removeObject(forKey: "pendingFinderSkippedCount")
        let urls = rawStrings.compactMap(URL.init(string:))
        addSharedFileURLs(urls, verifyOnDisk: true)
    }

    /// Extracts a normalized transfer code from Universal Links, custom URLs,
    /// or clipboard text strictly via Rust (`TransferCode::from_link` / `find`).
    nonisolated public static func extractTransferCode(from url: URL) -> String? {
        let bridge = LiveRustMacBridge()
        guard let result = bridge.handleURL(
            rawURL: url.absoluteString,
            activity: "idle",
            preferredLanguages: ["en"],
            numericLocale: "en_US"
        ), result.outcome == "open_receive" else {
            return nil
        }
        return result.displayCode
    }

    /// Extracts a transfer code from arbitrary pasted or QR-decoded text via Rust.
    public func extractCodeFromClipboardText(_ rawText: String) -> String? {
        guard let res = bridge.extractClipboardCode(rawText), res.ok else { return nil }
        return res.displayCode
    }

    /// Validates Finder or drag-and-drop `file://` URLs strictly through Rust
    /// (APFS NFD-to-NFC normalization, `validate_path`, case-collision check).
    public func addSharedFileURLs(_ urls: [URL], verifyOnDisk: Bool = false) {
        let existingURLStrings = selectedFiles.map(\.absoluteString)
        let incomingStrings = urls.map(\.absoluteString)
        let combined = existingURLStrings + incomingStrings

        guard let batch = bridge.validateFinderURLs(
            combined,
            activity: phase.bridgeActivityName,
            verifyOnDisk: verifyOnDisk,
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        ) else {
            transientBanner = t("sendAddFailed", fallback: "The files could not be added.")
            return
        }

        if batch.busy {
            transientBanner = batch.notice
                ?? t("shareBusy", fallback: "A transfer is still running. Wait for it to finish or stop it, then share again.")
            return
        }

        selectedFiles = batch.accepted.map { URL(fileURLWithPath: $0.path) }
        selectedTab = .send
        sendTextMode = false
        transientBanner = batch.notice
    }

    /// Sanitizes an untrusted filename through Rust for safe UI rendering.
    public func displaySafeFilename(_ rawName: String) -> String {
        bridge.sanitizeFilename(rawName)?.sanitized ?? rawName
    }

    /// Starts a real end-to-end encrypted send session on the Rust Tokio engine.
    public func beginSend() {
        guard !phase.isBusy else { return }
        let config = currentTransferConfig()
        let handle: UInt64
        if sendTextMode {
            guard !textPayload.isEmpty else { return }
            handle = bridge.startSendText(
                text: textPayload,
                config: config,
                preferredLanguages: preferredLanguages,
                numericLocale: numericLocale
            )
        } else {
            guard !selectedFiles.isEmpty else { return }
            let paths = selectedFiles.map(\.path)
            handle = bridge.startSendFiles(
                paths: paths,
                config: config,
                preferredLanguages: preferredLanguages,
                numericLocale: numericLocale
            )
        }
        guard handle != 0 else {
            phase = .failed(
                headline: t("sendAddFailed", fallback: "The files could not be added."),
                cause: nil,
                technicalDetail: "FFI rejected send session start parameters."
            )
            return
        }
        transientBanner = nil
        activeVerificationWords = []
        activeOfferIsText = sendTextMode
        sleepAssertion.acquire(reason: t("keepAwakeReason", fallback: "TotalDrop is sending or receiving files"))
        phase = .preparing
        startPolling(handle: handle)
    }

    /// Starts a real receive connection on the Rust Tokio engine.
    public func startReceiveConnection() {
        let trimmed = receiveInputCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phase.isBusy else { return }
        let handle = bridge.startReceive(
            codeOrLink: trimmed,
            config: currentTransferConfig(),
            preferredLanguages: preferredLanguages,
            numericLocale: numericLocale
        )
        guard handle != 0 else {
            phase = .failed(
                headline: t("receiveCodeInvalid", fallback: "That does not look like a code."),
                cause: nil,
                technicalDetail: "FFI rejected receive session start parameters."
            )
            return
        }
        transientBanner = nil
        activeVerificationWords = []
        activeOfferIsText = false
        sleepAssertion.acquire(reason: t("keepAwakeReason", fallback: "TotalDrop is sending or receiving files"))
        phase = .connecting(code: trimmed)
        startPolling(handle: handle)
    }

    /// Accepts the currently displayed incoming offer through Rust.
    public func acceptPendingOffer() {
        guard let handle = activeSessionHandle else { return }
        if !activeOfferIsText {
            try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }
        let destPath: String? = activeOfferIsText ? nil : destinationFolder.path
        let rc = bridge.acceptOffer(handle: handle, destDir: destPath)
        if rc != 0 {
            let headline = t("errorOther", fallback: "Something went wrong")
            finishSession(with: .failed(headline: headline, cause: nil, technicalDetail: "acceptOffer returned \(rc)"))
        }
    }

    /// Declines the currently displayed incoming offer through Rust.
    public func declinePendingOffer() {
        guard let handle = activeSessionHandle else { return }
        let rc = bridge.declineOffer(handle: handle)
        if rc != 0 {
            stopActiveTransfer()
        }
    }

    /// Stops any active Rust transfer session and releases system sleep prevention.
    public func stopActiveTransfer() {
        pollingTask?.cancel()
        pollingTask = nil
        if let handle = activeSessionHandle {
            _ = bridge.stopSession(handle: handle)
            _ = bridge.destroySession(handle: handle)
            activeSessionHandle = nil
        }
        activeVerificationWords = []
        sleepAssertion.release()
        phase = .idle
    }

    /// Resets a completed or failed session back to idle.
    public func resetCompletedOrFailed() {
        stopActiveTransfer()
    }

    /// Applies one Rust session event directly to `phase` (exposed internally for deterministic tests).
    public func applySessionEvent(_ event: RustSessionEvent) {
        switch event {
        case .codeReady(let displayCode, _, let universalLink, _, let shareMessage, _, _, _, _, _):
            phase = .waitingForReceiver(
                code: displayCode,
                universalLink: universalLink,
                shareMessage: shareMessage
            )
        case .waiting:
            break
        case .connected(let words, _):
            activeVerificationWords = words
            if case .waitingForReceiver = phase {
                phase = .transferring(
                    doneBytes: 0,
                    totalBytes: 0,
                    percent: 0,
                    fractionText: "",
                    menuBarLabel: t("sendSending", fallback: "Sending"),
                    words: words
                )
            }
        case .offerReady(
            let files,
            let dirs,
            let totalBytes,
            let formattedSize,
            let isText,
            let headline,
            let summaryLine,
            let topLevelNames,
            _,
            let moreNamesLine,
            let hasHiddenControls,
            let words,
            _
        ):
            activeVerificationWords = words
            activeOfferIsText = isText
            phase = .offerPending(
                files: files,
                dirs: dirs,
                totalBytes: totalBytes,
                formattedSize: formattedSize,
                isText: isText,
                headline: headline,
                summaryLine: summaryLine,
                words: words,
                topLevelNames: topLevelNames,
                moreNamesLine: moreNamesLine,
                hasHiddenControls: hasHiddenControls
            )
        case .progress(let doneBytes, let totalBytes, let percentValue, _, _, _, let fractionText, let menuBarLabel):
            phase = .transferring(
                doneBytes: doneBytes,
                totalBytes: totalBytes,
                percent: percentValue,
                fractionText: fractionText,
                menuBarLabel: menuBarLabel,
                words: activeVerificationWords
            )
        case .done(
            let filesOk,
            _,
            _,
            let formattedBytes,
            let isText,
            let savedTo,
            _,
            let receivedText,
            let sanitizedText,
            let textShortened,
            let textHadHiddenControls
        ):
            let folderURL = savedTo.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let summary: String
            if isText {
                summary = selectedTab == .send
                    ? t("sendTextDone", fallback: "The text arrived intact.")
                    : t("receiveTextDone", fallback: "Text received and verified")
            } else {
                summary = "\(filesOk) file(s) · \(formattedBytes)"
            }
            finishSession(
                with: .completed(
                    summaryText: summary,
                    savedFolder: folderURL,
                    receivedText: receivedText,
                    sanitizedText: sanitizedText,
                    textShortened: textShortened,
                    textHadHiddenControls: textHadHiddenControls
                )
            )
        case .declined(_, let headline):
            finishSession(with: .failed(headline: headline, cause: nil, technicalDetail: "Offer declined."))
        case .failed(_, let headline, let cause, let technicalDetail):
            finishSession(with: .failed(headline: headline, cause: cause, technicalDetail: technicalDetail))
        }
    }

    public var menuBarStatusTitle: String {
        switch phase {
        case .idle, .completed, .failed:
            return "TotalDrop"
        case .preparing:
            return t("sendPreparing", fallback: "Preparing…")
        case .waitingForReceiver(let code, _, _):
            return code
        case .connecting:
            return t("receiveConnecting", fallback: "Connecting securely…")
        case .offerPending(_, _, _, _, _, let headline, _, _, _, _, _):
            return headline
        case .transferring(_, _, _, _, let label, _):
            return label
        }
    }

    private func currentTransferConfig() -> RustTransferConfig {
        RustTransferConfig(
            server: rendezvousServer,
            relay: relayServer,
            stun: stunServer,
            privacyMode: privacyMode,
            strongerCode: strongerCode
        )
    }

    private func startPolling(handle: UInt64) {
        pollingTask?.cancel()
        activeSessionHandle = handle
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeSessionHandle == handle else { return }
                let events = self.bridge.pollEvents(handle: handle)
                for ev in events {
                    self.applySessionEvent(ev)
                    if self.activeSessionHandle != handle {
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func finishSession(with terminalPhase: MacTransferPhase) {
        pollingTask?.cancel()
        pollingTask = nil
        if let handle = activeSessionHandle {
            _ = bridge.destroySession(handle: handle)
            activeSessionHandle = nil
        }
        sleepAssertion.release()
        phase = terminalPhase
    }
}

@main
struct TotalDropMacApp: App {
    @State private var model = MacAppModel()

    var body: some Scene {
        WindowGroup("TotalDrop", id: "main") {
            MacRootWindowView(model: model)
                .environment(\.layoutDirection, model.layoutDirection)
                .frame(minWidth: 640, minHeight: 460)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        model.handleIncomingURL(url)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))

        MenuBarExtra(
            model.menuBarStatusTitle,
            systemImage: model.phase.isBusy ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
        ) {
            MacMenuBarContent(model: model)
        }

        Settings {
            MacSettingsView(model: model)
                .environment(\.layoutDirection, model.layoutDirection)
        }
    }
}

struct MacRootWindowView: View {
    @Bindable var model: MacAppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedTab) {
                Label(model.t("homeSendTitle", fallback: "Send"), systemImage: "arrow.up.doc")
                    .tag(MacTab.send)
                Label(model.t("homeReceiveTitle", fallback: "Receive"), systemImage: "arrow.down.doc")
                    .tag(MacTab.receive)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.transientBanner {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(banner)
                            .font(.callout)
                        Spacer()
                        Button(model.t("cancel", fallback: "Dismiss")) {
                            model.transientBanner = nil
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                }

                Group {
                    switch model.selectedTab {
                    case .send:
                        SendView(model: model)
                    case .receive:
                        ReceiveView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
            }
        }
    }
}

struct MacMenuBarContent: View {
    @Bindable var model: MacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            Text(
                model.phase.isBusy
                    ? model.menuBarStatusTitle
                    : model.t("appTagline", fallback: "Any file, to anyone, anywhere.")
            )
        }

        Button(model.t("sendTitle", fallback: "Send files")) {
            model.selectedTab = .send
            model.sendTextMode = false
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button(model.t("sendClipboard", fallback: "Send clipboard")) {
            if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                model.textPayload = clip
                model.sendTextMode = true
                model.selectedTab = .send
            } else {
                model.transientBanner = model.t("sendClipboardEmpty", fallback: "The clipboard holds no text.")
            }
            openWindow(id: "main")
            NSApplication.shared.activate()
        }

        Button(model.t("receiveTitle", fallback: "Receive files")) {
            model.selectedTab = .receive
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        if model.phase.isBusy {
            Divider()
            Button(model.t("stop", fallback: "Stop"), role: .destructive) {
                model.stopActiveTransfer()
            }
        }

        Divider()
        SettingsLink {
            Text(model.t("settings", fallback: "Settings"))
        }
        Divider()
        Button("Quit TotalDrop") {
            model.stopActiveTransfer()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct MacSettingsView: View {
    @Bindable var model: MacAppModel

    var body: some View {
        Form {
            Section(model.t("settingsServer", fallback: "Rendezvous server")) {
                TextField(model.t("settingsServer", fallback: "Rendezvous server"), text: $model.rendezvousServer)
                TextField("Relay", text: $model.relayServer)
                Button(model.t("settingsServerReset", fallback: "Use the default")) {
                    model.rendezvousServer = "wss://rendezvous.totaldrop.app"
                    model.relayServer = "wss://relay.totaldrop.app"
                    model.stunServer = "stun.cloudflare.com:3478"
                }
            }
            Section(model.t("settingsPrivacy", fallback: "Privacy")) {
                Toggle(model.t("privacyMode", fallback: "Hide my address from the other device"), isOn: $model.privacyMode)
                Text(model.t("privacyModeHint", fallback: "Everything goes through the relay so the peer never sees your IP address."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
