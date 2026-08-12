import Foundation

/// Utilities for interpreting a service's live output.
enum OutputParser {

    /// Strip ANSI/VT100 escape sequences so logs render as clean text.
    static func stripANSI(_ s: String) -> String {
        // CSI sequences: ESC [ ... final-byte ; plus OSC and single-char escapes.
        guard s.contains("\u{1B}") else { return s }
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {
                let next = i + 1 < scalars.count ? scalars[i + 1] : " "
                if next == "[" {
                    // CSI: skip until a byte in 0x40–0x7E
                    i += 2
                    while i < scalars.count {
                        let v = scalars[i].value
                        i += 1
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                    continue
                } else if next == "]" {
                    // OSC: skip until BEL or ESC\
                    i += 2
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}" && i + 1 < scalars.count && scalars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                    continue
                } else {
                    i += 2 // simple two-char escape
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\])(?::\d{2,5})?[^\s`'"]*"#,
        options: [.caseInsensitive])

    private static let portPhraseRegex = try! NSRegularExpression(
        pattern: #"(?:listening|running|ready|started|serving|available).{0,40}?(?:port|:)\s*(\d{2,5})"#,
        options: [.caseInsensitive])

    /// Try to find a server URL in a line of output. Normalizes 0.0.0.0 → localhost.
    static func detectURL(in line: String) -> URL? {
        let clean = stripANSI(line)
        let range = NSRange(clean.startIndex..., in: clean)

        if let m = urlRegex.firstMatch(in: clean, range: range),
           let r = Range(m.range, in: clean) {
            var str = String(clean[r])
            // Trim trailing punctuation the regex may have grabbed.
            while let last = str.last, ".,);]".contains(last) { str.removeLast() }
            str = str.replacingOccurrences(of: "0.0.0.0", with: "localhost")
                     .replacingOccurrences(of: "[::]", with: "localhost")
                     .replacingOccurrences(of: "[::1]", with: "localhost")
            if let url = URL(string: str) { return url }
        }

        if let m = portPhraseRegex.firstMatch(in: clean, range: range),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: clean),
           let port = Int(clean[r]), port > 0, port < 65536 {
            return URL(string: "http://localhost:\(port)")
        }
        return nil
    }
}
