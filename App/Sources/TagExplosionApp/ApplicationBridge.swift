import AppKit
@_exported import TagExplosionApplication

extension AppModel {
    var hostWindow: NSWindow? {
        get { hostContext as? NSWindow }
        set { hostContext = newValue }
    }
    /// Öffnen-Dialog (Dateien und Ordner) für dieses Fenster.
    func presentOpenPanel() {
        guard let urls = MediaOpenPanel.run() else { return }
        Task { await self.open(urls: urls) }
    }

}

extension FileEntry {
    /// Alles, was der Fensterkopf über diese Datei wissen muss.
    var chromeEntry: WindowChromeEntry {
        WindowChromeEntry(title: displayTitle, url: url,
                          isDirty: isDirty, isSaving: isSaving)
    }

}
