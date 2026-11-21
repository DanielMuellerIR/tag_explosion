use crate::localization::{language, text};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::ErrorKind,
    os::unix::process::ExitStatusExt,
    path::PathBuf,
    process::{ExitStatus, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, Weak,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    process::{Child, Command},
    sync::{mpsc, oneshot, Mutex as AsyncMutex},
};

const MAXIMUM_MESSAGE: usize = 24 * 1024 * 1024;
const MAXIMUM_PENDING: usize = 64;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(600);
const UPDATE_CONTROL_TIMEOUT: Duration = Duration::from_secs(10);
const DIAGNOSTIC_GRACE: Duration = Duration::from_millis(250);

type Reply = oneshot::Sender<Result<Value, String>>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Effect {
    Read,
    Mutation,
    Cleanup,
}

impl Effect {
    fn of(method: &str, params: &Value) -> Self {
        match method {
            "cancel" | "endUpdate" | "close" => Self::Cleanup,
            "preferences" if params.get("values").is_none() => Self::Read,
            "hello"
            | "tools"
            | "rulesSchema"
            | "lookupAuthorization"
            | "lookupQuery"
            | "batchCoverPreview"
            | "rawImageTags"
            | "batchInfo"
            | "state"
            | "entry"
            | "imagePreview"
            | "cover"
            | "history"
            | "historyDiff"
            | "invoice"
            | "readRules"
            | "info"
            | "imageMetadata"
            | "rulesPreview"
            | "renamePreview"
            | "check"
            | "lookupSearch"
            | "lookupDetails"
            | "lookupPreview"
            | "validationCurrent"
            | "validationReport"
            | "validate"
            | "prepareUpdate" => Self::Read,
            _ => Self::Mutation,
        }
    }
}

struct Pending {
    reply: Reply,
    effect: Effect,
    started: bool,
}

#[derive(Default)]
struct Calls {
    pending: HashMap<u64, Pending>,
    failure: Option<String>,
    uncertain_mutation: bool,
}

impl Calls {
    fn withdraw(&mut self, id: u64) -> bool {
        let uncertain = self
            .pending
            .remove(&id)
            .is_some_and(|pending| pending.effect == Effect::Mutation && pending.started);
        self.uncertain_mutation |= uncertain;
        uncertain
    }
}

struct Registration<'a> {
    calls: &'a Mutex<Calls>,
    id: u64,
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        self.calls.lock().unwrap().withdraw(self.id);
    }
}

struct Request {
    id: u64,
    bytes: Vec<u8>,
}

pub struct Engine {
    sequence: AtomicU64,
    input: AsyncMutex<Option<mpsc::Sender<Request>>>,
    calls: Mutex<Calls>,
    executable: PathBuf,
}

