/* SPDX-FileCopyrightText: 2026 The TotalDrop Contributors */
/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef TOTALDROP_MACOS_FFI_H
#define TOTALDROP_MACOS_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Releases a NUL-terminated UTF-8 string previously returned by any
 * `totaldrop_mac_*` function returning `char *`. Safe to call with `NULL`.
 */
void totaldrop_mac_string_free(char *ptr);

/**
 * Returns JSON containing `app_version`, `core_version`, and `bundle_version`.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_version_json(void);

/**
 * Returns the localized 35-language UI bundle JSON (`locale`, `isRtl`,
 * `isDraft`, `strings`) negotiated from `preferred_langs_json` (JSON array of
 * BCP-47 tags or comma-separated list) and optional `numeric_locale`.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_ui_bundle_json(
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Routes an incoming `totaldrop://r/...` or `https://totaldrop.app/r#...` URL
 * through `totaldrop_macos_bridge::handle_macos_open_url`.
 * `activity` accepts `"idle"`, `"transfer_running"`, `"offer_pending"`, or
 * `"showing_received_text"`.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_handle_url_json(
    const char *raw_url,
    const char *activity,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Extracts a normalized TotalDrop transfer code from clipboard or QR text
 * (`display_code`, `canonical_code`, `universal_link`, `scheme_link`).
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_extract_clipboard_code_json(const char *raw_text);

/**
 * Validates a JSON array of `file://` URLs from Finder Quick Actions, Share
 * Extension, or drag-and-drop with APFS NFD-to-NFC normalization and
 * case-collision filtering.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_validate_finder_urls_json(
    const char *urls_json,
    const char *activity,
    bool verify_on_disk,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Sanitizes a peer-supplied filename by revealing hidden Bidi/control code
 * points (`<U+202E>`, etc.).
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_sanitize_filename_json(const char *raw_name);

/**
 * Sanitizes received text for display, revealing hidden controls and capping
 * inline display length to `MAX_SHOWN_TEXT_CHARS`.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_sanitize_text_json(const char *raw_text);

/**
 * Formats floor-rounded regional transfer progress and compact `MenuBarExtra`
 * status text.
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_format_progress_json(
    uint64_t done_bytes,
    uint64_t total_bytes,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Formats a localized item count and total byte size summary (`itemsAndSize`).
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_format_selection_json(
    uint64_t item_count,
    uint64_t total_bytes,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous file/folder send session on the background Tokio
 * runtime. `paths_json` must be a JSON array of local filesystem path strings.
 * `config_json` is an optional JSON object overriding rendezvous/relay/stun,
 * `privacy_mode`, and `stronger_code`.
 * Returns a non-zero monotonic session handle, or `0` on invalid input.
 */
uint64_t totaldrop_mac_session_start_send_files(
    const char *paths_json,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous inline text send session on the background Tokio
 * runtime.
 * Returns a non-zero monotonic session handle, or `0` on invalid input.
 */
uint64_t totaldrop_mac_session_start_send_text(
    const char *text,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous receive session for `code_or_link` on the background
 * Tokio runtime.
 * Returns a non-zero monotonic session handle, or `0` on invalid input.
 */
uint64_t totaldrop_mac_session_start_receive(
    const char *code_or_link,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Accepts a pending incoming offer for `handle`. For file offers, `dest_dir`
 * must be a non-empty writable directory path; for text offers, `dest_dir` may
 * be `NULL` or empty.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mac_session_accept_offer(
    uint64_t handle,
    const char *dest_dir
);

/**
 * Declines a pending incoming offer for `handle`.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mac_session_decline_offer(uint64_t handle);

/**
 * Signals cancellation for an active transfer session `handle`.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mac_session_stop(uint64_t handle);

/**
 * Drains queued NDJSON event lines for `handle` (empty string when no new
 * events are pending).
 * Caller must free the returned pointer with `totaldrop_mac_string_free`.
 */
char *totaldrop_mac_session_poll_events_ndjson(uint64_t handle);

/**
 * Cancels (if still running) and removes `handle` from the session registry.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mac_session_destroy(uint64_t handle);

#ifdef __cplusplus
}
#endif

#endif /* TOTALDROP_MACOS_FFI_H */
