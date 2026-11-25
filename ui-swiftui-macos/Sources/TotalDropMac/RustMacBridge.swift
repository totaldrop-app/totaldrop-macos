// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CTotalDropMacFFI
import Foundation

/// Version metadata returned by `totaldrop_mac_version_json`.
public struct RustVersionInfo: Codable, Equatable, Sendable {
    public let ok: Bool
    public let appVersion: String
    public let coreVersion: String
    public let bundleVersion: String

    enum CodingKeys: String, CodingKey {
        case ok
        case appVersion = "app_version"
        case coreVersion = "core_version"
        case bundleVersion = "bundle_version"
    }
}

/// Negotiated 35-language localization bundle from `totaldrop-l10n`.
public struct RustUIBundle: Codable, Equatable, Sendable {
    public let locale: String
    public let isRtl: Bool
    public let isDraft: Bool
    public let strings: [String: String]

    public init(locale: String, isRtl: Bool, isDraft: Bool, strings: [String: String]) {
        self.locale = locale
        self.isRtl = isRtl
        self.isDraft = isDraft
        self.strings = strings
    }

    public func text(_ key: String, fallback: String) -> String {
        if let value = strings[key], !value.isEmpty {
            return value
        }
        return fallback
    }
}

/// Result of routing an incoming `totaldrop://` or Universal Link through Rust.
public struct RustHandleURLResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let outcome: String
    public let displayCode: String?
    public let canonicalCode: String?
    public let universalLink: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case outcome
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case message
    }
}

/// Normalized transfer code extracted from clipboard or QR payloads by Rust.
public struct RustExtractedCode: Codable, Equatable, Sendable {
    public let ok: Bool
    public let displayCode: String?
    public let canonicalCode: String?
    public let universalLink: String?
    public let schemeLink: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case schemeLink = "scheme_link"
    }
}

/// One validated local file or folder returned by Rust Finder URL validation.
public struct RustFinderItem: Codable, Equatable, Sendable {
    public let path: String
    public let normalizedName: String
    public let collisionKey: String
    public let isDirectory: Bool
    public let byteSize: UInt64

    enum CodingKeys: String, CodingKey {
        case path
        case normalizedName = "normalized_name"
        case collisionKey = "collision_key"
        case isDirectory = "is_directory"
        case byteSize = "byte_size"
    }
}

/// One rejected input entry from Rust Finder URL validation.
public struct RustFinderSkipped: Codable, Equatable, Sendable {
    public let rawUrl: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case rawUrl = "raw_url"
        case reason
    }
}

/// Result batch from `totaldrop_mac_validate_finder_urls_json`.
public struct RustFinderBatch: Codable, Equatable, Sendable {
    public let ok: Bool
    public let busy: Bool
    public let accepted: [RustFinderItem]
    public let skipped: [RustFinderSkipped]
    public let notice: String?
}

/// Sanitized filename returned by `totaldrop_mac_sanitize_filename_json`.
public struct RustSanitizedFilename: Codable, Equatable, Sendable {
    public let ok: Bool
    public let sanitized: String
    public let hasHiddenControls: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case sanitized
        case hasHiddenControls = "has_hidden_controls"
    }
}

/// Sanitized display text returned by `totaldrop_mac_sanitize_text_json`.
public struct RustSanitizedText: Codable, Equatable, Sendable {
    public let ok: Bool
    public let displayText: String
    public let shortened: Bool
    public let hadHiddenControls: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case displayText = "display_text"
        case shortened
        case hadHiddenControls = "had_hidden_controls"
    }
}

/// Regional progress formatting returned by `totaldrop_mac_format_progress_json`.
public struct RustFormattedProgress: Codable, Equatable, Sendable {
    public let ok: Bool
    public let percentValue: Int
    public let percentText: String
    public let doneBytesText: String
    public let totalBytesText: String
    public let fractionText: String
    public let menuBarLabel: String