impl Engine {
    pub fn new(executable: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            sequence: AtomicU64::new(1),
            input: AsyncMutex::new(None),
            calls: Mutex::new(Calls::default()),
            executable,
        })
    }

    async fn connection(self: &Arc<Self>) -> Result<mpsc::Sender<Request>, String> {
        let mut input = self.input.lock().await;
        if let Some(failure) = &self.calls.lock().unwrap().failure {
            return Err(failure.clone());
        }
        if let Some(sender) = input.as_ref() {
            return Ok(sender.clone());
        }

        let mut command = Command::new(&self.executable);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("TAGX_DESKTOP_LANGUAGE", language())
            .kill_on_drop(true);
        if let Some(directory) = self.executable.parent() {
            let resources = directory.join("../share/tag-explosion");
            for (variable, name) in [
                ("TAGX_VALIDATION_BUNDLE", "XRechnungValidator"),
                ("TAGX_PDF_VALIDATION_BUNDLE", "PDFValidator"),
            ] {
                let path = resources.join(name);
                if std::env::var_os(variable).is_none() && path.is_dir() {
                    command.env(variable, path);
                }
            }
            let existing = std::env::var_os("PATH").unwrap_or_default();
            let mut paths = vec![directory.to_path_buf()];
            paths.extend(std::env::split_paths(&existing));
            if let Ok(path) = std::env::join_paths(paths) {
                command.env("PATH", path);
            }
        }
        let mut child = command.spawn().map_err(|error| {
            text(
                "Die mitgelieferte Medienverarbeitung konnte nicht gestartet werden",
                "Could not start the bundled media engine",
            )
            .to_owned()
                + match error.kind() {
                    ErrorKind::NotFound => text(
                        " (Programm oder Programmlader fehlt)",
                        " (engine executable or loader missing)",
                    ),
                    ErrorKind::PermissionDenied => {
                        text(" (Ausführung nicht erlaubt)", " (permission denied)")
                    }
                    _ => "",
                }
        })?;
        let (Some(writer), Some(reader), Some(stderr)) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take())
        else {
            return Err(text(
                "Die Medienverarbeitung konnte ihre Prozesskanäle nicht öffnen",
                "The media engine could not open its process pipes",
            )
            .into());
        };
        let (sender, receiver) = mpsc::channel(MAXIMUM_PENDING);
        *input = Some(sender.clone());
        tauri::async_runtime::spawn(run_connection(
            Arc::downgrade(self),
            child,
            writer,
            reader,
            stderr,
            receiver,
        ));
        Ok(sender)
    }

    fn register(
        &self,
        id: u64,
        effect: Effect,
        reply: Reply,
        update_control: bool,
    ) -> Result<Registration<'_>, String> {
        let mut calls = self.calls.lock().unwrap();
        if let Some(failure) = &calls.failure {
            return Err(failure.clone());
        }
        if calls.uncertain_mutation && effect == Effect::Mutation {
            return Err(uncertain_result().into());
        }
        // Für die Freigabe des Updates bleibt ein Platz außerhalb des normalen Limits.
        if calls.pending.len() >= MAXIMUM_PENDING && !update_control {
            return Err(too_many_requests().into());
        }
        calls.pending.insert(
            id,
            Pending {
                reply,
                effect,
                started: false,
            },
        );
        Ok(Registration {
            calls: &self.calls,
            id,
        })
    }

    fn start_request(&self, id: u64) -> bool {
        let mut calls = self.calls.lock().unwrap();
        let blocked = calls.uncertain_mutation;
        let Some(request) = calls.pending.get_mut(&id) else {
            return false;
        };
        if blocked && request.effect == Effect::Mutation {
            if let Some(request) = calls.pending.remove(&id) {
                let _ = request.reply.send(Err(uncertain_result().into()));
            }
            return false;
        }
        request.started = true;
        true
    }

    fn fail(&self, reason: String) {
        let mut calls = self.calls.lock().unwrap();
        calls.failure = Some(reason.clone());
        for (_, pending) in calls.pending.drain() {
            let message = if pending.started && pending.effect == Effect::Mutation {
                format!("{} {}", reason, uncertain_result())
            } else {
                reason.clone()
            };
            let _ = pending.reply.send(Err(message));
        }
    }

    pub async fn call(
        self: &Arc<Self>,
        session: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, String> {
        self.call_inner(session, method, params, REQUEST_TIMEOUT, false)
            .await
    }

    pub fn recovery_required(&self) -> bool {
        self.calls.lock().unwrap().uncertain_mutation
    }

    pub async fn set_updating(
        self: &Arc<Self>,
        session: &str,
        updating: bool,
    ) -> Result<bool, String> {
        self.set_updating_with_timeout(session, updating, UPDATE_CONTROL_TIMEOUT)
            .await
    }

    async fn set_updating_with_timeout(
        self: &Arc<Self>,
        session: &str,
        updating: bool,
        timeout: Duration,
    ) -> Result<bool, String> {
        let method = if updating { "beginUpdate" } else { "endUpdate" };
        let result = self
            .call_inner(session, method, json!({}), timeout, true)
            .await;
        match result {
            Ok(Value::Bool(value)) if value || updating => Ok(value),
            _ => {
                // Eine verspätete Bestätigung kann den reservierten Worker
                // hinterlassen. Bis zum Neustart keine Schreibaufträge annehmen.
                self.calls.lock().unwrap().uncertain_mutation = true;
                Err(result.err().unwrap_or_else(|| uncertain_result().into()))
            }
        }
    }

    async fn call_inner(
        self: &Arc<Self>,
        session: &str,
        method: &str,
        params: Value,
        timeout: Duration,
        update_control: bool,
    ) -> Result<Value, String> {
        let input = self.connection().await?;
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let effect = Effect::of(method, &params);
        let (send, mut receive) = oneshot::channel();
        let _registration = self.register(id, effect, send, update_control)?;
        let mut bytes = serde_json::to_vec(
            &json!({"id": id, "session": session, "method": method, "params": params}),
        )
        .map_err(|_| text("Ungültige Anfrage", "Invalid request"))?;
        if bytes.len() > MAXIMUM_MESSAGE {
            return Err(text("Die Anfrage ist zu groß", "The request is too large").into());
        }
        bytes.push(b'\n');
        let request = Request { id, bytes };
        let deadline = tokio::time::Instant::now() + timeout;
        let timeout_error = || {
            text(
                "Die Medienverarbeitung hat nicht rechtzeitig geantwortet.",
                "The media engine did not respond in time.",
            )
        };
        if update_control {
            // Auch der reservierte Platz in Calls garantiert keinen freien
            // Platz in der Pipe-Warteschlange.
            tokio::time::timeout_at(deadline, input.send(request))
                .await
                .map_err(|_| timeout_error())?
                .ok();
        } else if matches!(
            input.try_send(request),
            Err(mpsc::error::TrySendError::Full(_))
        ) {
            return Err(too_many_requests().into());
        }

        let response = match tokio::time::timeout_at(deadline, &mut receive).await {
            Ok(result) => result,
            Err(_) => {
                let uncertain = self.calls.lock().unwrap().withdraw(id);
                // Eine am Ablaufzeitpunkt bereits abgeholte Antwort bleibt verbindlich.
                if let Ok(reply) = receive.try_recv() {
                    return reply;
                }
                return Err(if uncertain {
                    uncertain_result()
                } else {
                    timeout_error()
                }
                .into());
            }
        };
        response.map_err(|_| {
            text(
                "Die Verbindung zur Medienverarbeitung wurde unterbrochen.",
                "The connection to the media engine was interrupted.",
            )
        })?
    }
}

