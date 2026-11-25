// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Thin audited C ABI FFI boundary for TotalDrop on macOS (ADR 0009).
//!
//! This crate isolates all `extern "C"` FFI exports into a minimal
//! `staticlib` + `rlib` boundary (`libtotaldrop_macos_ffi.a`) so that
//! `totaldrop-crypto`, `totaldrop-proto`, `totaldrop-core`, `totaldrop-l10n`,
//! and `totaldrop-macos-bridge` remain strictly `#![forbid(unsafe_code)]`.
//!
//! # Memory Ownership & Safety Invariants
//!
//! - Every function returning `*mut c_char` allocates a NUL-terminated UTF-8
//!   JSON or NDJSON buffer via Rust's allocator. Callers MUST release every
//!   non-null pointer via [`totaldrop_mac_string_free`].
//! - Every `extern "C"` entry point wraps its body in
//!   [`std::panic::catch_unwind`] so a Rust panic can never unwind across the
//!   C ABI boundary.
//! - Interior NUL bytes are stripped before constructing [`CString`] buffers so
//!   serialization never fails or truncates mid-payload.

mod sessions;

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::ptr;

use serde::Serialize;
use totaldrop_macos_bridge::{
    CUSTOM_SCHEME_PREFIX, FinderSkipReason, MacLinkOutcome, MacLocalizationBundle,
    MacTransferConfig, UNIVERSAL_LINK_PREFIX, WindowActivity, format_selection_summary,
    format_transfer_progress, handle_macos_open_url, validate_finder_file_urls,
};
use totaldrop_proto::TransferCode;

use crate::sessions::FfiTransferConfig;

/// Independent SemVer of the TotalDrop for macOS application (`CFBundleShortVersionString`).
pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Version of the synced pure-Rust TotalDrop core workspace crates.
pub const CORE_VERSION: &str = "0.2.0-beta.5";

/// Monotonic numeric Apple bundle build version (`CFBundleVersion`).
pub const BUNDLE_VERSION: &str = "6";

/// Standardized `i32` status code: operation succeeded.
pub const FFI_OK: i32 = 0;

/// Standardized `i32` status code: required pointer argument was null.
pub const FFI_ERR_NULL_POINTER: i32 = -1;

/// Standardized `i32` status code: C string argument was not valid UTF-8.
pub const FFI_ERR_INVALID_UTF8: i32 = -2;

/// Standardized `i32` status code: session handle was `0`, unknown, or destroyed.
pub const FFI_ERR_INVALID_HANDLE: i32 = -3;

/// Standardized `i32` status code: operation invalid for current session state.
pub const FFI_ERR_INVALID_STATE: i32 = -4;

/// Standardized `i32` status code: argument failed domain validation.
pub const FFI_ERR_INVALID_ARG: i32 = -5;

/// Standardized `i32` status code: internal panic or poisoned lock caught at boundary.
pub const FFI_ERR_INTERNAL: i32 = -99;

const FALLBACK_PANIC_JSON: &str = r#"{"ok":false,"error":{"kind":"internal","l10n_key":"errorOther","message":"internal FFI panic"}}"#;
const FALLBACK_SERIALIZE_JSON: &str = r#"{"ok":false,"error":{"kind":"internal","l10n_key":"errorOther","message":"internal JSON serialization failure"}}"#;

#[derive(Serialize)]
struct VersionInfo {
    ok: bool,
    app_version: &'static str,
    core_version: &'static str,
    bundle_version: &'static str,
}

#[derive(Serialize)]
struct FfiErrorEnvelope<'a> {
    ok: bool,
    error: FfiErrorBody<'a>,
}

#[derive(Serialize)]
struct FfiErrorBody<'a> {
    kind: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    l10n_key: Option<&'a str>,
    message: String,
}

#[derive(Serialize)]
struct HandleUrlDto {
    ok: bool,
    outcome: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    canonical_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    universal_link: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize)]
struct ExtractedCodeDto {
    ok: bool,
    display_code: String,
    canonical_code: String,
    universal_link: String,
    scheme_link: String,
}

#[derive(Serialize)]
struct FinderItemDto {
    path: String,
    normalized_name: String,
    collision_key: String,
    is_directory: bool,
    byte_size: u64,
}

#[derive(Serialize)]
struct FinderSkippedDto {
    raw_url: String,
    reason: &'static str,
}

#[derive(Serialize)]
struct FinderBatchDto {
    ok: bool,
    busy: bool,
    accepted: Vec<FinderItemDto>,
    skipped: Vec<FinderSkippedDto>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notice: Option<String>,
}

#[derive(Serialize)]
struct SanitizedFilenameDto {
    ok: bool,
    sanitized: String,
    has_hidden_controls: bool,
}

