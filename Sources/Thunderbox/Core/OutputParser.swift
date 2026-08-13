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

    // MARK: - Port conflicts

    /// Phrases every runtime uses to say "that port is taken": Node's EADDRINUSE, the
    /// POSIX strerror text Python and Go surface, and the friendlier sentence tools
    /// write themselves.
    private static let addressInUseRegex = try! NSRegularExpression(
        pattern: #"EADDRINUSE|address already in use|port\s+\d{2,5}\s+is\s+(?:already\s+)?in\s+use"#,
        options: [.caseInsensitive])

    /// The port named on a conflict line. Node puts it after the last colon
    /// (`:::4321`, `127.0.0.1:4321`); friendlier messages put it after the word "port".
    private static let conflictPortRegex = try! NSRegularExpression(
        pattern: #"(?:port\s+|:)(\d{2,5})\b"#,
        options: [.caseInsensitive])

    /// A SCREAMING_CASE identifier containing PORT, ideally with the value to use.
    /// Well-behaved tools print the exact override in their error — book-reader's
    /// "start this one on another port with BOOK_READER_PORT=4322" is the whole answer,
    /// and reading it beats guessing that every project honours `PORT`.
    /// The lookahead carries the "must contain PORT" requirement so the capture itself can
    /// be a plain SCREAMING_CASE token — spelling it inline as `[A-Z][A-Z0-9_]*PORT…`
    /// would demand a character before PORT and quietly miss bare `PORT`.
    private static let portVarAssignedRegex = try! NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9_]*PORT)([A-Z][A-Z0-9_]*)\s*=\s*(\d{2,5})\b"#)

    private static let portVarBareRegex = try! NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9_]*PORT)([A-Z][A-Z0-9_]*)\b"#)

    /// Does this line say the port is taken? Returns the port it names, if any.
    /// A `true` with a nil port still means conflict — fall back to the declared port.
    static func detectPortConflict(in line: String) -> (isConflict: Bool, port: Int?) {
        let clean = stripANSI(line)
        let range = NSRange(clean.startIndex..., in: clean)
        guard addressInUseRegex.firstMatch(in: clean, range: range) != nil else {
            return (false, nil)
        }
        if let m = conflictPortRegex.firstMatch(in: clean, range: range),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: clean),
           let port = Int(clean[r]), port > 0, port < 65536 {
            return (true, port)
        }
        return (true, nil)
    }

    /// An env var this line offers as the way to move the port, and the value it
    /// suggests. Only meaningful in the neighbourhood of a conflict — a bare mention of
    /// `PORT` in ordinary output means nothing.
    static func detectPortVar(in line: String) -> (name: String, port: Int?)? {
        let clean = stripANSI(line)
        let range = NSRange(clean.startIndex..., in: clean)

        if let m = portVarAssignedRegex.firstMatch(in: clean, range: range),
           m.numberOfRanges > 2,
           let nameRange = Range(m.range(at: 1), in: clean),
           let portRange = Range(m.range(at: 2), in: clean),
           let port = Int(clean[portRange]), port > 0, port < 65536 {
            return (String(clean[nameRange]), port)
        }
        if let m = portVarBareRegex.firstMatch(in: clean, range: range),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: clean) {
            return (String(clean[r]), nil)
        }
        return nil
    }
}
