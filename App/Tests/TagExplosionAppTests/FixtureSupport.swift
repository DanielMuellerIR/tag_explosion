import Foundation
import TagExplosionTestSupport

/// Pflicht-Fixtures verwenden denselben Aufbau wie die optionalen Audio-Tests.
enum AppTestFixtures {
    static let directory: URL = {
        do { return try MediaTestFixtures.directory() }
        catch { preconditionFailure("Fixture-Generierung: \(error)") }
    }()
}