#[derive(Serialize)]
struct SanitizedTextDto {
    ok: bool,
    display_text: String,
    shortened: bool,
    had_hidden_controls: bool,
}

#[derive(Serialize)]
struct FormattedProgressDto {
    ok: bool,
    percent_value: u8,
    percent_text: String,
    done_bytes_text: String,
    total_bytes_text: String,
    fraction_text: String,
    menu_bar_label: String,
}

#[derive(Serialize)]
struct FormattedSelectionDto {
    ok: bool,
    summary: String,
}

fn into_c_string_ptr(mut text: String) -> *mut c_char {
    if text.as_bytes().contains(&0) {
        text.retain(|ch| ch != '\0');
    }
    match CString::new(text) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn serialize_or_error<T: Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(json) => into_c_string_ptr(json),
        Err(_) => into_c_string_ptr(FALLBACK_SERIALIZE_JSON.to_owned()),
    }
}

fn error_json(kind: &str, l10n_key: Option<&str>, message: impl Into<String>) -> *mut c_char {
    let raw = message.into();
    let sanitized = totaldrop_l10n::reveal_controls(&raw);
    let envelope = FfiErrorEnvelope {
        ok: false,
        error: FfiErrorBody {
            kind,
            l10n_key,
            message: sanitized,
        },
    };
    serialize_or_error(&envelope)
}

fn guard_ffi_json<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> *mut c_char,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(ptr) => ptr,
        Err(_) => into_c_string_ptr(FALLBACK_PANIC_JSON.to_owned()),
    }
}

fn guard_ffi_u64<F>(f: F) -> u64
where
    F: FnOnce() -> u64,
{
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(0)
}

fn guard_ffi_i32<F>(f: F) -> i32
where
    F: FnOnce() -> i32,
{
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(FFI_ERR_INTERNAL)
}

/// Reads an optional NUL-terminated UTF-8 C string pointer.
///
/// # Safety
///
/// If `ptr` is non-null, it must point to a valid, readable NUL-terminated C
/// string that remains alive for `'a`.
unsafe fn read_optional_c_str<'a>(ptr: *const c_char) -> Result<Option<&'a str>, &'static str> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: Caller guarantees non-null `ptr` points to a readable
    // NUL-terminated C string valid for lifetime `'a`.
    let cstr = unsafe { CStr::from_ptr(ptr) };
    match cstr.to_str() {
        Ok(valid) => Ok(Some(valid)),
        Err(_) => Err("input string is not valid UTF-8"),
    }
}

fn parse_preferred_languages(raw: Option<&str>) -> Vec<String> {
    let Some(text) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return vec!["en".to_owned()];
    };
    if text.starts_with('[')
        && let Ok(parsed) = serde_json::from_str::<Vec<String>>(text)
    {
        let filtered: Vec<String> = parsed
            .into_iter()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect();
        if !filtered.is_empty() {
            return filtered;
        }
    }
    let split: Vec<String> = text
        .split([',', ';'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if split.is_empty() {
        vec!["en".to_owned()]
    } else {
        split
    }
}

fn build_bundle(
    preferred_langs: Option<&str>,
    numeric_locale: Option<&str>,
) -> MacLocalizationBundle {
    let langs = parse_preferred_languages(preferred_langs);
    let numeric = numeric_locale.map(str::trim).filter(|s| !s.is_empty());
    MacLocalizationBundle::from_macos_preferences(&langs, numeric)
}

fn parse_activity(raw: Option<&str>) -> WindowActivity {
    match raw.map(str::trim) {
        Some("transfer_running" | "transferRunning") => WindowActivity::TransferRunning,
        Some("offer_pending" | "offerPending") => WindowActivity::OfferPending,
        Some("showing_received_text" | "showingReceivedText") => {
            WindowActivity::ShowingReceivedText
        }
        _ => WindowActivity::Idle,
    }
}

fn skip_reason_str(reason: &FinderSkipReason) -> &'static str {
    match reason {
        FinderSkipReason::NotLocalFileUrl => "not_local_file_url",
        FinderSkipReason::MissingFileName => "missing_file_name",
        FinderSkipReason::UnsafeFileName => "unsafe_file_name",
        FinderSkipReason::CaseCollision => "case_collision",
        FinderSkipReason::TooManyEntries => "too_many_entries",
        FinderSkipReason::UnreadableOnDisk => "unreadable_on_disk",
    }
}

fn parse_config(raw: Option<&str>) -> Result<MacTransferConfig, &'static str> {
    let Some(text) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(MacTransferConfig::default());
    };
    let dto: FfiTransferConfig =
        serde_json::from_str(text).map_err(|_| "invalid transfer configuration JSON")?;
    Ok(dto.into_mac_config())
}