fn uncertain_result() -> &'static str {
    text(
        "Der Ausgang einer Änderung ist unklar. Bitte vor weiteren Änderungen prüfen und die App neu starten.",
        "The outcome of a change is unknown. Check it before making further changes, then restart the app.",
    )
}

fn too_many_requests() -> &'static str {
    text(
        "Zu viele laufende Anfragen",
        "Too many requests in progress",
    )
}

#[derive(Debug, PartialEq, Eq)]
enum ConnectionEnd {
    ProcessExit,
    OutputClosed,
    InvalidResponse,
    OversizedResponse,
    ReadError,
    WriteError,
    WriteTimeout,
    InputClosed,
}

async fn write_requests(
    mut writer: impl AsyncWrite + Unpin,
    mut receiver: mpsc::Receiver<Request>,
    engine: &Weak<Engine>,
) -> ConnectionEnd {
    while let Some(request) = receiver.recv().await {
        if !engine
            .upgrade()
            .is_some_and(|engine| engine.start_request(request.id))
        {
            continue;
        }
        // Nur dieser Task schreibt. Der Aufrufer kann ablaufen oder wegfallen,
        // ohne dass die nächste Anfrage an eine unvollständige Zeile gehängt wird.
        match tokio::time::timeout(REQUEST_TIMEOUT, writer.write_all(&request.bytes)).await {
            Ok(Ok(())) => (),
            Ok(Err(_)) => return ConnectionEnd::WriteError,
            Err(_) => return ConnectionEnd::WriteTimeout,
        }
    }
    ConnectionEnd::InputClosed
}

