use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
};
use tauri::{Emitter, State, WebviewWindow};
use tauri_plugin_updater::{Update, UpdaterExt};

const FEED: &str =
    "https://github.com/DanielMuellerIR/tag_explosion/releases/latest/download/linux-updates.json";
pub struct Updates {
    inner: Mutex<UpdateState>,
}
#[derive(Default)]
struct UpdateState {
    pending: Option<Update>,
    owner: Option<String>,
    busy: bool,
}
impl Default for Updates {
    fn default() -> Self {
        Self {
            inner: Mutex::new(UpdateState::default()),
        }
    }
}

struct Active<'a>(&'a Updates);
impl Drop for Active<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.0.inner.lock() {
            state.busy = false;
        }
    }
}
fn reserve(state: &Updates) -> Result<Active<'_>, String> {
    let mut inner = state
        .inner
        .lock()
        .map_err(|_| "Updatezustand nicht verfügbar")?;
    if inner.busy {
        return Err("Eine Updateaktion läuft bereits".into());
    }
    inner.busy = true;
    Ok(Active(state))
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
        .endpoints(vec![feed.parse().map_err(|_| "Ungültiger Updatekanal")?])
        .map_err(|_| "Ungültiger Updatekanal")?
        .build()
        .map_err(|_| "Updatekanal ist nicht konfiguriert")?;
    let found = updater.check().await.map_err(|_| "Der Linux-Updatekanal ist derzeit nicht erreichbar. Internetverbindung und veröffentlichten Linux-Release prüfen.")?;
    let response = found
        .as_ref()
        .map(|update| json!({"available": true, "version": update.version, "notes": update.body}))
        .unwrap_or(json!({"available": false}));
    let mut inner = updates
        .inner
        .lock()
        .map_err(|_| "Updatezustand nicht verfügbar")?;
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
    let _active = reserve(&updates)?;
    // Der Worker verweigert den Paketwechsel während Dateioperationen. Seine
    // laufende Sitzung und der alte AppImage-Mount bleiben bis zum Beenden erhalten.
    let permitted = desktop
        .engine
        .call(window.label(), "prepareUpdate", json!({}))
        .await?;
    if permitted != true {
        return Err("Vor der Aktualisierung laufende Dateioperationen abschließen".into());
    }
    let update = {
        let mut inner = updates
            .inner
            .lock()
            .map_err(|_| "Updatezustand nicht verfügbar")?;
        if inner.owner.as_deref() != Some(window.label())
            || inner.pending.as_ref().map(|value| value.version.as_str()) != Some(version.as_str())
        {
            return Err(
                "Die bestätigte Updateversion stimmt nicht mehr mit der geprüften Version überein"
                    .into(),
            );
        }
        inner.owner = None;
        inner.pending.take().ok_or("Update bitte erneut prüfen")?
    };
    let current = std::env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .ok_or("Nur ein benutzereigen installiertes AppImage kann sich selbst aktualisieren")?;
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
        .map_err(|_| {
            "Download oder Signaturprüfung fehlgeschlagen; die installierte Version bleibt erhalten"
        })?;
    let expected_version = version.clone();
    let inspected = bytes.clone();
    tauri::async_runtime::spawn_blocking(move || inspect_package(&inspected, &expected_version))
        .await
        .map_err(|_| "Paketprüfung unterbrochen")??;
    if desktop
        .engine
        .call(window.label(), "beginUpdate", json!({}))
        .await?
        != true
    {
        return Err(
            "Inzwischen läuft eine Dateioperation; Update nach deren Abschluss erneut prüfen"
                .into(),
        );
    }
    let result =
        tauri::async_runtime::spawn_blocking(move || replace_appimage(&current, &bytes)).await;
    let _ = desktop
        .engine
        .call(window.label(), "endUpdate", json!({}))
        .await;
    result.map_err(|_| "Installation unterbrochen")?
}

