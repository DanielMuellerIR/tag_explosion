// Einstellungen des Online-Lookups: die Freigabe „Online-Dienste erlauben"
// (Voreinstellung aus), die Bestätigung des Datenschutzhinweises und die
// Zugangsdaten (Discogs-Token, AcoustID-Key) in der Keychain — nie in
// UserDefaults, die liegen als Klartext-Plist auf der Platte.
import Security
import SwiftUI
import TagExplosionCore

/// Schlüssel und Entscheidungslogik, getrennt von SwiftUI testbar.
enum OnlineLookupAccess {
    /// UserDefaults: Online-Dienste erlaubt (Voreinstellung aus).
    nonisolated static let allowedDefaultsKey = "onlineServicesAllowed"
    /// UserDefaults: Datenschutzhinweis wurde einmal bestätigt.
    nonisolated static let privacyAcknowledgedDefaultsKey = "onlineLookupPrivacyAcknowledged"

    nonisolated static var isAllowed: Bool {
        UserDefaults.standard.bool(forKey: allowedDefaultsKey)
    }

    nonisolated static var isPrivacyAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: privacyAcknowledgedDefaultsKey)
    }

    /// Was vor einer Suche passieren muss.
    enum Decision: Equatable {
        /// Einstellung aus: nichts senden, auf die Einstellungen verweisen.
        case blocked
        /// Erste Nutzung: Hinweis zeigen und bestätigen lassen.
        case needsPrivacyConsent
        case ready
    }

    nonisolated static func decision(allowed: Bool, acknowledged: Bool) -> Decision {
        guard allowed else { return .blocked }
        return acknowledged ? .ready : .needsPrivacyConsent
    }

    /// Datenschutzhinweis in der Sprache der App.
    nonisolated static var privacyNotice: String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return language == "de" ? OnlineLookupConsent.privacyNoticeGerman : OnlineLookupConsent.privacyNoticeEnglish
    }

    /// Version für den User-Agent: aus dem Bundle, sonst "dev" (swift run).
    nonisolated static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Zugangsdaten aus der Keychain — nur zum Zeitpunkt der Anfrage gelesen.
    nonisolated static func credentials() -> LookupCredentials {
        LookupCredentials(
            discogsToken: try? KeychainCredentialStore.read(account: KeychainCredentialStore.discogsAccount),
            acoustIDKey: try? KeychainCredentialStore.read(account: KeychainCredentialStore.acoustIDAccount))
    }
}

/// Generische Passwörter in der Login-Keychain über das Security-Framework.
/// Ein Eintrag je Dienst; Lesen liefert nil, wenn keiner da ist.
enum KeychainCredentialStore {
    nonisolated static let service = "io.github.danielmuellerir.tagexplosion.online-lookup"
    nonisolated static let discogsAccount = "discogs-token"
    nonisolated static let acoustIDAccount = "acoustid-client-key"

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return String(localized: "Schlüsselbund-Fehler: \(text)")
            }
        }
    }

    nonisolated private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    nonisolated static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Leerer Wert = Eintrag löschen.
    nonisolated static func write(account: String, secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            // Nur auf diesem Gerät, nicht in der iCloud-Keychain.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    nonisolated static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// Abschnitt in den Einstellungen (⌘,).
struct OnlineLookupSettingsSection: View {
    @AppStorage(OnlineLookupAccess.allowedDefaultsKey) private var allowed = false
    @State private var discogsToken = ""
    @State private var acoustIDKey = ""
    @State private var keychainError: String?

    var body: some View {
        Section {
            Toggle("Online-Dienste erlauben (MusicBrainz, Discogs, AcoustID)", isOn: $allowed)
            Text("""
            Nur für „Online nachschlagen …" im Editor — nie automatisch. Vor \
            der ersten Anfrage zeigt die App, welche Daten an welchen Dienst \
            gehen. Ohne diese Einstellung sendet Tag Explosion nichts.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            SecureField("Discogs-Token (optional)", text: $discogsToken)
                .onChange(of: discogsToken) { store(KeychainCredentialStore.discogsAccount, discogsToken) }
                .disabled(!allowed)
            HStack {
                Text("Ohne Token antwortet Discogs langsamer und ohne Bilder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Token erstellen", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                    .font(.caption)
            }

            SecureField("AcoustID-Client-Key", text: $acoustIDKey)
                .onChange(of: acoustIDKey) { store(KeychainCredentialStore.acoustIDAccount, acoustIDKey) }
                .disabled(!allowed)
            HStack {
                Text("Für die Erkennung per Audio-Fingerabdruck (braucht fpcalc aus Homebrew „chromaprint“).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Key beantragen", destination: URL(string: "https://acoustid.org/new-application")!)
                    .font(.caption)
            }
            Text("Token und Key liegen im Schlüsselbund dieses Macs, nicht in den Voreinstellungen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let keychainError {
                Text(keychainError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            discogsToken = (try? KeychainCredentialStore.read(account: KeychainCredentialStore.discogsAccount)) ?? ""
            acoustIDKey = (try? KeychainCredentialStore.read(account: KeychainCredentialStore.acoustIDAccount)) ?? ""
        }
    }

    private func store(_ account: String, _ value: String) {
        do {
            try KeychainCredentialStore.write(account: account, secret: value)
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }
}