async fn read_responses(
    mut reader: impl AsyncRead + Unpin,
    engine: &Weak<Engine>,
) -> ConnectionEnd {
    let mut chunk = [0u8; 65536];
    let mut line = Vec::new();
    loop {
        let count = match reader.read(&mut chunk).await {
            Ok(0) if line.is_empty() => return ConnectionEnd::OutputClosed,
            Ok(0) => return ConnectionEnd::InvalidResponse,
            Ok(count) => count,
            Err(_) => return ConnectionEnd::ReadError,
        };
        for part in chunk[..count].split_inclusive(|byte| *byte == b'\n') {
            let payload = part.strip_suffix(b"\n").unwrap_or(part);
            if line.len() + payload.len() > MAXIMUM_MESSAGE {
                return ConnectionEnd::OversizedResponse;
            }
            line.extend_from_slice(payload);
            if part.len() == payload.len() {
                continue;
            }
            let Ok(response) = serde_json::from_slice::<Value>(&line) else {
                return ConnectionEnd::InvalidResponse;
            };
            line.clear();
            let Some(id) = response.get("id").and_then(Value::as_u64) else {
                return ConnectionEnd::InvalidResponse;
            };
            let Some(engine) = engine.upgrade() else {
                return ConnectionEnd::InputClosed;
            };
            let result = if response.get("error").is_some_and(|value| !value.is_null()) {
                Err(response["error"]["message"]
                    .as_str()
                    .unwrap_or(text(
                        "Medienoperation fehlgeschlagen",
                        "Media operation failed",
                    ))
                    .to_owned())
            } else {
                Ok(response.get("result").cloned().unwrap_or(Value::Null))
            };
            if let Some(pending) = engine.calls.lock().unwrap().pending.remove(&id) {
                let _ = pending.reply.send(result);
            };
        }
    }
}

#[derive(Clone, Copy)]
enum LoaderError {
    TagLib,
    Qpdf,
    Swift,
    Other,
}

#[derive(Default)]
struct Diagnostics {
    loader_error: Option<LoaderError>,
    swift_crash: bool,
}

impl Diagnostics {
    fn observe(&mut self, line: &[u8]) {
        let contains = |part: &[u8]| line.windows(part.len()).any(|window| window == part);
        if contains(b"error while loading shared libraries:") {
            self.loader_error = Some(if contains(b"libtag.so") || contains(b"libtag_c.so") {
                LoaderError::TagLib
            } else if contains(b"libqpdf.so") {
                LoaderError::Qpdf
            } else if contains(b"libswift") {
                LoaderError::Swift
            } else {
                LoaderError::Other
            });
        } else if contains(b"symbol lookup error:")
            || (contains(b": version ") && contains(b" not found (required by "))
        {
            self.loader_error = Some(LoaderError::Other);
        }
        self.swift_crash |= contains(b"Program crashed:") || contains(b"Fatal error:");
    }
}

async fn drain_stderr(mut reader: impl AsyncRead + Unpin, diagnostics: Arc<Mutex<Diagnostics>>) {
    let mut chunk = [0u8; 4096];
    let mut prefix = Vec::with_capacity(512);
    while let Ok(count) = reader.read(&mut chunk).await {
        if count == 0 {
            break;
        }
        for part in chunk[..count].split_inclusive(|byte| *byte == b'\n') {
            let to_copy = (512 - prefix.len()).min(part.len());
            prefix.extend_from_slice(&part[..to_copy]);
            if part.last() == Some(&b'\n') {
                diagnostics.lock().unwrap().observe(&prefix);
                prefix.clear();
            }
        }
    }
    if !prefix.is_empty() {
        diagnostics.lock().unwrap().observe(&prefix);
    }
}