    enum CodingKeys: String, CodingKey {
        case ok
        case percentValue = "percent_value"
        case percentText = "percent_text"
        case doneBytesText = "done_bytes_text"
        case totalBytesText = "total_bytes_text"
        case fractionText = "fraction_text"
        case menuBarLabel = "menu_bar_label"
    }
}

/// Network and security transfer configuration serialized to Rust.
public struct RustTransferConfig: Codable, Equatable, Sendable {
    public let server: String
    public let relay: String
    public let stun: String
    public let privacyMode: Bool
    public let strongerCode: Bool

    public init(
        server: String,
        relay: String,
        stun: String = "stun.cloudflare.com:3478",
        privacyMode: Bool,
        strongerCode: Bool
    ) {
        self.server = server
        self.relay = relay
        self.stun = stun
        self.privacyMode = privacyMode
        self.strongerCode = strongerCode
    }

    enum CodingKeys: String, CodingKey {
        case server
        case relay
        case stun
        case privacyMode = "privacy_mode"
        case strongerCode = "stronger_code"
    }
}

/// Structured NDJSON event emitted by an active Rust transfer session.
public enum RustSessionEvent: Equatable, Sendable {
    case codeReady(
        displayCode: String,
        canonicalCode: String,
        universalLink: String,
        schemeLink: String,
        shareMessage: String,
        entries: Int,
        totalBytes: UInt64,
        formattedTotal: String,
        skipped: Int,
        isText: Bool
    )
    case waiting(headline: String)
    case connected(verificationWords: [String], joinedWordsLtr: String)
    case offerReady(
        files: Int,
        dirs: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        headline: String,
        summaryLine: String,
        topLevelNames: [String],
        remainingNames: Int,
        moreNamesLine: String?,
        hasHiddenControls: Bool,
        verificationWords: [String],
        joinedWordsLtr: String
    )
    case progress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        percentValue: Int,
        percentText: String,
        doneBytesText: String,
        totalBytesText: String,
        fractionText: String,
        menuBarLabel: String
    )
    case done(
        filesOk: Int,
        filesFailed: Int,
        bytes: UInt64,
        formattedBytes: String,
        isText: Bool,
        savedTo: String?,
        placed: [String],
        receivedText: String?,
        sanitizedText: String?,
        textShortened: Bool,
        textHadHiddenControls: Bool
    )
    case declined(isText: Bool, headline: String)
    case failed(headlineKey: String, headline: String, cause: String?, technicalDetail: String)
}

private struct RawSessionEventEnvelope: Decodable {
    let event: String
    let displayCode: String?
    let canonicalCode: String?
    let universalLink: String?
    let schemeLink: String?
    let shareMessage: String?
    let entries: Int?
    let totalBytes: UInt64?
    let formattedTotal: String?
    let skipped: Int?
    let isText: Bool?
    let headline: String?
    let verificationWords: [String]?
    let joinedWordsLtr: String?
    let files: Int?
    let dirs: Int?
    let formattedSize: String?
    let summaryLine: String?
    let topLevelNames: [String]?
    let remainingNames: Int?
    let moreNamesLine: String?
    let hasHiddenControls: Bool?
    let doneBytes: UInt64?
    let percentValue: Int?
    let percentText: String?
    let doneBytesText: String?
    let totalBytesText: String?
    let fractionText: String?
    let menuBarLabel: String?
    let filesOk: Int?
    let filesFailed: Int?
    let bytes: UInt64?
    let formattedBytes: String?
    let savedTo: String?
    let placed: [String]?
    let receivedText: String?
    let sanitizedText: String?
    let textShortened: Bool?
    let textHadHiddenControls: Bool?
    let headlineKey: String?
    let cause: String?
    let technicalDetail: String?

