// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Static 2-thread Tokio runtime, monotonic `u64` transfer session registry,
//! and NDJSON event stream engine for `totaldrop-macos-ffi`.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;
use totaldrop_core::{Error as CoreError, Event, PreparedSend, TEXT_FILE, check_destination};
use totaldrop_macos_bridge::{
    MacLocalizationBundle, MacOfferPreview, MacStopHandle, MacTransferConfig, build_share_payload,
    connect_macos_receive, describe_core_error, format_transfer_progress, prepare_macos_file_send,
};

use crate::{FFI_ERR_INVALID_ARG, FFI_ERR_INVALID_HANDLE, FFI_ERR_INVALID_STATE, FFI_OK};

/// Maximum queued events per session before oldest progress ticks are coalesced.
const MAX_QUEUED_EVENTS: usize = 256;

/// Static 2-thread Tokio runtime driving all async network, QUIC, crypto, and
/// disk I/O off the SwiftUI `@MainActor` thread (ADR 0009).
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("totaldrop-mac")
        .build()
        .unwrap_or_else(|_| std::process::abort())
});

static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

static SESSIONS: LazyLock<Mutex<HashMap<u64, Arc<SessionEntry>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// JSON-deserializable network and transfer config allowing omitted optional
/// fields to inherit [`MacTransferConfig::default`] while preserving explicit
/// empty strings (such as `"relay": ""`, `"stun": ""` in loopback tests).
#[derive(Debug, Default, Deserialize)]
pub(crate) struct FfiTransferConfig {
    server: Option<String>,
    relay: Option<String>,
    stun: Option<String>,
    #[serde(default)]
    privacy_mode: bool,
    #[serde(default)]
    stronger_code: bool,
}

impl FfiTransferConfig {
    pub(crate) fn into_mac_config(self) -> MacTransferConfig {
        let defaults = MacTransferConfig::default();
        MacTransferConfig {
            server: self.server.unwrap_or(defaults.server),
            relay: self.relay.unwrap_or(defaults.relay),
            stun: self.stun.unwrap_or(defaults.stun),
            privacy_mode: self.privacy_mode,
            stronger_code: self.stronger_code,
        }
    }
}

#[derive(Debug)]
enum OfferDecision {
    Accept { dest_dir: Option<PathBuf> },
    Decline,
}

/// NDJSON event emitted by `totaldrop_mac_session_poll_events_ndjson`.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(crate) enum MacSessionEvent {
    CodeReady {
        display_code: String,
        canonical_code: String,
        universal_link: String,
        scheme_link: String,
        share_message: String,
        entries: usize,
        total_bytes: u64,
        formatted_total: String,
        skipped: usize,
        is_text: bool,
    },
    Waiting {
        headline: String,
    },
    Connected {
        verification_words: Vec<String>,
        joined_words_ltr: String,
    },
    OfferReady {
        files: usize,
        dirs: usize,
        total_bytes: u64,
        formatted_size: String,
        is_text: bool,
        headline: String,
        summary_line: String,
        top_level_names: Vec<String>,
        remaining_names: usize,
        more_names_line: Option<String>,
        has_hidden_controls: bool,
        verification_words: Vec<String>,
        joined_words_ltr: String,
    },
    Progress {
        done_bytes: u64,
        total_bytes: u64,
        percent_value: u8,
        percent_text: String,
        done_bytes_text: String,
        total_bytes_text: String,
        fraction_text: String,
        menu_bar_label: String,
    },
    Done {
        files_ok: usize,
        files_failed: usize,
        bytes: u64,
        formatted_bytes: String,
        is_text: bool,
        saved_to: Option<String>,
        placed: Vec<String>,
        received_text: Option<String>,
        sanitized_text: Option<String>,
        text_shortened: bool,
        text_had_hidden_controls: bool,
    },
    Declined {
        is_text: bool,
        headline: String,
    },
    Failed {
        headline_key: String,
        headline: String,
        cause: Option<String>,
        technical_detail: String,
    },
}

impl MacSessionEvent {
    fn from_core_error(error: &CoreError, is_sender: bool, bundle: &MacLocalizationBundle) -> Self {
        let alert = describe_core_error(error, is_sender, bundle);
        Self::Failed {
            headline_key: alert.headline_key.to_owned(),
            headline: alert.headline,
            cause: alert.cause,
            technical_detail: alert.technical_detail,
        }
    }
}

