use crate::{engine::Engine, localization::text};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{Emitter, State, WebviewWindow};
use tauri_plugin_updater::{Update, UpdaterExt};

const FEED: &str =
    "https://github.com/DanielMuellerIR/tag_explosion/releases/latest/download/linux-updates.json";
#[derive(Clone, Default)]
pub struct Updates {
    inner: Arc<Mutex<UpdateState>>,
}
#[derive(Default)]
struct UpdateState {
    pending: Option<Update>,
    owner: Option<String>,
    busy: bool,
}

struct Active(Updates);
impl Drop for Active {
    fn drop(&mut self) {
        if let Ok(mut state) = self.0.inner.lock() {
            state.busy = false;
        }
    }
}
fn update_state_unavailable() -> &'static str {
    text(
        "Updatezustand nicht verfügbar",
        "Update state is unavailable",
    )
}

fn reserve(state: &Updates) -> Result<Active, String> {
    let mut inner = state.inner.lock().map_err(|_| update_state_unavailable())?;
    if inner.busy {
        return Err(text(
            "Eine Updateaktion läuft bereits",
            "An update operation is already running",
        )
        .into());
    }
    inner.busy = true;
    Ok(Active(state.clone()))
}

#[tauri::command]
pub async fn check_update(
    window: WebviewWindow,
    updates: State<'_, Updates>,
) -> Result<Value, String> {
    let _active = reserve(&updates)?;
    #[cfg(debug_assertions)]
    let feed = std::env::var("TAGX_TEST_UPDATE_FEED")
        .ok()
        .filter(|value| value.starts_with("http://127.0.0.1:"))
        .unwrap_or_else(|| FEED.into());
    #[cfg(not(debug_assertions))]
    let feed = FEED;
    let updater = window
        .updater_builder()
        .target("linux-x86_64-appimage")
        .timeout(Duration::from_secs(30))
        .endpoints(vec![feed.parse().map_err(|_| {
            text("Ungültiger Updatekanal", "Invalid update channel")
        })?])
        .map_err(|_| text("Ungültiger Updatekanal", "Invalid update channel"))?
        .build()
        .map_err(|_| {
            text(
                "Updatekanal ist nicht konfiguriert",
                "The update channel is not configured",
            )
        })?;
    let found = updater.check().await.map_err(|_| text(
        "Der Linux-Updatekanal ist derzeit nicht erreichbar. Internetverbindung und veröffentlichten Linux-Release prüfen.",
        "The Linux update channel is unavailable. Check your internet connection and the published Linux release.",
    ))?;
    let response = found
        .as_ref()
        .map(|update| json!({"available": true, "version": update.version, "notes": update.body}))
        .unwrap_or(json!({"available": false}));
    let mut inner = updates
        .inner
        .lock()
        .map_err(|_| update_state_unavailable())?;
    inner.pending = found;
    inner.owner = Some(window.label().into());
    Ok(response)
}

