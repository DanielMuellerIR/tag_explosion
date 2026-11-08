use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, Command},
    sync::{oneshot, Mutex},
};

const MAXIMUM_MESSAGE: usize = 24 * 1024 * 1024;
type Reply = oneshot::Sender<Result<Value, String>>;

pub struct Engine {
    sequence: AtomicU64,
    initialization: Mutex<()>,
    input: Mutex<Option<ChildStdin>>,
    child: Mutex<Option<Child>>,
    pending: Mutex<HashMap<u64, Reply>>,
    failed: AtomicBool,
    executable: PathBuf,
}

impl Engine {
    pub fn new(executable: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            sequence: AtomicU64::new(1),
            initialization: Mutex::new(()),
            input: Mutex::new(None),
            child: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            failed: AtomicBool::new(false),
            executable,
        })
    }

    async fn start(self: &Arc<Self>) -> Result<(), String> {
        let _initializing = self.initialization.lock().await;
        if self.failed.load(Ordering::Acquire) {
            return Err("Die Verbindung zur Medienverarbeitung wurde unterbrochen. Bitte die App neu starten; einen unbekannten Speicherausgang vorher prüfen.".into());
        }
        if self.input.lock().await.is_some() {
            return Ok(());
        }
        let mut command = Command::new(&self.executable);
        command
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
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
        let mut child = command.spawn().map_err(|_| {
            "Die mitgelieferte Medienverarbeitung konnte nicht gestartet werden".to_string()
        })?;
        let mut output = child.stdout.take().ok_or("Engine stdout fehlt")?;
        *self.input.lock().await = child.stdin.take();
        *self.child.lock().await = Some(child);
        let weak = Arc::downgrade(self);
        tauri::async_runtime::spawn(async move {
            let mut chunk = [0u8; 65536];
            let mut line = Vec::new();
            'reading: loop {
                let count = match output.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(count) => count,
                };
                for part in chunk[..count].split_inclusive(|byte| *byte == b'\n') {
                    if line.len() + part.len() > MAXIMUM_MESSAGE {
                        break 'reading;
                    }
                    line.extend_from_slice(part);
                    if part.last() != Some(&b'\n') {
                        continue;
                    }
                    let response: Value = match serde_json::from_slice(&line) {
                        Ok(value) => value,
                        Err(_) => break 'reading,
                    };
                    line.clear();
                    let Some(engine) = weak.upgrade() else {
                        return;
                    };
                    let Some(id) = response.get("id").and_then(Value::as_u64) else {
                        break 'reading;
                    };
                    let reply = { engine.pending.lock().await.remove(&id) };
                    if let Some(reply) = reply {
                        let result = if response.get("error").is_some_and(|value| !value.is_null())
                        {
                            Err(response["error"]["message"]
                                .as_str()
                                .unwrap_or("Medienoperation fehlgeschlagen")
                                .to_owned())
                        } else {
                            Ok(response.get("result").cloned().unwrap_or(Value::Null))
                        };
                        let _ = reply.send(result);
                    }
                }
            }
            if let Some(engine) = weak.upgrade() {
                engine.failed.store(true, Ordering::Release);
                for (_, reply) in engine.pending.lock().await.drain() {
                    let _ = reply.send(Err("Die Medienverarbeitung wurde unterbrochen. Ein laufender Speichervorgang muss vor einer Wiederholung geprüft werden.".into()));
                }
            }
        });
        Ok(())
    }

    pub async fn call(
        self: &Arc<Self>,
        session: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, String> {
        self.start().await?;
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let mut request = serde_json::to_vec(
            &json!({"id": id, "session": session, "method": method, "params": params}),
        )
        .map_err(|_| "Ungültige Anfrage")?;
        if request.len() > MAXIMUM_MESSAGE {
            return Err("Die Anfrage ist zu groß".into());
        }
        request.push(b'\n');
        let (send, receive) = oneshot::channel();
        {
            let mut pending = self.pending.lock().await;
            if pending.len() >= 64 {
                return Err("Zu viele laufende Anfragen".into());
            }
            pending.insert(id, send);
        }
        let write_result = {
            let mut input = self.input.lock().await;
            match input.as_mut() {
                Some(input) => input.write_all(&request).await,
                None => return Err("Engine stdin fehlt".into()),
            }
        };
        if write_result.is_err() {
            self.pending.lock().await.remove(&id);
            return Err("Die Anfrage konnte nicht übertragen werden".into());
        }
        match tokio::time::timeout(Duration::from_secs(600), receive).await {
            Ok(Ok(reply)) => reply,
            _ => {
                self.failed.store(true, Ordering::Release);
                self.pending.lock().await.remove(&id);
                Err("Die Antwort der Medienverarbeitung fehlt. Einen möglichen Speicherausgang vor einer Wiederholung prüfen.".into())
            }
        }
    }
}