async fn run_connection(
    engine: Weak<Engine>,
    mut child: Child,
    writer: impl AsyncWrite + Unpin,
    reader: impl AsyncRead + Unpin,
    stderr: impl AsyncRead + Unpin + Send + 'static,
    receiver: mpsc::Receiver<Request>,
) {
    let diagnostics = Arc::new(Mutex::new(Diagnostics::default()));
    let mut stderr_task = tauri::async_runtime::spawn(drain_stderr(stderr, diagnostics.clone()));
    let (end, status) = {
        let responses = read_responses(reader, &engine);
        tokio::pin!(responses);
        tokio::select! {
            end = &mut responses => (end, None),
            end = write_requests(writer, receiver, &engine) => (end, None),
            status = child.wait() => {
                // Antworten können nach dem Exit noch vollständig in der Pipe liegen.
                let end = tokio::time::timeout(DIAGNOSTIC_GRACE, &mut responses)
                    .await
                    .unwrap_or(ConnectionEnd::ProcessExit);
                (end, status.ok())
            }
        }
    };
    let status = match status {
        Some(status) => Some(status),
        None => tokio::time::timeout(DIAGNOSTIC_GRACE, child.wait())
            .await
            .ok()
            .and_then(Result::ok),
    };
    let _ = tokio::time::timeout(DIAGNOSTIC_GRACE, &mut stderr_task).await;
    if let Some(engine) = engine.upgrade() {
        engine.fail(connection_error(end, status, &diagnostics.lock().unwrap()));
    }
    if status.is_none() {
        // EOF lässt den Swift-Worker angenommene Dateioperationen zu Ende
        // führen. Ein dauerhaft hängender Prozess bleibt dabei begrenzt.
        if tokio::time::timeout(REQUEST_TIMEOUT, child.wait())
            .await
            .is_err()
        {
            let _ = child.kill().await;
        }
    }
    stderr_task.abort();
}

fn connection_error(
    end: ConnectionEnd,
    status: Option<ExitStatus>,
    diagnostics: &Diagnostics,
) -> String {
    let summary = match end {
        ConnectionEnd::InvalidResponse => text(
            "Die Medienverarbeitung hat eine ungültige Antwort gesendet.",
            "The media engine sent an invalid response.",
        ),
        ConnectionEnd::OversizedResponse => text(
            "Die Antwort der Medienverarbeitung ist zu groß.",
            "The media engine response is too large.",
        ),
        ConnectionEnd::WriteError | ConnectionEnd::WriteTimeout => text(
            "Die Anfrage konnte nicht vollständig an die Medienverarbeitung übertragen werden.",
            "The request could not be fully sent to the media engine.",
        ),
        _ => text(
            "Die Verbindung zur Medienverarbeitung wurde unterbrochen.",
            "The connection to the media engine was interrupted.",
        ),
    };
    let detail = match diagnostics.loader_error {
        Some(LoaderError::TagLib) => text("TagLib fehlt.", "TagLib is missing."),
        Some(LoaderError::Qpdf) => text("QPDF fehlt.", "QPDF is missing."),
        Some(LoaderError::Swift) => {
            text("Die Swift-Laufzeit fehlt.", "The Swift runtime is missing.")
        }
        Some(LoaderError::Other) => text(
            "Eine Laufzeitbibliothek fehlt oder ist inkompatibel.",
            "A runtime library is missing or incompatible.",
        ),
        None if diagnostics.swift_crash => text(
            "Die Swift-Laufzeit meldet einen Absturz.",
            "The Swift runtime reported a crash.",
        ),
        None => "",
    };
    let mut message = summary.to_owned();
    if !detail.is_empty() {
        message.push(' ');
        message.push_str(detail);
    }
    if let Some(signal) = status.and_then(|status| status.signal()) {
        message.push_str(&format!(" ({} {signal})", text("Signal", "signal")));
    } else if let Some(code) = status.and_then(|status| status.code()) {
        message.push_str(&format!(" ({} {code})", text("Exitcode", "exit code")));
    }
    message.push(' ');
    message.push_str(text("Bitte die App neu starten.", "Restart the app."));
    message
}

