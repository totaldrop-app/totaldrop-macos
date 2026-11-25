// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// Native macOS SwiftUI view for picking files or text, generating a real transfer code
/// via `totaldrop-macos-ffi`, sharing Universal Links / QR codes, verifying the 4 words,
/// and tracking live encrypted transfer progress.
public struct SendView: View {
    @Bindable var model: MacAppModel
    @State private var isDropTargeted = false
    @State private var isFileImporterPresented = false

    public init(model: MacAppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow

                switch model.phase {
                case .preparing:
                    preparingCard
                case .waitingForReceiver(let code, let universalLink, let shareMessage):
                    waitingCard(code: code, universalLink: universalLink, shareMessage: shareMessage)
                case .transferring(_, _, let percent, let fractionText, _, let words):
                    transferringCard(percent: percent, fractionText: fractionText, words: words)
                case .completed(let summaryText, _, _, _, _, _):
                    completedCard(summaryText: summaryText)
                case .failed(let headline, let cause, let detail):
                    failedCard(headline: headline, cause: cause, detail: detail)
                default:
                    selectionCard
                }
            }
            .padding(24)
        }
        .dropDestination(for: URL.self) { items, _ in
            model.addSharedFileURLs(items, verifyOnDisk: true)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.addSharedFileURLs(urls, verifyOnDisk: true)
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    model.sendTextMode
                        ? model.t("sendText", fallback: "Send text")
                        : model.t("sendTitle", fallback: "Send files")
                )
                .font(.title2.weight(.semibold))
                Text(model.t("sameNetworkNote", fallback: "End-to-end encrypted with CPace, Noise XXpsk3, ML-KEM-768, and BLAKE3."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Mode", selection: $model.sendTextMode) {
                Text(model.t("homeSendTitle", fallback: "Files")).tag(false)
                Text(model.t("sendText", fallback: "Text")).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(model.phase.isBusy)
        }
    }

    private var preparingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(model.t("sendPreparing", fallback: "Preparing your files…"))
                .font(.headline)
            Spacer()
            Button(model.t("cancel", fallback: "Cancel"), role: .destructive) {
                model.stopActiveTransfer()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.sendTextMode {
                TextEditor(text: $model.textPayload)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                dropZone
                if !model.selectedFiles.isEmpty {
                    fileList
                }
            }

            Toggle(isOn: $model.strongerCode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.t("sendStrongCode", fallback: "Stronger code"))
                    Text(model.t("sendStrongCodeHint", fallback: "Three words instead of two: much harder to guess"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if !model.sendTextMode {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(model.t("sendAddFiles", fallback: "Add files"), systemImage: "plus")
                    }
                }
                Spacer()
                Button {
                    model.beginSend()
                } label: {
                    Text(model.t("sendCreateCode", fallback: "Create code"))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.sendTextMode ? model.textPayload.isEmpty : model.selectedFiles.isEmpty)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(
                model.selectedFiles.isEmpty
                    ? model.t("sendEmpty", fallback: "Nothing selected yet")
                    : "\(model.selectedFiles.count)"
            )
            .font(.headline)
            Text(model.t("sendDropHint", fallback: "You can also drag files onto this window."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6])
                        )
                )
        )
    }

    private var fileList: some View {
        VStack(spacing: 6) {
            ForEach(model.selectedFiles, id: \.self) { url in
                let safeName = model.displaySafeFilename(url.lastPathComponent.precomposedStringWithCanonicalMapping)
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(safeName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        model.selectedFiles.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(model.t("sendRemove", fallback: "Remove")) \(safeName)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func waitingCard(code: String, universalLink: String, shareMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("sendYourCode", fallback: "Your code"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)

                    Text(model.t("sendCodeHint", fallback: "On the other device, open TotalDrop, choose Receive, and enter this code."))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            model.transientBanner = model.t("sendCopied", fallback: "Code copied")
                        } label: {
                            Label(model.t("sendCopy", fallback: "Copy"), systemImage: "doc.on.doc")
                        }

                        if let shareURL = URL(string: universalLink) {
                            ShareLink(
                                item: shareURL,
                                message: Text(shareMessage.isEmpty ? code : shareMessage)
                            ) {
                                Label(model.t("sendShare", fallback: "Share"), systemImage: "square.and.arrow.up")
                            }
                        }

                        Button(model.t("cancel", fallback: "Cancel"), role: .destructive) {
                            model.stopActiveTransfer()
                        }
                    }
                }
                Spacer()
                if let qrImage = Self.makeQRCodeImage(from: universalLink) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("QR \(code)")
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.t("sendWaiting", fallback: "Waiting for the receiver…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transferringCard(percent: Int, fractionText: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !words.isEmpty {
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
            }

            ProgressView(value: Double(percent), total: 100.0) {
                HStack {
                    Text(model.t("sendSending", fallback: "Sending"))
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

    private func completedCard(summaryText: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.t("sendDone", fallback: "Sent and verified"), systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            Text(summaryText)
                .foregroundStyle(.secondary)
            Button(model.t("done", fallback: "Done")) {
                model.selectedFiles.removeAll()
                model.textPayload = ""
                model.resetCompletedOrFailed()
            }
            .buttonStyle(.borderedProminent)
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

    static func makeQRCodeImage(from payload: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
