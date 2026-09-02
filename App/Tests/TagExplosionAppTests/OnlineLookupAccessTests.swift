// Entscheidungslogik vor einer Online-Suche, ohne Fenster und ohne Netz:
// Einstellung aus → blockiert; an, aber Hinweis nie bestätigt → Hinweis;
// beides → suchen. Die Keychain selbst wird hier bewusst nicht angefasst.
import Foundation
import Testing
@testable import TagExplosionApp

@Suite("OnlineLookupAccess")
struct OnlineLookupAccessTests {
    @Test("Ohne Freigabe wird nie gesucht, auch mit bestätigtem Hinweis")
    func blockedWithoutSetting() {
        #expect(OnlineLookupAccess.decision(allowed: false, acknowledged: false) == .blocked)
        #expect(OnlineLookupAccess.decision(allowed: false, acknowledged: true) == .blocked)
    }

    @Test("Erste Nutzung zeigt den Datenschutzhinweis, danach direkt suchen")
    func consentFlow() {
        #expect(OnlineLookupAccess.decision(allowed: true, acknowledged: false) == .needsPrivacyConsent)
        #expect(OnlineLookupAccess.decision(allowed: true, acknowledged: true) == .ready)
    }

    @Test("Voreinstellung: Online-Dienste aus; Hinweis nennt alle drei Dienste")
    func defaults() {
        let defaults = UserDefaults(suiteName: "OnlineLookupAccessTests-\(UUID().uuidString)")!
        #expect(!defaults.bool(forKey: OnlineLookupAccess.allowedDefaultsKey))
        #expect(!defaults.bool(forKey: OnlineLookupAccess.privacyAcknowledgedDefaultsKey))
        let notice = OnlineLookupAccess.privacyNotice
        #expect(notice.contains("musicbrainz.org") && notice.contains("api.discogs.com") && notice.contains("api.acoustid.org"))
        #expect(KeychainCredentialStore.discogsAccount != KeychainCredentialStore.acoustIDAccount)
    }
}