    enum CodingKeys: String, CodingKey {
        case event
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case schemeLink = "scheme_link"
        case shareMessage = "share_message"
        case entries
        case totalBytes = "total_bytes"
        case formattedTotal = "formatted_total"
        case skipped
        case isText = "is_text"
        case headline
        case verificationWords = "verification_words"
        case joinedWordsLtr = "joined_words_ltr"
        case files
        case dirs
        case formattedSize = "formatted_size"
        case summaryLine = "summary_line"
        case topLevelNames = "top_level_names"
        case remainingNames = "remaining_names"
        case moreNamesLine = "more_names_line"
        case hasHiddenControls = "has_hidden_controls"
        case doneBytes = "done_bytes"
        case percentValue = "percent_value"
        case percentText = "percent_text"
        case doneBytesText = "done_bytes_text"
        case totalBytesText = "total_bytes_text"
        case fractionText = "fraction_text"
        case menuBarLabel = "menu_bar_label"
        case filesOk = "files_ok"
        case filesFailed = "files_failed"
        case bytes
        case formattedBytes = "formatted_bytes"
        case savedTo = "saved_to"
        case placed
        case receivedText = "received_text"
        case sanitizedText = "sanitized_text"
        case textShortened = "text_shortened"
        case textHadHiddenControls = "text_had_hidden_controls"
        case headlineKey = "headline_key"
        case cause
        case technicalDetail = "technical_detail"
    }

    func toEvent() -> RustSessionEvent? {
        switch event {
        case "code_ready":
            let vDisplayCode: String = displayCode ?? ""
            let vCanonicalCode: String = canonicalCode ?? ""
            let vUniversalLink: String = universalLink ?? ""
            let vSchemeLink: String = schemeLink ?? ""
            let vShareMessage: String = shareMessage ?? ""
            let vEntries: Int = entries ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vFormattedTotal: String = formattedTotal ?? ""
            let vSkipped: Int = skipped ?? 0
            let vIsText: Bool = isText ?? false
            return RustSessionEvent.codeReady(
                displayCode: vDisplayCode,
                canonicalCode: vCanonicalCode,
                universalLink: vUniversalLink,
                schemeLink: vSchemeLink,
                shareMessage: vShareMessage,
                entries: vEntries,
                totalBytes: vTotalBytes,
                formattedTotal: vFormattedTotal,
                skipped: vSkipped,
                isText: vIsText
            )
        case "waiting":
            let vHeadline: String = headline ?? ""
            return RustSessionEvent.waiting(headline: vHeadline)
        case "connected":
            let vWords: [String] = verificationWords ?? []
            let vJoined: String = joinedWordsLtr ?? ""
            return RustSessionEvent.connected(
                verificationWords: vWords,
                joinedWordsLtr: vJoined
            )
        case "offer_ready":
            let vFiles: Int = files ?? 0
            let vDirs: Int = dirs ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vFormattedSize: String = formattedSize ?? ""
            let vIsText: Bool = isText ?? false
            let vHeadline: String = headline ?? ""
            let vSummaryLine: String = summaryLine ?? ""
            let vTopLevelNames: [String] = topLevelNames ?? []
            let vRemainingNames: Int = remainingNames ?? 0
            let vHasHiddenControls: Bool = hasHiddenControls ?? false
            let vWords: [String] = verificationWords ?? []
            let vJoined: String = joinedWordsLtr ?? ""
            return RustSessionEvent.offerReady(
                files: vFiles,
                dirs: vDirs,
                totalBytes: vTotalBytes,
                formattedSize: vFormattedSize,
                isText: vIsText,
                headline: vHeadline,
                summaryLine: vSummaryLine,
                topLevelNames: vTopLevelNames,
                remainingNames: vRemainingNames,
                moreNamesLine: moreNamesLine,
                hasHiddenControls: vHasHiddenControls,
                verificationWords: vWords,
                joinedWordsLtr: vJoined
            )
        case "progress":
            let vDoneBytes: UInt64 = doneBytes ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vPercentValue: Int = percentValue ?? 0
            let vPercentText: String = percentText ?? "0%"
            let vDoneBytesText: String = doneBytesText ?? ""
            let vTotalBytesText: String = totalBytesText ?? ""
            let vFractionText: String = fractionText ?? ""
            let vMenuBarLabel: String = menuBarLabel ?? ""
            return RustSessionEvent.progress(
                doneBytes: vDoneBytes,
                totalBytes: vTotalBytes,
                percentValue: vPercentValue,
                percentText: vPercentText,
                doneBytesText: vDoneBytesText,
                totalBytesText: vTotalBytesText,
                fractionText: vFractionText,
                menuBarLabel: vMenuBarLabel
            )
        case "done":
            let vFilesOk: Int = filesOk ?? 0
            let vFilesFailed: Int = filesFailed ?? 0
            let vBytes: UInt64 = bytes ?? 0
            let vFormattedBytes: String = formattedBytes ?? ""
            let vIsText: Bool = isText ?? false
            let vPlaced: [String] = placed ?? []
            let vTextShortened: Bool = textShortened ?? false
            let vTextHadHiddenControls: Bool = textHadHiddenControls ?? false
            return RustSessionEvent.done(
                filesOk: vFilesOk,
                filesFailed: vFilesFailed,
                bytes: vBytes,
                formattedBytes: vFormattedBytes,
                isText: vIsText,
                savedTo: savedTo,
                placed: vPlaced,
                receivedText: receivedText,
                sanitizedText: sanitizedText,
                textShortened: vTextShortened,
                textHadHiddenControls: vTextHadHiddenControls
            )
        case "declined":
            let vIsText: Bool = isText ?? false
            let vHeadline: String = headline ?? ""
            return RustSessionEvent.declined(isText: vIsText, headline: vHeadline)
        case "failed":
            let vHeadlineKey: String = headlineKey ?? "errorOther"
            let vHeadline: String = headline ?? "Transfer failed"
            let vTechnicalDetail: String = technicalDetail ?? ""
            return RustSessionEvent.failed(
                headlineKey: vHeadlineKey,
                headline: vHeadline,
                cause: cause,
                technicalDetail: vTechnicalDetail
            )
        default:
            return nil
        }
    }
}

