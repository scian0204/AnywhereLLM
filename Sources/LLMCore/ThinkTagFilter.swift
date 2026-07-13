/// Strips `<think>…</think>` reasoning blocks from a streamed text feed.
///
/// Stateful so it survives chunk boundaries: a chunk may end mid-tag (`…<thi`)
/// or mid-block. Feed chunks in order via `feed(_:)`; the returned string is the
/// visible text to emit so far. Call `flush()` at end of stream to release any
/// text that was held back as a possible-but-incomplete tag.
///
/// Only the literal tags `<think>` / `</think>` are recognized (case-sensitive),
/// which is what current reasoning models emit. An unclosed `<think>` drops
/// everything to the end of the stream.
public struct ThinkTagFilter {
    private static let open = Array("<think>")
    private static let close = Array("</think>")

    private var insideThink = false
    /// Text held back because it might be the prefix of a tag split across chunks.
    private var pending: [Character] = []

    public init() {}

    /// Feed the next chunk; returns visible text ready to emit.
    public mutating func feed(_ chunk: String) -> String {
        pending.append(contentsOf: chunk)
        var out = ""

        while !pending.isEmpty {
            let tag = insideThink ? Self.close : Self.open
            if let range = firstMatch(of: tag, in: pending) {
                // Text before the tag: emit it (only when outside a think block).
                if !insideThink { out += String(pending[..<range.lowerBound]) }
                pending.removeSubrange(..<range.upperBound)
                insideThink.toggle()
            } else if let partialLen = longestSuffixPrefix(of: tag, in: pending) {
                // Tail of pending could be the start of `tag`; keep it, emit the rest.
                let emitEnd = pending.count - partialLen
                if !insideThink { out += String(pending[..<emitEnd]) }
                pending.removeSubrange(..<emitEnd)
                break
            } else {
                // No tag and no possible partial: emit everything (if visible).
                if !insideThink { out += String(pending) }
                pending.removeAll()
                break
            }
        }
        return out
    }

    /// End of stream: emit any held-back text that turned out not to be a tag.
    /// Anything still inside an unclosed think block is dropped.
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return insideThink ? "" : String(pending)
    }

    // MARK: - Matching helpers

    /// Index range of the first full occurrence of `needle` in `haystack`.
    private func firstMatch(of needle: [Character], in haystack: [Character]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }

    /// Longest k>0 where the last k chars of `haystack` equal the first k of `needle`.
    /// That suffix might grow into a full tag on the next chunk, so hold it back.
    private func longestSuffixPrefix(of needle: [Character], in haystack: [Character]) -> Int? {
        let maxK = min(needle.count - 1, haystack.count)
        var k = maxK
        while k > 0 {
            if Array(haystack.suffix(k)) == Array(needle.prefix(k)) { return k }
            k -= 1
        }
        return nil
    }
}
