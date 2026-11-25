// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Native macOS SwiftUI view for entering or pasting a transfer code, scanning a QR image,
/// reviewing the offer and verification words, accepting or declining through Rust FFI,
/// and displaying received text or saving verified files to `~/Downloads/TotalDrop`.
public struct ReceiveView: View {
    @Bindable var model: MacAppModel
    @State private var isQRImagePickerPresented = false

    public init(model: MacAppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("receiveTitle", fallback: "Receive files"))
                        .font(.title2.weight(.semibold))
                    Text(model.t("receiveCodeHelp", fallback: "Ask the sender for their code."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                switch model.phase {
                case .connecting(let code):
                    connectingCard(code: code)
                case .offerPending(
                    _,
                    _,
                    _,
                    _,
                    _,
                    let headline,
                    let summaryLine,
                    let words,
                    let names,
                    let moreNamesLine,
                    let hasHiddenControls
                ):
                    offerCard(
                        headline: headline,
                        summaryLine: summaryLine,
                        words: words,
                        names: names,
                        moreNamesLine: moreNamesLine,
                        hasHiddenControls: hasHiddenControls
                    )
                case .transferring(_, _, let percent, let fractionText, _, let words):
                    receivingCard(percent: percent, fractionText: fractionText, words: words)
                case .completed(
                    let summaryText,
                    let savedFolder,
                    let receivedText,
                    let sanitizedText,
                    let textShortened,
                    let textHadHiddenControls
                ):
                    completedCard(
                        summaryText: summaryText,
                        savedFolder: savedFolder,
                        receivedText: receivedText,
                        sanitizedText: sanitizedText,
                        textShortened: textShortened,
                        textHadHiddenControls: textHadHiddenControls
                    )
                case .failed(let headline, let cause, let detail):
                    failedCard(headline: headline, cause: cause, detail: detail)
                default:
                    codeEntryCard
                }
            }
            .padding(24)
        }
        .fileImporter(
            isPresented: $isQRImagePickerPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let imageURL = urls.first {
                readQRCode(from: imageURL)
            }
        }
    }

    private var codeEntryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("receiveCodeLabel", fallback: "Code"))
                .font(.headline)

            HStack(spacing: 10) {
                TextField(
                    model.t("receiveCodeHint", fallback: "7-harbor-rocket"),
                    text: $model.receiveInputCode
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    model.startReceiveConnection()
                }

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        if let extracted = model.extractCodeFromClipboardText(pasted) {
                            model.receiveInputCode = extracted
                        } else {
                            model.receiveInputCode = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                } label: {
                    Label(model.t("receivePaste", fallback: "Paste"), systemImage: "doc.on.clipboard")
                }

                Button {
                    isQRImagePickerPresented = true
                } label: {
                    Label(model.t("receiveFromImage", fallback: "Read QR from image"), systemImage: "qrcode.viewfinder")
                }
            }

            HStack {
                Text(model.destinationFolder.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.startReceiveConnection()
                } label: {
                    Text(model.t("receiveConnect", fallback: "Connect"))
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.receiveInputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func connectingCard(code: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t("receiveConnecting", fallback: "Connecting securely…"))
                    .font(.headline)
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.t("cancel", fallback: "Cancel"), role: .destructive) {
                model.stopActiveTransfer()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func offerCard(
        headline: String,
        summaryLine: String,
        words: [String],
        names: [String],
        moreNamesLine: String?,
        hasHiddenControls: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headline)
                .font(.title3.weight(.semibold))

            Text(summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("verificationTitle", fallback: "Verification words"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(words.joined(separator: " · "))
                    .font(.headline.monospaced())
                Text(model.t("verificationHint", fallback: "The other person sees the same four words. If they differ, stop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if hasHiddenControls {
                Label(
                    model.t("receiveTextHidden", fallback: "Hidden direction or control characters in names are shown as <U+…>."),
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !names.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(names.prefix(10), id: \.self) { item in
                        Text("• \(item)")
                            .font(.callout.monospaced())
                    }
                    if let more = moreNamesLine {
                        Text(more)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button(model.t("receiveDecline", fallback: "Decline"), role: .destructive) {
                    model.declinePendingOffer()
                }
                Spacer()
                Button(model.t("receiveAccept", fallback: "Accept")) {
                    model.acceptPendingOffer()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func receivingCard(percent: Int, fractionText: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !words.isEmpty {
                Text(words.joined(separator: " · "))
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(percent), total: 100.0) {
                HStack {
                    Text(model.t("receiveReceiving", fallback: "Receiving"))
                    Spacer()
                    Text(fractionText.isEmpty ? "\(percent)%" : "\(percent)% · \(fractionText)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button(model.t("stop", fallback: "Stop"), role: .destructive) {
                model.stopActiveTransfer()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func completedCard(
        summaryText: String,
        savedFolder: URL?,
        receivedText: String?,
        sanitizedText: String?,
        textShortened: Bool,
        textHadHiddenControls: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                receivedText != nil
                    ? model.t("receiveTextDone", fallback: "Text received and verified")
                    : model.t("receiveDone", fallback: "Received and verified"),
                systemImage: "checkmark.seal.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(.green)

            Text(summaryText)
                .foregroundStyle(.secondary)

            if let display = sanitizedText ?? receivedText {
                if textHadHiddenControls {
                    Label(
                        model.t("receiveTextHidden", fallback: "The text holds hidden characters, shown as U+…."),
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if textShortened {
                    Text(model.t("receiveTextShortened", fallback: "Only the beginning of the text is shown. Copy text copies all of it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(display)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if let rawText = receivedText {
                    Button(model.t("copyText", fallback: "Copy text")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rawText, forType: .string)
                        model.transientBanner = model.t("textCopied", fallback: "Text copied")
                    }
                }
                if let folder = savedFolder {
                    Button(model.t("openFolder", fallback: "Open folder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Button(model.t("done", fallback: "Done")) {
                    model.receiveInputCode = ""
                    model.resetCompletedOrFailed()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func failedCard(headline: String, cause: String?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            if let cause {
                Text(cause)
                    .font(.callout)
            }
            DisclosureGroup(model.t("moreInfo", fallback: "Details")) {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button(model.t("tryAgain", fallback: "Try again")) {
                model.resetCompletedOrFailed()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func readQRCode(from imageURL: URL) {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        do {
            try handler.perform([request])
            guard let payload = request.results?.compactMap(\.payloadStringValue).first else {
                model.transientBanner = model.t("receiveQrNotFound", fallback: "There is no TotalDrop code in that image.")
                return
            }
            if let code = model.extractCodeFromClipboardText(payload) {
                model.receiveInputCode = code
                model.startReceiveConnection()
            } else {
                model.transientBanner = model.t("receiveQrNotFound", fallback: "There is no TotalDrop code in that image.")
            }
        } catch {
            model.transientBanner = model.t("receiveQrNotFound", fallback: "There is no TotalDrop code in that image.")
        }
    }
}
