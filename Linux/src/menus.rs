use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    Emitter, Manager,
};

pub fn install(app: &tauri::App) -> tauri::Result<()> {
    let german = super::system_locale().to_lowercase().starts_with("de");
    let text = |de, en| if german { de } else { en };
    let mut file = SubmenuBuilder::new(app, text("Datei", "File"));
    for (id, de, en, key) in [
        ("new", "Neues Fenster", "New Window", "Ctrl+N"),
        ("open", "Öffnen …", "Open…", "Ctrl+O"),
        ("folder", "Ordner öffnen …", "Open Folder…", "Ctrl+Shift+O"),
        ("save", "Speichern", "Save", "Ctrl+S"),
        ("saveAll", "Alle speichern", "Save All", "Ctrl+Shift+S"),
        ("close", "Fenster schließen", "Close Window", "Ctrl+W"),
        ("quit", "Beenden", "Quit", "Ctrl+Q"),
    ] {
        file = file.item(
            &MenuItemBuilder::with_id(id, text(de, en))
                .accelerator(key)
                .build(app)?,
        );
    }
    let editing = SubmenuBuilder::new(app, text("Bearbeiten", "Edit"))
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .separator()
        .text("revert", text("Änderungen verwerfen …", "Discard Edits…"))
        .text("history", text("Versionen …", "Versions…"))
        .text("settings", text("Einstellungen …", "Settings…"))
        .build()?;
    let help = SubmenuBuilder::new(app, text("Hilfe", "Help"))
        .text(
            "updates",
            text("Nach Updates suchen …", "Check for Updates…"),
        )
        .text("about", text("Über Tag Explosion", "About Tag Explosion"))
        .build()?;
    app.set_menu(
        MenuBuilder::new(app)
            .items(&[&file.build()?, &editing, &help])
            .build()?,
    )?;
    app.on_menu_event(|app, event| {
        if event.id().as_ref() == "quit" {
            for window in app.webview_windows().values() {
                let _ = window.emit("request-close", ());
            }
            return;
        }
        let windows = app.webview_windows();
        if let Some(window) = windows
            .values()
            .find(|window| window.is_focused().unwrap_or(false))
            .or_else(|| windows.get("main"))
            .or_else(|| windows.values().next())
        {
            let _ = window.emit("menu-action", event.id().as_ref());
        }
    });
    Ok(())
}
