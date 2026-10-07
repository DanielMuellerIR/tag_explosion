# Finder-Objekt beim DMG-Bau

Geprüft: 2026-10-07, macOS 26.7.1.

`tell (POSIX file "$mount_dir" as alias)` kompiliert, adressiert aber einen
rohen AppleScript-Alias. Der darin ausgeführte Befehl `open` scheitert mit -1708.
Der Finder benötigt ein eigenes Ordnerobjekt:

```applescript
tell application "Finder"
    tell folder (POSIX file "$mount_dir" as alias)
        open
        -- Layoutbefehle für container window
    end tell
end tell
```

Der reale Layoutschritt muss in einer GUI-Sitzung mit freigegebener
Finder-Automation laufen. Ein SSH-Prozess kann trotz entsperrter Konsole mit
-1743 scheitern; eine Prüfung, die nur AppleScript kompiliert, erkennt weder
diesen Berechtigungsfehler noch das falsche Zielobjekt. Der korrigierte
vollständige DMG-Bau wurde in einer GUI-Sitzung ausgeführt.

`--no-finder-layout` bleibt für headless Builds verfügbar; dabei entsteht
kein Fensterlayout mit positionierten Icons und Hintergrundbild.
