#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod engine;
mod file_args;
mod localization;
mod menus;
mod updates;

use engine::Engine;
use localization::text;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tauri::{Emitter, Manager, State, WebviewWindow};
use tauri_plugin_dialog::DialogExt;

struct Desktop {
    engine: Arc<Engine>,
    closing: Mutex<HashSet<String>>,
    windows: AtomicU64,
    initial_files: Mutex<HashMap<String, Vec<String>>>,
}

#[tauri::command]
async fn media(
    window: WebviewWindow,
    desktop: State<'_, Desktop>,
    method: String,
    mut params: Value,
) -> Result<Value, String> {
    if method.starts_with("lookup") {
        let authorization = desktop
            .engine
            .call(window.label(), "lookupAuthorization", params.clone())
            .await?;
        if authorization["allowed"] != true {
            return Err(text(
                "Online-Dienste und Datenschutzhinweis zuerst in den Einstellungen freigeben",
                "Enable online services and acknowledge the privacy notice in Settings first",
            )
            .into());
        }
        if let Some(account) = authorization["account"].as_str() {
            let account = account.to_string();
            let credentials = tauri::async_runtime::spawn_blocking(move || -> Result<Value, String> {
                let value = match keyring::Entry::new("io.github.danielmuellerir.tagexplosion.online-lookup", &account)
                    .map_err(|_| text("Schlüsselbund ist nicht verfügbar", "Keyring is unavailable"))?.get_password() {
                    Ok(value) => Some(value), Err(keyring::Error::NoEntry) => None,
                    Err(_) => return Err(text("Der Schlüsselbund ist nicht verfügbar oder gesperrt", "The keyring is unavailable or locked").into()),
                };
                Ok(json!({if account == "discogs-token" { "discogsToken" } else { "acoustIDKey" }: value}))
            }).await.map_err(|_| text("Schlüsselbund-Auftrag unterbrochen", "Keyring operation was interrupted"))??;
            params
                .as_object_mut()
                .ok_or(text("Ungültige Parameter", "Invalid parameters"))?
                .insert("credentials".into(), credentials);
        }
    }
    desktop.engine.call(window.label(), &method, params).await
}

#[tauri::command]
async fn choose(
    window: WebviewWindow,
    purpose: String,
    suggested: Option<String>,
) -> Result<Vec<String>, String> {
    let app = window.app_handle().clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut dialog = app.dialog().file();
        if let Some(name) = suggested {
            dialog = dialog.set_file_name(name);
        }
        let values = match purpose.as_str() {
            "folder" => dialog.blocking_pick_folder().into_iter().collect(),
            "save" => dialog.blocking_save_file().into_iter().collect(),
            "cover" => dialog
                .add_filter(
                    text("Bilder", "Images"),
                    &["jpg", "jpeg", "png", "webp", "gif", "bmp"],
                )
                .blocking_pick_file()
                .into_iter()
                .collect(),
            "archive" => dialog
                .add_filter("JSON", &["json"])
                .blocking_pick_file()
                .into_iter()
                .collect(),
            _ => dialog.blocking_pick_files().unwrap_or_default(),
        };
        values
            .into_iter()
            .map(|value| {
                value
                    .into_path()
                    .map(|path| path.to_string_lossy().into_owned())
                    .map_err(|_| text("Ungültiger Dateipfad", "Invalid file path").into())
            })
            .collect::<Result<Vec<_>, _>>()
    })
    .await
    .map_err(|_| text("Dateidialog unterbrochen", "File dialog was interrupted"))?;
    result
}

#[tauri::command]
async fn save_credential(account: String, value: String) -> Result<(), String> {
    if !["discogs-token", "acoustid-client-key"].contains(&account.as_str()) {
        return Err(text("Unbekannter Dienst", "Unknown service").into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let entry = keyring::Entry::new("io.github.danielmuellerir.tagexplosion.online-lookup", &account).map_err(|_| text("Schlüsselbund nicht verfügbar", "Keyring is unavailable"))?;
        let result = if value.is_empty() { entry.delete_credential() } else { entry.set_password(&value) };
        match result { Ok(()) | Err(keyring::Error::NoEntry) => Ok(()), Err(_) => Err(text("Schlüsselbund ist gesperrt oder nicht verfügbar. Zugangsdaten wurden nicht gespeichert.", "The keyring is locked or unavailable. The credentials were not saved.").into()) }
    }).await.map_err(|_| text("Schlüsselbund-Auftrag unterbrochen", "Keyring operation was interrupted"))?
}