/// Releases a NUL-terminated UTF-8 string previously allocated by this crate.
///
/// Passing `NULL` is a safe no-op.
///
/// # Safety
///
/// `ptr` must either be null or be a pointer previously returned by a
/// `totaldrop_mac_*` function that has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Caller guarantees `ptr` came from `CString::into_raw` in this
        // crate and has not been freed before.
        let _ = unsafe { CString::from_raw(ptr) };
    }));
}

/// Returns JSON containing `app_version`, `core_version`, and `bundle_version`.
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mac_version_json() -> *mut c_char {
    guard_ffi_json(|| {
        let info = VersionInfo {
            ok: true,
            app_version: APP_VERSION,
            core_version: CORE_VERSION,
            bundle_version: BUNDLE_VERSION,
        };
        serialize_or_error(&info)
    })
}

/// Exports the negotiated 35-language macOS localization bundle JSON
/// (`locale`, `isRtl`, `isDraft`, `strings`).
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string for the
/// duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_ui_bundle_json(
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let bundle = build_bundle(langs, numeric);
        into_c_string_ptr(bundle.export_swiftui_json())
    })
}

/// Routes an incoming `totaldrop://r/...` or `https://totaldrop.app/r#...` URL
/// through [`handle_macos_open_url`].
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string for the
/// duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_handle_url_json(
    raw_url: *const c_char,
    activity: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let url_opt = match unsafe { read_optional_c_str(raw_url) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorInvalidCode"), msg),
        };
        let Some(url) = url_opt else {
            return error_json(
                "null_pointer",
                Some("errorInvalidCode"),
                "raw_url must not be null",
            );
        };
        // SAFETY: Forwarded from this function's safety contract.
        let act = match unsafe { read_optional_c_str(activity) } {
            Ok(v) => parse_activity(v),
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let bundle = build_bundle(langs, numeric);
        let dto = match handle_macos_open_url(url, act, &bundle) {
            MacLinkOutcome::OpenReceive {
                display_code,
                canonical_code,
                universal_link,
            } => HandleUrlDto {
                ok: true,
                outcome: "open_receive",
                display_code: Some(display_code),
                canonical_code: Some(canonical_code),
                universal_link: Some(universal_link),
                message: None,
            },
            MacLinkOutcome::Busy { message } => HandleUrlDto {
                ok: true,
                outcome: "busy",
                display_code: None,
                canonical_code: None,
                universal_link: None,
                message: Some(message),
            },
            MacLinkOutcome::Rejected => HandleUrlDto {
                ok: false,
                outcome: "rejected",
                display_code: None,
                canonical_code: None,
                universal_link: None,
                message: Some(bundle.text("errorInvalidCode")),
            },
        };
        serialize_or_error(&dto)
    })
}

/// Extracts a normalized TotalDrop transfer code from clipboard or QR text.
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// `raw_text` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_extract_clipboard_code_json(
    raw_text: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let text_opt = match unsafe { read_optional_c_str(raw_text) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorInvalidCode"), msg),
        };
        let Some(text) = text_opt else {
            return error_json(
                "null_pointer",
                Some("errorInvalidCode"),
                "raw_text must not be null",
            );
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return error_json(
                "empty",
                Some("receiveCodeInvalid"),
                "clipboard text is empty",
            );
        }
        let found = TransferCode::from_link(trimmed)
            .or_else(|| TransferCode::parse(trimmed).ok())
            .or_else(|| TransferCode::find(trimmed));
        let Some(code) = found else {
            return error_json(
                "no_code_found",
                Some("errorInvalidCode"),
                "no valid TotalDrop transfer code found",
            );
        };
        let display_code = code.to_english();
        let dto = ExtractedCodeDto {
            ok: true,
            canonical_code: code.canonical(),
            universal_link: format!("{UNIVERSAL_LINK_PREFIX}{display_code}"),
            scheme_link: format!("{CUSTOM_SCHEME_PREFIX}{display_code}"),
            display_code,
        };
        serialize_or_error(&dto)
    })
}

/// Validates a JSON array of `file://` URLs handed over by Finder or
/// drag-and-drop through [`validate_finder_file_urls`].
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_validate_finder_urls_json(
    urls_json: *const c_char,
    activity: *const c_char,
    verify_on_disk: bool,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let urls_opt = match unsafe { read_optional_c_str(urls_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(urls_str) = urls_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "urls_json must not be null",
            );
        };
        let raw_urls: Vec<String> = match serde_json::from_str(urls_str) {
            Ok(list) => list,
            Err(_) => {
                return error_json(
                    "invalid_json",
                    Some("errorOther"),
                    "urls_json must be a JSON array of strings",
                );
            }
        };
        // SAFETY: Forwarded from this function's safety contract.
        let act = match unsafe { read_optional_c_str(activity) } {
            Ok(v) => parse_activity(v),
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let bundle = build_bundle(langs, numeric);
        let batch = validate_finder_file_urls(&raw_urls, act, verify_on_disk, &bundle);
        let dto = FinderBatchDto {
            ok: true,
            busy: batch.busy,
            accepted: batch
                .accepted
                .into_iter()
                .map(|item| FinderItemDto {
                    path: item.path.to_string_lossy().into_owned(),
                    normalized_name: item.normalized_name,
                    collision_key: item.collision_key,
                    is_directory: item.is_directory,
                    byte_size: item.byte_size,
                })
                .collect(),
            skipped: batch
                .skipped
                .into_iter()
                .map(|(raw_url, reason)| FinderSkippedDto {
                    raw_url: totaldrop_l10n::reveal_controls(&raw_url),
                    reason: skip_reason_str(&reason),
                })
                .collect(),
            notice: batch.notice,
        };
        serialize_or_error(&dto)
    })
}