#[tauri::command]
pub async fn install_update(
    window: WebviewWindow,
    updates: State<'_, Updates>,
    desktop: State<'_, super::Desktop>,
    version: String,
) -> Result<(), String> {
    let active = reserve(&updates)?;
    // Der Worker verweigert den Paketwechsel während Dateioperationen. Seine
    // laufende Sitzung und der alte AppImage-Mount bleiben bis zum Beenden erhalten.
    let permitted = desktop
        .engine
        .call(window.label(), "prepareUpdate", json!({}))
        .await?;
    if permitted != true {
        return Err(text(
            "Vor der Aktualisierung laufende Dateioperationen abschließen",
            "Finish ongoing file operations before updating",
        )
        .into());
    }
    let update = {
        let mut inner = updates
            .inner
            .lock()
            .map_err(|_| update_state_unavailable())?;
        if inner.owner.as_deref() != Some(window.label())
            || inner.pending.as_ref().map(|value| value.version.as_str()) != Some(version.as_str())
        {
            return Err(text(
                "Die bestätigte Updateversion stimmt nicht mehr mit der geprüften Version überein",
                "The confirmed version no longer matches the checked version",
            )
            .into());
        }
        inner.owner = None;
        inner.pending.take().ok_or(text(
            "Update bitte erneut prüfen",
            "Check for updates again",
        ))?
    };
    let current = std::env::var_os("APPIMAGE").map(PathBuf::from).ok_or(text(
        "Nur ein benutzereigen installiertes AppImage kann sich selbst aktualisieren",
        "Self-updates require an AppImage installed and owned by the current user",
    ))?;
    let progress = window.clone();
    let mut downloaded = 0_u64;
    // Tauri prüft die Herausgebersignatur, bevor bytes zurückgegeben wird.
    let bytes = update
        .download(
            move |count, total| {
                downloaded = downloaded.saturating_add(count as u64);
                let _ = progress.emit(
                    "update-progress",
                    json!({"downloaded": downloaded, "total": total}),
                );
            },
            || {},
        )
        .await
        .map_err(|_| text(
            "Download oder Signaturprüfung fehlgeschlagen. Die installierte Version bleibt erhalten.",
            "The download or signature verification failed. The installed version is unchanged.",
        ))?;
    let bytes = tauri::async_runtime::spawn_blocking(move || {
        inspect_package(&bytes, &version)?;
        Ok::<_, String>(bytes)
    })
    .await
    .map_err(|_| {
        text(
            "Paketprüfung unterbrochen",
            "Package verification interrupted",
        )
    })??;

    install_in_background(
        active,
        desktop.engine.clone(),
        window.label().into(),
        move || replace_appimage(&current, &bytes),
    )
    .await
    .map_err(|_| installation_interrupted())?
}

fn installation_interrupted() -> &'static str {
    text("Installation unterbrochen", "Installation interrupted")
}

fn install_in_background(
    active: Active,
    engine: Arc<Engine>,
    session: String,
    install: impl FnOnce() -> Result<(), String> + Send + 'static,
) -> tauri::async_runtime::JoinHandle<Result<(), String>> {
    // Das Wegfallen der Webview-Anfrage darf den Installer nicht abbrechen.
    // Erst nach dem Paketwechsel wird der Worker für Änderungen freigegeben.
    tauri::async_runtime::spawn(async move {
        let _active = active;
        if !engine.set_updating(&session, true).await? {
            return Err(text(
                "Inzwischen läuft eine Dateioperation. Update nach deren Abschluss erneut prüfen.",
                "A file operation has started. Check for updates again after it finishes.",
            )
            .into());
        }
        let result = tauri::async_runtime::spawn_blocking(install).await;
        let released = engine.set_updating(&session, false).await;
        result.map_err(|_| installation_interrupted())??;
        released.map_err(|_| text(
            "Update installiert. Die Medienverarbeitung hat die Freigabe nicht bestätigt. Bitte die App neu starten.",
            "Update installed. The media engine did not confirm release. Restart the app.",
        ).to_owned())?;
        Ok(())
    })
}

