// What Foundation's `NSString` gives a string and FoundationEssentials doesn't, written with the
// standard library alone, so every platform has the same. Only this package's modules see them.

extension StringProtocol {
    /// The string without the whitespace, newlines among it, at its ends.
    package func trimmed() -> String {
        trimmed(while: \.isWhitespace)
    }

    /// The string without the characters `isTrimmed` holds for at its ends.
    package func trimmed(while isTrimmed: (Character) -> Bool) -> String {
        guard let first = firstIndex(where: { !isTrimmed($0) }), let last = lastIndex(where: { !isTrimmed($0) })
        else { return "" }
        return String(self[first...last])
    }
}

extension Sequence<UInt8> {
    /// The bytes as lowercase hex, two digits each.
    package var hexString: String {
        map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