#[cfg(test)]
pub(crate) fn test_worker(script: &str) -> (tempfile::TempDir, Arc<Engine>) {
    use std::{fs, os::unix::fs::PermissionsExt};

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("test-worker");
    fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    (directory, Engine::new(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stderr_classifies_start_failure_without_exposing_its_contents() {
        tauri::async_runtime::block_on(async {
            let (_directory, engine) = test_worker(
                r#"printf '%80000s\n' 'private-media-name' >&2
printf '%s\n' 'private-engine-path: error while loading shared libraries: libtag.so.2: cannot open shared object file' >&2
exit 127"#,
            );
            let error = engine.call("main", "hello", json!({})).await.unwrap_err();
            assert!(error.contains(text("TagLib fehlt.", "TagLib is missing.")));
            assert!(error.contains("127"));
            assert!(!error.contains("private-"));
            assert!(engine.calls.lock().unwrap().pending.is_empty());
        });
    }

    #[test]
    fn read_timeout_keeps_worker_available_and_unknown_write_blocks_mutations() {
        tauri::async_runtime::block_on(async {
            let (_directory, engine) = test_worker(
                r#"while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"info"'* | *'"method":"save"'*) late=$id; continue ;;
  esac
  if [ -n "$late" ]; then printf '{"id":%s,"result":null}\n' "$late"; late=; fi
  printf '{"id":%s,"result":true}\n' "$id"
done"#,
            );
            let timeout = Duration::from_millis(250);
            let error = engine
                .call_inner("main", "info", json!({}), timeout, false)
                .await
                .unwrap_err();
            assert!(error.contains(text("nicht rechtzeitig", "did not respond in time")));
            assert_eq!(engine.call("main", "state", json!({})).await.unwrap(), true);
            let error = engine
                .call_inner("main", "save", json!({}), timeout, false)
                .await
                .unwrap_err();
            assert_eq!(error, uncertain_result());
            assert_eq!(engine.call("main", "state", json!({})).await.unwrap(), true);
            assert_eq!(
                engine.call("main", "cancel", json!({})).await.unwrap(),
                true
            );
            assert_eq!(engine.call("main", "close", json!({})).await.unwrap(), true);
            assert_eq!(
                engine.call("main", "saveAll", json!({})).await.unwrap_err(),
                uncertain_result()
            );
            assert!(engine.calls.lock().unwrap().pending.is_empty());
        });
    }

    #[test]
    fn missing_update_acknowledgement_blocks_mutations_but_allows_closing() {
        tauri::async_runtime::block_on(async {
            for updating in [true, false] {
                let (_directory, engine) = test_worker(
                    r#"while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"beginUpdate"'* | *'"method":"endUpdate"'*) continue ;;
  esac
  printf '{"id":%s,"result":true}\n' "$id"
done"#,
                );
                let result = engine
                    .set_updating_with_timeout("main", updating, Duration::from_millis(250))
                    .await;
                assert!(result.is_err());
                assert!(engine.recovery_required());
                assert!(engine.call("main", "save", json!({})).await.is_err());
                assert_eq!(engine.call("main", "close", json!({})).await.unwrap(), true);
            }
        });
    }

    #[test]
    fn dropping_a_caller_mid_frame_preserves_framing_for_next_request() {
        tauri::async_runtime::block_on(async {
            let engine = Engine::new(PathBuf::new());
            let weak = Arc::downgrade(&engine);
            let (input, mut peer) = tokio::io::duplex(4);
            let (queue, receiver) = mpsc::channel(2);
            let writer =
                tauri::async_runtime::spawn(
                    async move { write_requests(input, receiver, &weak).await },
                );
            let (send, _receive) = oneshot::channel();
            let first = engine.register(1, Effect::Read, send, false).unwrap();
            queue
                .send(Request {
                    id: 1,
                    bytes: b"first frame\n".to_vec(),
                })
                .await
                .unwrap();
            let mut prefix = [0; 3];
            peer.read_exact(&mut prefix).await.unwrap();
            assert_eq!(&prefix, b"fir");
            drop(first);
            assert!(engine.calls.lock().unwrap().pending.is_empty());

            let (send, _receive) = oneshot::channel();
            let _second = engine.register(2, Effect::Read, send, false).unwrap();
            queue
                .send(Request {
                    id: 2,
                    bytes: b"second frame\n".to_vec(),
                })
                .await
                .unwrap();
            drop(queue);
            let mut rest = Vec::new();
            peer.read_to_end(&mut rest).await.unwrap();
            assert_eq!(rest, b"st frame\nsecond frame\n");
            assert_eq!(writer.await.unwrap(), ConnectionEnd::InputClosed);
        });
    }
}
