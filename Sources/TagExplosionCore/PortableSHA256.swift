// SHA-256 in reinem Swift — für Plattformen ohne CryptoKit (Linux).
//
// Unter macOS rechnet `BackupJournal.sha256` mit CryptoKit. Ohne Prüfsumme
// könnte die Undo-Historie unter Linux nicht belegen, dass eine Kopie im
// Papierkorb noch unversehrt ist. Statt einer weiteren Abhängigkeit
// (swift-crypto) reicht hier die Standard-Implementierung nach FIPS 180-4;
// sie ist kurz, hat keine Plattformannahmen und wird nur für Prüfsummen
// gebraucht, nicht für Geheimnisse. Ein Test vergleicht sie mit bekannten
// Vektoren und (unter macOS) mit CryptoKit.
import Foundation

struct PortableSHA256 {

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    /// Noch nicht verarbeitete Bytes (weniger als ein 64-Byte-Block).
    private var pending: [UInt8] = []
    /// Gesamtlänge der Nachricht in Bytes (für das Längenfeld am Ende).
    private var totalBytes: UInt64 = 0

    init() {}

    mutating func update(data: Data) {
        totalBytes += UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            compress(block: pending[offset..<offset + 64])
            offset += 64
        }
        pending.removeFirst(offset)
    }

    /// Schließt die Berechnung ab und liefert den Hash als Hex-String
    /// (64 Kleinbuchstaben/Ziffern).
    mutating func finalizeHex() -> String {
        // Padding: 0x80, Nullen bis 56 mod 64, dann die Bitlänge (Big Endian).
        var block = pending
        block.append(0x80)
        while block.count % 64 != 56 { block.append(0) }
        let bitLength = totalBytes &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            block.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var offset = 0
        while offset < block.count {
            compress(block: block[offset..<offset + 64])
            offset += 64
        }
        pending = []
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(block: ArraySlice<UInt8>) {
        var schedule = [UInt32](repeating: 0, count: 64)
        var index = block.startIndex
        for t in 0..<16 {
            schedule[t] = UInt32(block[index]) << 24 | UInt32(block[index + 1]) << 16
                | UInt32(block[index + 2]) << 8 | UInt32(block[index + 3])
            index += 4
        }
        for t in 16..<64 {
            let s0 = rotr(schedule[t - 15], 7) ^ rotr(schedule[t - 15], 18) ^ (schedule[t - 15] >> 3)
            let s1 = rotr(schedule[t - 2], 17) ^ rotr(schedule[t - 2], 19) ^ (schedule[t - 2] >> 10)
            schedule[t] = schedule[t - 16] &+ s0 &+ schedule[t - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for t in 0..<64 {
            let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ bigS1 &+ choose &+ Self.roundConstants[t] &+ schedule[t]
            let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = bigS0 &+ majority
            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}