fn inspect_package(bytes: &[u8], expected_version: &str) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    if !bytes.starts_with(b"\x7fELF") || bytes.get(8..11) != Some(&b"AI\x02"[..]) {
        return Err(text(
            "Der signierte Download ist kein AppImage",
            "The signed download is not an AppImage",
        )
        .into());
    }
    let prepare_error = text(
        "Paketprüfung konnte nicht vorbereitet werden",
        "Could not prepare package verification",
    );
    let temporary = tempfile::tempdir().map_err(|_| prepare_error)?;
    let image = temporary.path().join("candidate.AppImage");
    fs::write(&image, bytes).map_err(|_| prepare_error)?;
    fs::set_permissions(&image, fs::Permissions::from_mode(0o700)).map_err(|_| prepare_error)?;
    // Ausgeführt wird ausschließlich die bereits signaturgeprüfte Runtime.
    // Extraktion braucht weder FUSE noch eine sichtbare GUI.
    let mut child = std::process::Command::new(&image)
        .arg("--appimage-extract")
        .arg("usr/share/tag-explosion/package.json")
        .current_dir(temporary.path())
        .env_remove("APPIMAGE")
        .env_remove("APPDIR")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| {
            text(
                "Signiertes Paket konnte nicht geprüft werden",
                "Could not verify the signed package",
            )
        })?;
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => {
                return Err(text(
                    "Signiertes Paket konnte nicht entpackt werden",
                    "Could not extract the signed package",
                )
                .into())
            }
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(text(
                    "Paketprüfung wurde abgebrochen",
                    "Package verification was stopped",
                )
                .into());
            }
        }
    }
    let manifest: Value = serde_json::from_slice(
        &fs::read(
            temporary
                .path()
                .join("squashfs-root/usr/share/tag-explosion/package.json"),
        )
        .map_err(|_| {
            text(
                "Linux-Paketmanifest fehlt",
                "The Linux package manifest is missing",
            )
        })?,
    )
    .map_err(|_| {
        text(
            "Linux-Paketmanifest ist ungültig",
            "The Linux package manifest is invalid",
        )
    })?;
    if manifest["version"] != expected_version
        || manifest["os"] != "linux"
        || manifest["architecture"] != "x86_64"
        || manifest["identifier"] != "io.github.danielmuellerir.tagexplosion"
    {
        return Err(text(
            "Paketversion, Anwendung oder Zielplattform passen nicht zum bestätigten Update",
            "The package version, application, or platform does not match the confirmed update",
        )
        .into());
    }
    Ok(())
}

fn sync_directory(path: &Path) -> Result<(), String> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| {
            text(
                "Installationsverzeichnis konnte nicht gesichert werden",
                "Could not sync the installation directory",
            )
            .into()
        })
}