struct SessionEntry {
    stop: MacStopHandle,
    events: Mutex<VecDeque<MacSessionEvent>>,
    pending_decision: Mutex<Option<oneshot::Sender<OfferDecision>>>,
    pending_is_text: Mutex<Option<bool>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl SessionEntry {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            stop: MacStopHandle::new(),
            events: Mutex::new(VecDeque::new()),
            pending_decision: Mutex::new(None),
            pending_is_text: Mutex::new(None),
            task: Mutex::new(None),
        })
    }

    fn push_event(&self, event: MacSessionEvent) {
        if let Ok(mut queue) = self.events.lock() {
            // Coalesce consecutive progress events so polling never falls behind on large streams.
            if matches!(event, MacSessionEvent::Progress { .. })
                && matches!(queue.back(), Some(MacSessionEvent::Progress { .. }))
            {
                let _ = queue.pop_back();
            } else if queue.len() >= MAX_QUEUED_EVENTS {
                let _ = queue.pop_front();
            }
            queue.push_back(event);
        }
    }

    fn drain_ndjson(&self) -> String {
        let drained: Vec<MacSessionEvent> = match self.events.lock() {
            Ok(mut queue) => queue.drain(..).collect(),
            Err(_) => return String::new(),
        };
        if drained.is_empty() {
            return String::new();
        }
        let mut out = String::new();
        for ev in drained {
            if let Ok(line) = serde_json::to_string(&ev) {
                out.push_str(&line);
                out.push('\n');
            }
        }
        out
    }

    fn set_pending_decision(&self, tx: oneshot::Sender<OfferDecision>, is_text: bool) {
        if let Ok(mut slot) = self.pending_is_text.lock() {
            *slot = Some(is_text);
        }
        if let Ok(mut slot) = self.pending_decision.lock() {
            *slot = Some(tx);
        }
    }

    fn clear_pending_decision(&self) {
        if let Ok(mut slot) = self.pending_decision.lock() {
            *slot = None;
        }
        if let Ok(mut slot) = self.pending_is_text.lock() {
            *slot = None;
        }
    }

    fn take_pending_decision(&self) -> Option<(oneshot::Sender<OfferDecision>, bool)> {
        let tx = self.pending_decision.lock().ok()?.take()?;
        let is_text = self
            .pending_is_text
            .lock()
            .ok()
            .and_then(|mut s| s.take())
            .unwrap_or(false);
        Some((tx, is_text))
    }
}

fn register_session(entry: Arc<SessionEntry>) -> u64 {
    let id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut map) = SESSIONS.lock() {
        map.insert(id, entry);
    }
    id
}

fn lookup_session(handle: u64) -> Option<Arc<SessionEntry>> {
    if handle == 0 {
        return None;
    }
    SESSIONS.lock().ok()?.get(&handle).cloned()
}

fn join_words_ltr(words: &[String]) -> String {
    let joined = words.join(" \u{00B7} ");
    format!("\u{2066}{joined}\u{2069}")
}

fn make_event_callback(
    entry: Arc<SessionEntry>,
    bundle: Arc<MacLocalizationBundle>,
) -> totaldrop_core::Events {
    Arc::new(move |ev| match ev {
        Event::Waiting => {
            entry.push_event(MacSessionEvent::Waiting {
                headline: bundle.text("sendWaiting"),
            });
        }
        Event::Connected { words } => {
            let joined_words_ltr = join_words_ltr(&words);
            entry.push_event(MacSessionEvent::Connected {
                verification_words: words,
                joined_words_ltr,
            });
        }
        Event::Progress { done, total } => {
            let formatted = format_transfer_progress(done, total, &bundle);
            let clamped = if total > 0 { done.min(total) } else { done };
            entry.push_event(MacSessionEvent::Progress {
                done_bytes: clamped,
                total_bytes: total,
                percent_value: formatted.percent_value,
                percent_text: formatted.percent_text,
                done_bytes_text: formatted.done_bytes_text,
                total_bytes_text: formatted.total_bytes_text,
                fraction_text: formatted.fraction_text,
                menu_bar_label: formatted.menu_bar_label,
            });
        }
    })
}