#[tauri::command]
fn new_window(
    app: tauri::AppHandle,
    desktop: State<'_, Desktop>,
    paths: Option<Vec<String>>,
) -> Result<(), String> {
    if app.webview_windows().len() >= 32 {
        return Err(text(
            "Höchstens 32 Fenster können gleichzeitig geöffnet sein",
            "Up to 32 windows can be open at once",
        )
        .into());
    }
    let id = desktop.windows.fetch_add(1, Ordering::Relaxed);
    let label = format!("window-{id}");
    desktop
        .initial_files
        .lock()
        .map_err(|_| {
            text(
                "Fensterzustand nicht verfügbar",
                "Window state is unavailable",
            )
        })?
        .insert(label.clone(), paths.unwrap_or_default());
    let created = tauri::WebviewWindowBuilder::new(
        &app,
        label.clone(),
        tauri::WebviewUrl::App("index.html".into()),
    )
    .title("Tag Explosion")
    .inner_size(1100.0, 800.0)
    .min_inner_size(760.0, 500.0)
    .build();
    if created.is_err() {
        desktop
            .initial_files
            .lock()
            .map_err(|_| {
                text(
                    "Fensterzustand nicht verfügbar",
                    "Window state is unavailable",
                )
            })?
            .remove(&label);
    }
    created.map_err(|_| {
        text(
            "Fenster konnte nicht geöffnet werden",
            "The window could not be opened",
        )
    })?;
    Ok(())
}

#[tauri::command]
async fn close_window(window: WebviewWindow, desktop: State<'_, Desktop>) -> Result<Value, String> {
    let result = desktop
        .engine
        .call(window.label(), "close", json!({}))
        .await?;
    if result["closed"] == true {
        desktop
            .closing
            .lock()
            .map_err(|_| {
                text(
                    "Fensterzustand nicht verfügbar",
                    "Window state is unavailable",
                )
            })?
            .insert(window.label().into());
        window.close().map_err(|_| {
            text(
                "Fenster konnte nicht geschlossen werden",
                "The window could not be closed",
            )
        })?;
    }
    Ok(result)
}

#[tauri::command]
fn system_locale() -> String {
    localization::language().into()
}

#[tauri::command]
fn startup_files(window: WebviewWindow, desktop: State<'_, Desktop>) -> Vec<String> {
    desktop
        .initial_files
        .lock()
        .map(|mut values| values.remove(window.label()).unwrap_or_default())
        .unwrap_or_default()
}

fn engine_path(app: &tauri::App) -> PathBuf {
    if let Some(path) = std::env::var_os("TAGX_ENGINE") {
        return path.into();
    }
    if let Ok(executable) = std::env::current_exe() {
        if let Some(parent) = executable.parent() {
            let path = parent.join("tagx-engine");
            if path.is_file() {
                return path;
            }
        }
    }
    app.path()
        .resource_dir()
        .unwrap_or_default()
        .join("tagx-engine")
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            let windows = app.webview_windows();
            if let Some(window) = windows
                .get("main")
                .or_else(|| {
                    windows
                        .values()
                        .find(|window| window.is_focused().unwrap_or(false))
                })
                .or_else(|| windows.values().next())
            {
                let paths = file_args::existing_file_arguments(args, &cwd);
                let queued = app
                    .state::<Desktop>()
                    .initial_files
                    .lock()
                    .map(|mut pending| {
                        if let Some(waiting) = pending.get_mut(window.label()) {
                            waiting.extend(paths.clone());
                            true
                        } else {
                            false
                        }
                    })
                    .unwrap_or(false);
                if !queued {
                    let _ = window.emit("open-files", paths);
                }
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_updater::Builder::new()
                .pubkey(include_str!("../updates.pub").trim())
                .build(),
        )
        .setup(|app| {
            menus::install(app)?;
            app.manage(updates::Updates::default());
            app.manage(Desktop {
                engine: Engine::new(engine_path(app)),
                closing: Mutex::new(HashSet::new()),
                windows: AtomicU64::new(1),
                initial_files: Mutex::new(HashMap::from([(
                    "main".into(),
                    std::env::args_os()
                        .skip(1)
                        .map(PathBuf::from)
                        .filter(|path| path.exists())
                        .map(|path| path.to_string_lossy().into_owned())
                        .collect(),
                )])),
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let desktop = window.state::<Desktop>();
                let allowed = desktop
                    .closing
                    .lock()
                    .map(|mut values| values.remove(window.label()))
                    .unwrap_or(false);
                if !allowed {
                    api.prevent_close();
                    let _ = window.emit("request-close", ());
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            media,
            choose,
            save_credential,
            new_window,
            close_window,
            startup_files,
            system_locale,
            updates::check_update,
            updates::install_update
        ])
        .run(tauri::generate_context!())
        .expect("Tag Explosion konnte nicht gestartet werden");
}