pub fn replace_appimage(current: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let metadata = fs::symlink_metadata(current).map_err(|_| {
        text(
            "Installiertes AppImage nicht gefunden",
            "The installed AppImage was not found",
        )
    })?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || !bytes.starts_with(b"\x7fELF")
        || bytes.get(8..11) != Some(&b"AI\x02"[..])
    {
        return Err(text(
            "Installation benötigt eine eigene reguläre AppImage-Datei und ein gültiges AppImage-Paket",
            "Installation requires an owned, regular AppImage file and a valid AppImage package",
        ).into());
    }
    let directory = current.parent().ok_or(text(
        "Installationsverzeichnis fehlt",
        "The installation directory is missing",
    ))?;
    let previous = directory.join("TagExplosion.previous.AppImage");
    if previous == current
        || fs::symlink_metadata(&previous)
            .is_ok_and(|value| !value.is_file() || value.uid() != metadata.uid())
    {
        return Err(text(
            "Der Rückfallpfad gehört nicht zu dieser Installation",
            "The rollback path does not belong to this installation",
        )
        .into());
    }

    // Beide Umbenennungen bleiben auf demselben Dateisystem. TempDir räumt
    // ausschließlich dieses für den Versuch angelegte Verzeichnis auf.
    let prepare_error = text(
        "Update konnte nicht im Installationsverzeichnis vorbereitet werden",
        "Could not stage the update in the installation directory",
    );
    let temporary = tempfile::Builder::new()
        .prefix(".tagx-update-")
        .tempdir_in(directory)
        .map_err(|_| prepare_error)?;
    let staged = temporary.path().join("next.AppImage");
    let backup = temporary.path().join("previous.AppImage");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o700)
        .open(&staged)
        .map_err(|_| prepare_error)?;
    output.write_all(bytes).map_err(|_| {
        text(
            "Update konnte nicht vollständig geschrieben werden",
            "Could not write the complete update",
        )
    })?;
    output
        .set_permissions(fs::Permissions::from_mode(0o755))
        .map_err(|_| {
            text(
                "Update konnte nicht ausführbar gemacht werden",
                "Could not make the update executable",
            )
        })?;
    output.sync_all().map_err(|_| {
        text(
            "Update konnte nicht gesichert werden",
            "Could not sync the update",
        )
    })?;
    // Ein Hardlink erhält exakt den laufenden Stand. Auf Dateisystemen ohne
    // Hardlinks wird die vorige Version im selben privaten Verzeichnis kopiert.
    if fs::hard_link(current, &backup).is_err() {
        let mut source = File::open(current).map_err(|_| {
            text(
                "Vorige Version nicht lesbar",
                "Could not read the previous version",
            )
        })?;
        let mut target = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(&backup)
            .map_err(|_| {
                text(
                    "Vorige Version konnte nicht gesichert werden",
                    "Could not back up the previous version",
                )
            })?;
        std::io::copy(&mut source, &mut target)
            .and_then(|_| target.sync_all())
            .map_err(|_| {
                text(
                    "Sicherung der vorigen Version fehlgeschlagen",
                    "Backing up the previous version failed",
                )
            })?;
    }
    sync_directory(temporary.path())?;
    fs::rename(&backup, &previous).map_err(|_| {
        text(
            "Vorige Version konnte nicht veröffentlicht werden",
            "Could not publish the previous version",
        )
    })?;
    sync_directory(directory)?;
    fs::rename(&staged, current).map_err(|_| {
        text(
            "Update konnte nicht atomar eingesetzt werden",
            "Could not replace the AppImage atomically with the update",
        )
    })?;
    sync_directory(directory)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_preserves_the_previous_package_and_rejects_invalid_images() {
        let directory = tempfile::tempdir().unwrap();
        let current = directory.path().join("TagExplosion.AppImage");
        let mut old = b"\x7fELF\x02\x01\x01\x00AI\x02".to_vec();
        old.extend_from_slice(b"old");
        fs::write(&current, &old).unwrap();
        assert!(replace_appimage(&current, b"corrupt").is_err());
        assert_eq!(fs::read(&current).unwrap(), old);
        let mut next = old.clone();
        next.extend_from_slice(b"next");
        replace_appimage(&current, &next).unwrap();
        assert_eq!(fs::read(&current).unwrap(), next);
        assert_eq!(
            fs::read(directory.path().join("TagExplosion.previous.AppImage")).unwrap(),
            old
        );
    }

    #[test]
    fn replacement_leaves_existing_temporary_paths_alone() {
        let directory = tempfile::tempdir().unwrap();
        let current = directory.path().join("TagExplosion.AppImage");
        let image = b"\x7fELF\x02\x01\x01\x00AI\x02";
        fs::write(&current, image).unwrap();
        let legacy = directory
            .path()
            .join(format!(".tagx-update-{}.new", std::process::id()));
        fs::write(&legacy, b"unrelated file").unwrap();
        replace_appimage(&current, image).unwrap();
        assert_eq!(fs::read(&legacy).unwrap(), b"unrelated file");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 3);
    }

    #[test]
    fn cancellation_keeps_update_reserved_until_the_worker_is_released() {
        tauri::async_runtime::block_on(async {
            let (_directory, engine) = crate::engine::test_worker(
                r#"updating=false
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"beginUpdate"'*) updating=true; result=true ;;
    *'"method":"endUpdate"'*) updating=false; result=true ;;
    *) result=$updating ;;
  esac
  printf '{"id":%s,"result":%s}\n' "$id" "$result"
done"#,
            );
            let updates = Updates::default();
            let (started, entered) = tokio::sync::oneshot::channel();
            let (finish, finished) = tokio::sync::oneshot::channel();
            let install = install_in_background(
                reserve(&updates).unwrap(),
                engine.clone(),
                "main".into(),
                move || {
                    started.send(()).unwrap();
                    finished.blocking_recv().unwrap();
                    Err("synthetic installation failure".into())
                },
            );
            tokio::time::timeout(Duration::from_secs(3), entered)
                .await
                .unwrap()
                .unwrap();
            drop(install);
            assert!(reserve(&updates).is_err());
            assert_eq!(engine.call("main", "state", json!({})).await.unwrap(), true);
            finish.send(()).unwrap();
            tokio::time::timeout(Duration::from_secs(3), async {
                while reserve(&updates).is_err() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap();
            assert_eq!(
                engine.call("main", "state", json!({})).await.unwrap(),
                false
            );
        });
    }
}