pub(crate) fn start_send_files(
    paths: Vec<PathBuf>,
    config: MacTransferConfig,
    bundle: MacLocalizationBundle,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let bundle = Arc::new(bundle);
    let task_entry = Arc::clone(&entry);
    let task_bundle = Arc::clone(&bundle);

    let join = RUNTIME.spawn(async move {
        let prepared = match prepare_macos_file_send(&config, &paths, &task_entry.stop).await {
            Ok(p) => p,
            Err(err) => {
                task_entry.push_event(MacSessionEvent::from_core_error(&err, true, &task_bundle));
                return;
            }
        };
        run_prepared_send(prepared, false, task_entry, task_bundle).await;
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

pub(crate) fn start_send_text(
    text: String,
    config: MacTransferConfig,
    bundle: MacLocalizationBundle,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let bundle = Arc::new(bundle);
    let task_entry = Arc::clone(&entry);
    let task_bundle = Arc::clone(&bundle);

    let join = RUNTIME.spawn(async move {
        if task_entry.stop.is_cancelled() {
            task_entry.push_event(MacSessionEvent::from_core_error(
                &CoreError::Stopped,
                true,
                &task_bundle,
            ));
            return;
        }
        let opts = config.send_options();
        let prepared = tokio::select! {
            biased;
            res = PreparedSend::text(&opts, &text, TEXT_FILE) => res,
            () = task_entry.stop.as_core_stop().stopped() => Err(CoreError::Stopped),
        };
        let prepared = match prepared {
            Ok(p) => p,
            Err(err) => {
                task_entry.push_event(MacSessionEvent::from_core_error(&err, true, &task_bundle));
                return;
            }
        };
        run_prepared_send(prepared, true, task_entry, task_bundle).await;
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

async fn run_prepared_send(
    prepared: PreparedSend,
    is_text: bool,
    entry: Arc<SessionEntry>,
    bundle: Arc<MacLocalizationBundle>,
) {
    let code = prepared.code().clone();
    let share = build_share_payload(&code, &bundle);
    let (entries, total_bytes) = prepared.totals();
    let skipped = prepared.skipped();
    entry.push_event(MacSessionEvent::CodeReady {
        display_code: share.code,
        canonical_code: code.canonical(),
        universal_link: share.universal_link,
        scheme_link: share.scheme_link,
        share_message: share.message,
        entries,
        total_bytes,
        formatted_total: bundle.format_bytes(total_bytes),
        skipped,
        is_text,
    });

    let cb = make_event_callback(Arc::clone(&entry), Arc::clone(&bundle));
    let stop_clone = entry.stop.as_core_stop().clone();
    match prepared.run_with(cb, stop_clone).await {
        Ok(report) => {
            entry.push_event(MacSessionEvent::Done {
                files_ok: report.files_ok,
                files_failed: report.files_failed,
                bytes: report.bytes,
                formatted_bytes: bundle.format_bytes(report.bytes),
                is_text,
                saved_to: None,
                placed: Vec::new(),
                received_text: None,
                sanitized_text: None,
                text_shortened: false,
                text_had_hidden_controls: false,
            });
        }
        Err(err) => {
            entry.push_event(MacSessionEvent::from_core_error(&err, true, &bundle));
        }
    }
}

pub(crate) fn start_receive(
    code_or_link: String,
    config: MacTransferConfig,
    bundle: MacLocalizationBundle,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let bundle = Arc::new(bundle);
    let task_entry = Arc::clone(&entry);
    let task_bundle = Arc::clone(&bundle);

    let join = RUNTIME.spawn(async move {
        let offer = match connect_macos_receive(&config, &code_or_link, &task_entry.stop).await {
            Ok(o) => o,
            Err(err) => {
                task_entry.push_event(MacSessionEvent::from_core_error(&err, false, &task_bundle));
                return;
            }
        };

        let preview = MacOfferPreview::from_offer_summary(offer.summary(), &task_bundle);
        let is_text = preview.is_text_offer;
        let words = offer.words().to_vec();
        let joined_words_ltr = join_words_ltr(&words);

        let (tx, rx) = oneshot::channel::<OfferDecision>();
        task_entry.set_pending_decision(tx, is_text);

        task_entry.push_event(MacSessionEvent::OfferReady {
            files: preview.files,
            dirs: preview.dirs,
            total_bytes: preview.total_bytes,
            formatted_size: preview.formatted_size,
            is_text,
            headline: preview.headline,
            summary_line: preview.summary_line,
            top_level_names: preview.top_level_names,
            remaining_names: preview.remaining_names,
            more_names_line: preview.more_names_line,
            has_hidden_controls: preview.has_hidden_controls,
            verification_words: words,
            joined_words_ltr,
        });

        let decision = tokio::select! {
            biased;
            res = rx => res.ok(),
            () = task_entry.stop.as_core_stop().stopped() => None,
        };
        task_entry.clear_pending_decision();

        match decision {
            None => {
                let err = offer.stop().await;
                task_entry.push_event(MacSessionEvent::from_core_error(&err, false, &task_bundle));
            }
            Some(OfferDecision::Decline) => match offer.decline().await {
                Ok(()) => {
                    task_entry.push_event(MacSessionEvent::Declined {
                        is_text,
                        headline: task_bundle.text("errorDeclined"),
                    });
                }
                Err(err) => {
                    task_entry.push_event(MacSessionEvent::from_core_error(
                        &err,
                        false,
                        &task_bundle,
                    ));
                }
            },
            Some(OfferDecision::Accept { dest_dir }) => {
                if is_text {
                    match offer.accept_text_with(task_entry.stop.as_core_stop()).await {
                        Ok(report) => {
                            let raw_text = report.text.clone();
                            let sanitized = raw_text
                                .as_deref()
                                .map(|txt| task_bundle.sanitize_received_text(txt));
                            task_entry.push_event(MacSessionEvent::Done {
                                files_ok: report.files_ok,
                                files_failed: report.files_failed,
                                bytes: report.bytes,
                                formatted_bytes: task_bundle.format_bytes(report.bytes),
                                is_text: true,
                                saved_to: None,
                                placed: Vec::new(),
                                received_text: raw_text,
                                sanitized_text: sanitized.as_ref().map(|s| s.display_text.clone()),
                                text_shortened: sanitized.as_ref().is_some_and(|s| s.shortened),
                                text_had_hidden_controls: sanitized
                                    .as_ref()
                                    .is_some_and(|s| s.had_hidden_controls),
                            });
                        }
                        Err(err) => {
                            task_entry.push_event(MacSessionEvent::from_core_error(
                                &err,
                                false,
                                &task_bundle,
                            ));
                        }
                    }
                } else {
                    let Some(dest) = dest_dir else {
                        let err = offer.stop().await;
                        task_entry.push_event(MacSessionEvent::from_core_error(
                            &err,
                            false,
                            &task_bundle,
                        ));
                        return;
                    };
                    if let Err(err) = check_destination(&dest) {
                        let _ = offer.stop().await;
                        task_entry.push_event(MacSessionEvent::from_core_error(
                            &err,
                            false,
                            &task_bundle,
                        ));
                        return;
                    }
                    let cb = make_event_callback(Arc::clone(&task_entry), Arc::clone(&task_bundle));
                    match offer
                        .accept_with(&dest, cb, task_entry.stop.as_core_stop())
                        .await
                    {
                        Ok(report) => {
                            let placed: Vec<String> = report
                                .placed
                                .iter()
                                .map(|p| task_bundle.sanitize_filename(&p.to_string_lossy()))
                                .collect();
                            task_entry.push_event(MacSessionEvent::Done {
                                files_ok: report.files_ok,
                                files_failed: report.files_failed,
                                bytes: report.bytes,
                                formatted_bytes: task_bundle.format_bytes(report.bytes),
                                is_text: false,
                                saved_to: Some(dest.to_string_lossy().into_owned()),
                                placed,
                                received_text: None,
                                sanitized_text: None,
                                text_shortened: false,
                                text_had_hidden_controls: false,
                            });
                        }
                        Err(err) => {
                            task_entry.push_event(MacSessionEvent::from_core_error(
                                &err,
                                false,
                                &task_bundle,
                            ));
                        }
                    }
                }
            }
        }
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

pub(crate) fn accept_offer(handle: u64, dest_dir: Option<PathBuf>) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    let is_text = entry
        .pending_is_text
        .lock()
        .ok()
        .and_then(|slot| *slot)
        .unwrap_or(false);
    if !is_text {
        let Some(ref dir) = dest_dir else {
            return FFI_ERR_INVALID_ARG;
        };
        if dir.as_os_str().is_empty() {
            return FFI_ERR_INVALID_ARG;
        }
    }
    let Some((tx, _)) = entry.take_pending_decision() else {
        return FFI_ERR_INVALID_STATE;
    };
    match tx.send(OfferDecision::Accept { dest_dir }) {
        Ok(()) => FFI_OK,
        Err(_) => FFI_ERR_INVALID_STATE,
    }
}

pub(crate) fn decline_offer(handle: u64) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    let Some((tx, _)) = entry.take_pending_decision() else {
        return FFI_ERR_INVALID_STATE;
    };
    match tx.send(OfferDecision::Decline) {
        Ok(()) => FFI_OK,
        Err(_) => FFI_ERR_INVALID_STATE,
    }
}

pub(crate) fn stop_session(handle: u64) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    entry.stop.cancel();
    entry.clear_pending_decision();
    FFI_OK
}

pub(crate) fn poll_events_ndjson(handle: u64) -> Option<String> {
    let entry = lookup_session(handle)?;
    Some(entry.drain_ndjson())
}

pub(crate) fn destroy_session(handle: u64) -> i32 {
    if handle == 0 {
        return FFI_ERR_INVALID_HANDLE;
    }
    let removed = SESSIONS.lock().ok().and_then(|mut map| map.remove(&handle));
    let Some(entry) = removed else {
        return FFI_ERR_INVALID_HANDLE;
    };
    entry.stop.cancel();
    entry.clear_pending_decision();
    if let Ok(mut slot) = entry.task.lock()
        && let Some(join) = slot.take()
    {
        join.abort();
    }
    FFI_OK
}