/// Abstract bridge boundary allowing both live Rust FFI execution and
/// deterministic unit tests.
public protocol MacBridgeProtocol: Sendable {
    func versionInfo() -> RustVersionInfo?
    func loadUIBundle(preferredLanguages: [String], numericLocale: String?) -> RustUIBundle
    func handleURL(
        rawURL: String,
        activity: String,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustHandleURLResult?
    func extractClipboardCode(_ rawText: String) -> RustExtractedCode?
    func validateFinderURLs(
        _ urls: [String],
        activity: String,
        verifyOnDisk: Bool,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFinderBatch?
    func sanitizeFilename(_ rawName: String) -> RustSanitizedFilename?
    func sanitizeText(_ rawText: String) -> RustSanitizedText?
    func formatProgress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFormattedProgress?
    func startSendFiles(
        paths: [String],
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func startSendText(
        text: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func startReceive(
        codeOrLink: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func acceptOffer(handle: UInt64, destDir: String?) -> Int32
    func declineOffer(handle: UInt64) -> Int32
    func stopSession(handle: UInt64) -> Int32
    func pollEvents(handle: UInt64) -> [RustSessionEvent]
    func destroySession(handle: UInt64) -> Int32
}

/// Production Swift 6 bridge backed directly by `libtotaldrop_macos_ffi.a`.
public struct LiveRustMacBridge: MacBridgeProtocol, Sendable {
    public init() {}

    public func versionInfo() -> RustVersionInfo? {
        decodeJSON(takeRustString(totaldrop_mac_version_json()))
    }

    public func loadUIBundle(preferredLanguages: [String], numericLocale: String?) -> RustUIBundle {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = withOptionalCString(langsJSON) { langsPtr in
            withOptionalCString(numericLocale) { numPtr in
                takeRustString(totaldrop_mac_ui_bundle_json(langsPtr, numPtr))
            }
        }
        if let decoded: RustUIBundle = decodeJSON(raw) {
            return decoded
        }
        return RustUIBundle(locale: "en", isRtl: false, isDraft: false, strings: [:])
    }

    public func handleURL(
        rawURL: String,
        activity: String,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustHandleURLResult? {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = rawURL.withCString { urlPtr in
            activity.withCString { actPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        takeRustString(
                            totaldrop_mac_handle_url_json(urlPtr, actPtr, langsPtr, numPtr)
                        )
                    }
                }
            }
        }
        return decodeJSON(raw)
    }

    public func extractClipboardCode(_ rawText: String) -> RustExtractedCode? {
        let raw = rawText.withCString { ptr in
            takeRustString(totaldrop_mac_extract_clipboard_code_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func validateFinderURLs(
        _ urls: [String],
        activity: String,
        verifyOnDisk: Bool,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFinderBatch? {
        guard let urlsJSON = encodeJSONString(urls) else { return nil }
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = urlsJSON.withCString { urlsPtr in
            activity.withCString { actPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        takeRustString(
                            totaldrop_mac_validate_finder_urls_json(
                                urlsPtr,
                                actPtr,
                                verifyOnDisk,
                                langsPtr,
                                numPtr
                            )
                        )
                    }
                }
            }
        }
        return decodeJSON(raw)
    }

    public func sanitizeFilename(_ rawName: String) -> RustSanitizedFilename? {
        let raw = rawName.withCString { ptr in
            takeRustString(totaldrop_mac_sanitize_filename_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func sanitizeText(_ rawText: String) -> RustSanitizedText? {
        let raw = rawText.withCString { ptr in
            takeRustString(totaldrop_mac_sanitize_text_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func formatProgress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustFormattedProgress? {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = langsJSON.withCString { langsPtr in
            withOptionalCString(numericLocale) { numPtr in
                takeRustString(
                    totaldrop_mac_format_progress_json(doneBytes, totalBytes, langsPtr, numPtr)
                )
            }
        }
        return decodeJSON(raw)
    }

    public func startSendFiles(
        paths: [String],
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        guard let pathsJSON = encodeJSONString(paths) else { return 0 }
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return pathsJSON.withCString { pathsPtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mac_session_start_send_files(pathsPtr, cfgPtr, langsPtr, numPtr)
                    }
                }
            }
        }
    }

    public func startSendText(
        text: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return text.withCString { textPtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mac_session_start_send_text(textPtr, cfgPtr, langsPtr, numPtr)
                    }
                }
            }
        }
    }

    public func startReceive(
        codeOrLink: String,
        config: RustTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return codeOrLink.withCString { codePtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mac_session_start_receive(codePtr, cfgPtr, langsPtr, numPtr)
                    }
                }
            }
        }
    }

    public func acceptOffer(handle: UInt64, destDir: String?) -> Int32 {
        withOptionalCString(destDir) { dirPtr in
            totaldrop_mac_session_accept_offer(handle, dirPtr)
        }
    }

    public func declineOffer(handle: UInt64) -> Int32 {
        totaldrop_mac_session_decline_offer(handle)
    }

    public func stopSession(handle: UInt64) -> Int32 {
        totaldrop_mac_session_stop(handle)
    }

    public func pollEvents(handle: UInt64) -> [RustSessionEvent] {
        guard let ndjson = takeRustString(totaldrop_mac_session_poll_events_ndjson(handle)),
              !ndjson.isEmpty
        else {
            return []
        }
        let decoder = JSONDecoder()
        var events: [RustSessionEvent] = []
        for line in ndjson.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let raw = try? decoder.decode(RawSessionEventEnvelope.self, from: data),
               let ev = raw.toEvent()
            {
                events.append(ev)
            }
        }
        return events
    }

    public func destroySession(handle: UInt64) -> Int32 {
        totaldrop_mac_session_destroy(handle)
    }

    private func takeRustString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { totaldrop_mac_string_free(ptr) }
        return String(cString: ptr)
    }

    private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let value else {
            return body(nil)
        }
        return value.withCString { ptr in
            body(ptr)
        }
    }

    private func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
