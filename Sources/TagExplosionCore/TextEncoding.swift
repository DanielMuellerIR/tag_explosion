// Text in eine Legacy-Kodierung (Latin-1, Windows-1252 …) bringen — portabel.
//
// Falle in Linux-Foundation (swift-corelibs, Stand Swift 6.0): `String.data(
// using: .isoLatin1)` und `String(data:encoding: .isoLatin1)` liefern nil,
// sobald der Text ein CRLF (`\r\n`) enthält,
// weil das Zeilenende als ein Zeichen behandelt wird, das der Kodierer nicht
// abbildet. Untertitel und Kodi-NFOs aus Windows-Programmen enden praktisch
// immer auf CRLF; unter Linux scheiterte damit jedes Zurückschreiben in
// Latin-1. Der Umweg über `NSString` kodiert auf beiden Plattformen richtig
// und liefert weiterhin nil, wenn ein Zeichen nicht darstellbar ist.
import Foundation

extension String {
    /// Wie `String(data:encoding:)`, nur auch unter Linux verlässlich: Dort
    /// liefert der String-Weg für Latin-1-Bytes mit CRLF ebenfalls nil.
    /// nil, wenn die Bytes in der Kodierung ungültig sind.
    static func decoded(_ data: Data, as encoding: String.Encoding) -> String? {
        guard let text = NSString(data: data, encoding: encoding.rawValue) else { return nil }
        // `substring(from:)` liefert auf beiden Plattformen einen Swift-String
        // (die `as String`-Brücke gibt es unter Linux nicht).
        return text.substring(from: 0)
    }

    /// Wie `data(using:)`, nur auch unter Linux verlässlich (siehe oben).
    /// nil, wenn ein Zeichen in der Kodierung nicht existiert — Aufrufer
    /// müssen das wie bisher als Fehler behandeln.
    func encoded(as encoding: String.Encoding) -> Data? {
        NSString(string: self).data(using: encoding.rawValue, allowLossyConversion: false)
    }
}