/// Sanitizes a peer-supplied filename via `totaldrop_l10n::reveal_controls`.
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// `raw_name` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_sanitize_filename_json(
    raw_name: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let name_opt = match unsafe { read_optional_c_str(raw_name) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(name) = name_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "raw_name must not be null",
            );
        };
        let sanitized = totaldrop_l10n::reveal_controls(name);
        let has_hidden_controls = sanitized != name;
        let dto = SanitizedFilenameDto {
            ok: true,
            sanitized,
            has_hidden_controls,
        };
        serialize_or_error(&dto)
    })
}

/// Sanitizes received text for display via
/// [`MacLocalizationBundle::sanitize_received_text`].
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// `raw_text` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_sanitize_text_json(raw_text: *const c_char) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let text_opt = match unsafe { read_optional_c_str(raw_text) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(text) = text_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "raw_text must not be null",
            );
        };
        let bundle = build_bundle(None, None);
        let res = bundle.sanitize_received_text(text);
        let dto = SanitizedTextDto {
            ok: true,
            display_text: res.display_text,
            shortened: res.shortened,
            had_hidden_controls: res.had_hidden_controls,
        };
        serialize_or_error(&dto)
    })
}

/// Formats regional transfer progress strings and compact `MenuBarExtra` text.
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_format_progress_json(
    done_bytes: u64,
    total_bytes: u64,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let bundle = build_bundle(langs, numeric);
        let prog = format_transfer_progress(done_bytes, total_bytes, &bundle);
        let dto = FormattedProgressDto {
            ok: true,
            percent_value: prog.percent_value,
            percent_text: prog.percent_text,
            done_bytes_text: prog.done_bytes_text,
            total_bytes_text: prog.total_bytes_text,
            fraction_text: prog.fraction_text,
            menu_bar_label: prog.menu_bar_label,
        };
        serialize_or_error(&dto)
    })
}

/// Formats localized item count and byte total (`itemsAndSize`).
///
/// The returned pointer must be freed with [`totaldrop_mac_string_free`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_format_selection_json(
    item_count: u64,
    total_bytes: u64,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let bundle = build_bundle(langs, numeric);
        let count_usize = usize::try_from(item_count).unwrap_or(usize::MAX);
        let dto = FormattedSelectionDto {
            ok: true,
            summary: format_selection_summary(count_usize, total_bytes, &bundle),
        };
        serialize_or_error(&dto)
    })
}

/// Starts an asynchronous file/folder send session.
///
/// Returns a monotonic non-zero handle, or `0` on invalid input.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_session_start_send_files(
    paths_json: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(paths_str)) = (unsafe { read_optional_c_str(paths_json) }) else {
            return 0;
        };
        let Ok(raw_paths) = serde_json::from_str::<Vec<String>>(paths_str) else {
            return 0;
        };
        let paths: Vec<PathBuf> = raw_paths
            .into_iter()
            .filter(|p| !p.trim().is_empty())
            .map(PathBuf::from)
            .collect();
        if paths.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let bundle = build_bundle(langs, numeric);
        sessions::start_send_files(paths, config, bundle)
    })
}

/// Starts an asynchronous inline text send session.
///
/// Returns a monotonic non-zero handle, or `0` on invalid input.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_session_start_send_text(
    text: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(raw_text)) = (unsafe { read_optional_c_str(text) }) else {
            return 0;
        };
        if raw_text.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let bundle = build_bundle(langs, numeric);
        sessions::start_send_text(raw_text.to_owned(), config, bundle)
    })
}

/// Starts an asynchronous receive session for `code_or_link`.
///
/// Returns a monotonic non-zero handle, or `0` on invalid input.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_session_start_receive(
    code_or_link: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(raw_code)) = (unsafe { read_optional_c_str(code_or_link) }) else {
            return 0;
        };
        let trimmed = raw_code.trim();
        if trimmed.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let bundle = build_bundle(langs, numeric);
        sessions::start_receive(trimmed.to_owned(), config, bundle)
    })
}