fn inspect_package(bytes: &[u8], expected_version: &str) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    if !bytes.starts_with(b"\x7fELF") || bytes.get(8..11) != Some(&b"AI\x02"[..]) {
        return Err("Der signierte Download ist kein AppImage".into());
    }
    let temporary =
        tempfile::tempdir().map_err(|_| "Paketprüfung konnte nicht vorbereitet werden")?;
    let image = temporary.path().join("candidate.AppImage");
    fs::write(&image, bytes).map_err(|_| "Paketprüfung konnte nicht vorbereitet werden")?;
    fs::set_permissions(&image, fs::Permissions::from_mode(0o700))
        .map_err(|_| "Paketprüfung konnte nicht vorbereitet werden")?;
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
        .map_err(|_| "Signiertes Paket konnte nicht geprüft werden")?;
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return Err("Signiertes Paket konnte nicht entpackt werden".into()),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Paketprüfung wurde abgebrochen".into());
            }
        }
    }
    let manifest: Value = serde_json::from_slice(
        &fs::read(
            temporary
                .path()
                .join("squashfs-root/usr/share/tag-explosion/package.json"),
        )
        .map_err(|_| "Linux-Paketmanifest fehlt")?,
    )
    .map_err(|_| "Linux-Paketmanifest ist ungültig")?;
    if manifest["version"] != expected_version
        || manifest["os"] != "linux"
        || manifest["architecture"] != "x86_64"
        || manifest["identifier"] != "io.github.danielmuellerir.tagexplosion"
    {
        return Err(
            "Paketversion, Anwendung oder Zielplattform passen nicht zum bestätigten Update".into(),
        );
    }
    Ok(())
}

fn sync_directory(path: &Path) -> Result<(), String> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| "Installationsverzeichnis konnte nicht gesichert werden".into())
}

pub fn replace_appimage(current: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let metadata =
        fs::symlink_metadata(current).map_err(|_| "Installiertes AppImage nicht gefunden")?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || !bytes.starts_with(b"\x7fELF")
        || bytes.get(8..11) != Some(&b"AI\x02"[..])
    {
        return Err("Installation benötigt eine eigene reguläre AppImage-Datei und ein gültiges AppImage-Paket".into());
    }
    let directory = current.parent().ok_or("Installationsverzeichnis fehlt")?;
    let previous = directory.join("TagExplosion.previous.AppImage");
    if previous == current
        || fs::symlink_metadata(&previous)
            .is_ok_and(|value| !value.is_file() || value.uid() != metadata.uid())
    {
        return Err("Der Rückfallpfad gehört nicht zu dieser Installation".into());
    }
    let stem = format!(".tagx-update-{}", std::process::id());
    let staged = directory.join(format!("{stem}.new"));
    let backup = directory.join(format!("{stem}.previous"));
    let operation = (|| {
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&staged)
            .map_err(|_| "Update konnte nicht im Installationsverzeichnis vorbereitet werden")?;
        output
            .write_all(bytes)
            .and_then(|_| output.sync_all())
            .map_err(|_| "Update konnte nicht vollständig geschrieben werden")?;
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))
            .map_err(|_| "Update konnte nicht ausführbar gemacht werden")?;
        // Ein Hardlink erhält exakt den laufenden Stand. Der Kopierfallback
        // beginnt ebenfalls exklusiv; ein fremder Pfad wird niemals überschrieben.
        if fs::hard_link(current, &backup).is_err() {
            let mut source = File::open(current).map_err(|_| "Vorige Version nicht lesbar")?;
            let mut target = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o755)
                .open(&backup)
                .map_err(|_| "Vorige Version konnte nicht gesichert werden")?;
            std::io::copy(&mut source, &mut target)
                .and_then(|_| target.sync_all())
                .map_err(|_| "Sicherung der vorigen Version fehlgeschlagen")?;
        }
        fs::rename(&backup, &previous)
            .map_err(|_| "Vorige Version konnte nicht veröffentlicht werden")?;
        sync_directory(directory)?;
        fs::rename(&staged, current).map_err(|_| "Update konnte nicht atomar eingesetzt werden")?;
        sync_directory(directory)
    })();
    let _ = fs::remove_file(&staged);
    let _ = fs::remove_file(&backup);
    operation
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
}