/// Accepts a pending incoming offer for `handle`.
///
/// # Safety
///
/// `dest_dir` must either be null (for text offers) or point to a valid
/// NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mac_session_accept_offer(
    handle: u64,
    dest_dir: *const c_char,
) -> i32 {
    guard_ffi_i32(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let dir_opt = match unsafe { read_optional_c_str(dest_dir) } {
            Ok(v) => v
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };
        sessions::accept_offer(handle, dir_opt)
    })
}

/// Declines a pending incoming offer for `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mac_session_decline_offer(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::decline_offer(handle))
}

/// Signals cancellation for an active transfer session `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mac_session_stop(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::stop_session(handle))
}

/// Drains pending NDJSON event lines for `handle`.
///
/// Returns an empty string when no new events are queued, or an error JSON line
/// if `handle` is unknown. Caller must free with [`totaldrop_mac_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mac_session_poll_events_ndjson(handle: u64) -> *mut c_char {
    guard_ffi_json(|| match sessions::poll_events_ndjson(handle) {
        Some(ndjson) => into_c_string_ptr(ndjson),
        None => error_json(
            "invalid_handle",
            Some("errorOther"),
            "unknown session handle",
        ),
    })
}

/// Cancels (if active) and destroys `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mac_session_destroy(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::destroy_session(handle))
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        clippy::undocumented_unsafe_blocks
    )]

    use std::collections::HashMap;
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use futures_util::{SinkExt, StreamExt};
    use serde_json::{Value, json};
    use tokio::net::TcpListener;
    use tokio::sync::{Mutex, mpsc};
    use tokio_tungstenite::tungstenite::Message;

    use super::*;

    fn take_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "FFI returned null string pointer");
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { totaldrop_mac_string_free(ptr) };
        text
    }

    fn take_json(ptr: *mut c_char) -> Value {
        let raw = take_string(ptr);
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("invalid JSON {raw:?}: {e}"))
    }

    fn cstr(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn version_and_string_free_contract() {
        unsafe { totaldrop_mac_string_free(ptr::null_mut()) };
        let v = take_json(totaldrop_mac_version_json());
        assert_eq!(v["ok"], true);
        assert_eq!(v["app_version"], APP_VERSION);
        assert_eq!(v["core_version"], CORE_VERSION);
        assert_eq!(v["bundle_version"], BUNDLE_VERSION);
        assert!(
            BUNDLE_VERSION.chars().all(|c| c.is_ascii_digit()),
            "CFBundleVersion must be strictly numeric"
        );
    }

    #[test]
    fn ui_bundle_negotiates_english_turkish_and_arabic_rtl() {
        let en = take_json(unsafe {
            totaldrop_mac_ui_bundle_json(cstr(r#"["en-US"]"#).as_ptr(), cstr("en_US").as_ptr())
        });
        assert_eq!(en["locale"], "en");
        assert_eq!(en["isRtl"], false);
        assert!(en["strings"]["verificationTitle"].is_string());

        let tr = take_json(unsafe {
            totaldrop_mac_ui_bundle_json(cstr("tr-TR,en-US").as_ptr(), cstr("tr_TR").as_ptr())
        });
        assert_eq!(tr["locale"], "tr");
        assert_eq!(tr["isRtl"], false);

        let ar = take_json(unsafe {
            totaldrop_mac_ui_bundle_json(cstr(r#"["ar-SA"]"#).as_ptr(), cstr("ar_SA").as_ptr())
        });
        assert_eq!(ar["locale"], "ar");
        assert_eq!(ar["isRtl"], true);
    }

    #[test]
    fn handle_url_and_clipboard_code_extraction() {
        let ok = take_json(unsafe {
            totaldrop_mac_handle_url_json(
                cstr("https://totaldrop.app/r#7-harbor-rocket").as_ptr(),
                cstr("idle").as_ptr(),
                ptr::null(),
                ptr::null(),
            )
        });
        assert_eq!(ok["ok"], true);
        assert_eq!(ok["outcome"], "open_receive");
        assert_eq!(ok["display_code"], "7-harbor-rocket");

        let busy = take_json(unsafe {
            totaldrop_mac_handle_url_json(
                cstr("totaldrop://r/7-harbor-rocket").as_ptr(),
                cstr("transfer_running").as_ptr(),
                cstr("en-US").as_ptr(),
                ptr::null(),
            )
        });
        assert_eq!(busy["outcome"], "busy");
        assert!(busy["message"].as_str().is_some_and(|m| !m.is_empty()));

        let rejected = take_json(unsafe {
            totaldrop_mac_handle_url_json(
                cstr("https://evil.example/r#7-harbor-rocket").as_ptr(),
                cstr("idle").as_ptr(),
                ptr::null(),
                ptr::null(),
            )
        });
        assert_eq!(rejected["ok"], false);
        assert_eq!(rejected["outcome"], "rejected");

        let clip = take_json(unsafe {
            totaldrop_mac_extract_clipboard_code_json(
                cstr("Get my files with TotalDrop. Code: 9-harbor-rocket").as_ptr(),
            )
        });
        assert_eq!(clip["ok"], true);
        assert_eq!(clip["display_code"], "9-harbor-rocket");
        assert_eq!(
            clip["universal_link"],
            "https://totaldrop.app/r#9-harbor-rocket"
        );

        let null_err = take_json(unsafe { totaldrop_mac_extract_clipboard_code_json(ptr::null()) });
        assert_eq!(null_err["ok"], false);
        assert_eq!(null_err["error"]["kind"], "null_pointer");
    }

    #[test]
    fn finder_url_validation_normalizes_nfd_and_detects_case_collisions() {
        let urls = serde_json::to_string(&vec![
            "file:///Users/ada/A/Cafe%CC%81.pdf",
            "file:///Users/ada/B/caf%C3%A9.pdf",
            "https://example.org/not-local.txt",
        ])
        .unwrap();
        let res = take_json(unsafe {
            totaldrop_mac_validate_finder_urls_json(
                cstr(&urls).as_ptr(),
                cstr("idle").as_ptr(),
                false,
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        });
        assert_eq!(res["ok"], true);
        assert_eq!(res["busy"], false);
        assert_eq!(res["accepted"].as_array().unwrap().len(), 1);
        assert_eq!(res["accepted"][0]["normalized_name"], "Café.pdf");
        assert_eq!(res["skipped"].as_array().unwrap().len(), 2);
        assert_eq!(res["skipped"][0]["reason"], "case_collision");
        assert_eq!(res["skipped"][1]["reason"], "not_local_file_url");
    }

    #[test]
    fn sanitize_and_progress_helpers() {
        let name = take_json(unsafe {
            totaldrop_mac_sanitize_filename_json(cstr("invoice\u{202E}fdp.app").as_ptr())
        });
        assert_eq!(name["ok"], true);
        assert_eq!(name["has_hidden_controls"], true);
        assert_eq!(name["sanitized"], "invoice<U+202E>fdp.app");

        let text = take_json(unsafe {
            totaldrop_mac_sanitize_text_json(cstr("hello\u{202E}world\r\nline2").as_ptr())
        });
        assert_eq!(text["ok"], true);
        assert_eq!(text["had_hidden_controls"], true);
        assert_eq!(text["shortened"], false);
        assert_eq!(text["display_text"], "hello<U+202E>world\nline2");

        let prog = take_json(unsafe {
            totaldrop_mac_format_progress_json(
                999_999,
                1_000_000,
                cstr("de-DE").as_ptr(),
                cstr("de_DE").as_ptr(),
            )
        });
        assert_eq!(prog["ok"], true);
        assert_eq!(prog["percent_value"], 99);
        assert!(prog["done_bytes_text"].as_str().unwrap().contains(','));

        let sel = take_json(unsafe {
            totaldrop_mac_format_selection_json(
                3,
                1_500_000,
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        });
        assert_eq!(sel["ok"], true);
        assert!(sel["summary"].as_str().is_some_and(|s| !s.is_empty()));
    }

    #[test]
    fn invalid_session_handles_return_documented_error_codes() {
        assert_eq!(
            unsafe { totaldrop_mac_session_accept_offer(0, ptr::null()) },
            FFI_ERR_INVALID_HANDLE
        );
        assert_eq!(
            totaldrop_mac_session_decline_offer(999_999),
            FFI_ERR_INVALID_HANDLE
        );
        assert_eq!(totaldrop_mac_session_stop(999_999), FFI_ERR_INVALID_HANDLE);
        assert_eq!(
            totaldrop_mac_session_destroy(999_999),
            FFI_ERR_INVALID_HANDLE
        );
        let poll = take_json(totaldrop_mac_session_poll_events_ndjson(999_999));
        assert_eq!(poll["ok"], false);
        assert_eq!(poll["error"]["kind"], "invalid_handle");
    }

    // -----------------------------------------------------------------------
    // Embedded loopback rendezvous server for real C ABI E2E transfer tests
    // -----------------------------------------------------------------------

    use totaldrop_proto::wire::{ClientMessage, ServerMessage};

    #[derive(Default)]
    struct MockRendezvousState {
        next_nameplate: u32,
        mailboxes: HashMap<u32, MockMailbox>,
    }

    struct MockMailbox {
        id: [u8; 16],
        messages: Vec<(usize, String, Vec<u8>)>,
        peers: Vec<(usize, mpsc::UnboundedSender<Message>)>,
    }

    async fn spawn_loopback_rendezvous() -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let state = Arc::new(Mutex::new(MockRendezvousState {
            next_nameplate: 7,
            mailboxes: HashMap::new(),
        }));
        let handle = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    let Ok(ws) = tokio_tungstenite::accept_async(stream).await else {
                        return;
                    };
                    let (mut sink, mut stream) = ws.split();
                    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
                    let writer = tokio::spawn(async move {
                        while let Some(msg) = rx.recv().await {
                            let is_close = matches!(msg, Message::Close(_));
                            if sink.send(msg).await.is_err() || is_close {
                                break;
                            }
                        }
                    });

                    let mut my_peer_id: usize = 0;
                    let mut my_nameplate: Option<u32> = None;

                    while let Some(Ok(Message::Binary(raw))) = stream.next().await {
                        let Ok(client_msg) = ClientMessage::decode(&raw) else {
                            continue;
                        };
                        match client_msg {
                            ClientMessage::Allocate => {
                                let mut guard = state.lock().await;
                                let np = guard.next_nameplate;
                                guard.next_nameplate = guard.next_nameplate.saturating_add(1);
                                let mut mailbox_id = [0u8; 16];
                                mailbox_id[0..4].copy_from_slice(&np.to_be_bytes());
                                let mut token = [0xA5u8; 16];
                                token[0..4].copy_from_slice(&np.to_be_bytes());
                                guard.mailboxes.insert(
                                    np,
                                    MockMailbox {
                                        id: mailbox_id,
                                        messages: Vec::new(),
                                        peers: Vec::new(),
                                    },
                                );
                                let reply = ServerMessage::Allocated {
                                    nameplate: np,
                                    token,
                                };
                                let _ = tx.send(Message::Binary(reply.encode().into()));
                            }
                            ClientMessage::Claim { nameplate, .. } => {
                                let mut guard = state.lock().await;
                                if let Some(mb) = guard.mailboxes.get_mut(&nameplate) {
                                    let reply = ServerMessage::Claimed { mailbox: mb.id };
                                    let _ = tx.send(Message::Binary(reply.encode().into()));
                                    my_peer_id = mb.peers.len();
                                    for (from, phase, body) in &mb.messages {
                                        if *from != my_peer_id {
                                            let fwd = ServerMessage::Message {
                                                phase: phase.clone(),
                                                body: body.clone(),
                                            };
                                            let _ = tx.send(Message::Binary(fwd.encode().into()));
                                        }
                                    }
                                    mb.peers.push((my_peer_id, tx.clone()));
                                    my_nameplate = Some(nameplate);
                                } else {
                                    let reply = ServerMessage::Error {
                                        reason: "unknown nameplate".to_owned(),
                                    };
                                    let _ = tx.send(Message::Binary(reply.encode().into()));
                                }
                            }
                            ClientMessage::Add { phase, body } => {
                                if let Some(np) = my_nameplate {
                                    let mut guard = state.lock().await;
                                    if let Some(mb) = guard.mailboxes.get_mut(&np) {
                                        mb.messages.push((my_peer_id, phase.clone(), body.clone()));
                                        let fwd = ServerMessage::Message { phase, body }.encode();
                                        for (peer_id, peer_tx) in &mb.peers {
                                            if *peer_id != my_peer_id {
                                                let _ = peer_tx
                                                    .send(Message::Binary(fwd.clone().into()));
                                            }
                                        }
                                    }
                                }
                            }
                            ClientMessage::Close { .. } => {
                                let _ = tx.send(Message::Close(None));
                                break;
                            }
                        }
                    }
                    drop(tx);
                    let _ = writer.await;
                });
            }
        });
        (addr, handle)
    }

    fn poll_events_until<F>(handle: u64, timeout: Duration, mut pred: F) -> Vec<Value>
    where
        F: FnMut(&Value) -> bool,
    {
        let deadline = Instant::now().checked_add(timeout).unwrap();
        let mut all = Vec::new();
        while Instant::now() < deadline {
            let chunk = take_string(totaldrop_mac_session_poll_events_ndjson(handle));
            for line in chunk.lines().filter(|l| !l.trim().is_empty()) {
                let ev: Value = serde_json::from_str(line).unwrap();
                let done = pred(&ev);
                all.push(ev);
                if done {
                    return all;
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("timed out polling handle {handle}; events seen so far: {all:#?}");
    }

    #[test]
    fn loopback_e2e_file_transfer_and_text_transfer_via_c_abi() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let (rv_addr, rv_task) = rt.block_on(spawn_loopback_rendezvous());
        let cfg = json!({
            "server": format!("ws://{rv_addr}"),
            "relay": "",
            "stun": "",
            "privacy_mode": false,
            "stronger_code": false
        })
        .to_string();

        // 1. Real file send -> receive over loopback QUIC + Noise XXpsk3 + ML-KEM-768 + BLAKE3.
        let temp_root =
            std::env::temp_dir().join(format!("totaldrop-macos-ffi-e2e-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_root);
        let src_dir = temp_root.join("src");
        let dst_dir = temp_root.join("dst");
        std::fs::create_dir_all(&src_dir).unwrap();
        std::fs::create_dir_all(&dst_dir).unwrap();
        let src_file = src_dir.join("mac-e2e-sample.bin");
        let payload: Vec<u8> = (0..65_536u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(&src_file, &payload).unwrap();

        let paths_json = serde_json::to_string(&vec![src_file.to_string_lossy()]).unwrap();
        let send_handle = unsafe {
            totaldrop_mac_session_start_send_files(
                cstr(&paths_json).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        assert_ne!(send_handle, 0);

        let send_ready = poll_events_until(send_handle, Duration::from_secs(10), |ev| {
            ev["event"] == "code_ready"
        });
        let code = send_ready
            .iter()
            .find(|ev| ev["event"] == "code_ready")
            .unwrap()["display_code"]
            .as_str()
            .unwrap()
            .to_owned();

        let recv_handle = unsafe {
            totaldrop_mac_session_start_receive(
                cstr(&code).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("tr-TR").as_ptr(),
                cstr("tr_TR").as_ptr(),
            )
        };
        assert_ne!(recv_handle, 0);

        let offer_events = poll_events_until(recv_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "offer_ready" || ev["event"] == "failed"
        });
        let offer = offer_events
            .iter()
            .find(|ev| ev["event"] == "offer_ready")
            .unwrap_or_else(|| panic!("expected offer_ready, got {offer_events:#?}"));
        assert_eq!(offer["files"], 1);
        assert_eq!(offer["total_bytes"], 65_536);
        assert_eq!(offer["is_text"], false);
        assert_eq!(offer["verification_words"].as_array().unwrap().len(), 4);

        let accept_rc = unsafe {
            totaldrop_mac_session_accept_offer(
                recv_handle,
                cstr(&dst_dir.to_string_lossy()).as_ptr(),
            )
        };
        assert_eq!(accept_rc, FFI_OK);

        let recv_done = poll_events_until(recv_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        let recv_final = recv_done.last().unwrap();
        assert_eq!(recv_final["event"], "done", "recv failed: {recv_done:#?}");
        assert_eq!(recv_final["files_ok"], 1);
        assert_eq!(recv_final["bytes"], 65_536);

        let send_done = poll_events_until(send_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        let send_final = send_done.last().unwrap();
        assert_eq!(send_final["event"], "done", "send failed: {send_done:#?}");
        assert_eq!(send_final["files_ok"], 1);

        let arrived = std::fs::read(dst_dir.join("mac-e2e-sample.bin")).unwrap();
        assert_eq!(arrived, payload);
        assert_eq!(totaldrop_mac_session_destroy(send_handle), FFI_OK);
        assert_eq!(totaldrop_mac_session_destroy(recv_handle), FFI_OK);

        // 2. Real inline text send -> receive (with Bidi sanitization check).
        let secret_note = "macOS note \u{202E}rtl-check";
        let text_send = unsafe {
            totaldrop_mac_session_start_send_text(
                cstr(secret_note).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        assert_ne!(text_send, 0);
        let text_ready = poll_events_until(text_send, Duration::from_secs(10), |ev| {
            ev["event"] == "code_ready"
        });
        let text_code = text_ready
            .iter()
            .find(|ev| ev["event"] == "code_ready")
            .unwrap()["display_code"]
            .as_str()
            .unwrap()
            .to_owned();

        let text_recv = unsafe {
            totaldrop_mac_session_start_receive(
                cstr(&text_code).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        let text_offer = poll_events_until(text_recv, Duration::from_secs(15), |ev| {
            ev["event"] == "offer_ready" || ev["event"] == "failed"
        });
        assert_eq!(text_offer.last().unwrap()["is_text"], true);
        assert_eq!(
            unsafe { totaldrop_mac_session_accept_offer(text_recv, ptr::null()) },
            FFI_OK
        );

        let text_done = poll_events_until(text_recv, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        let final_text = text_done.last().unwrap();
        assert_eq!(
            final_text["event"], "done",
            "text recv failed: {text_done:#?}"
        );
        assert_eq!(final_text["is_text"], true);
        assert_eq!(final_text["received_text"], secret_note);
        assert_eq!(final_text["sanitized_text"], "macOS note <U+202E>rtl-check");
        assert_eq!(final_text["text_had_hidden_controls"], true);

        let _ = poll_events_until(text_send, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        assert_eq!(totaldrop_mac_session_destroy(text_send), FFI_OK);
        assert_eq!(totaldrop_mac_session_destroy(text_recv), FFI_OK);

        rv_task.abort();
        let _ = std::fs::remove_dir_all(&temp_root);
    }
}
