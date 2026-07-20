using System.Text;

namespace AnywhereLLM.Core;

/// Strips &lt;think&gt;…&lt;/think&gt; reasoning blocks from a streamed text feed.
///
/// Stateful so it survives chunk boundaries: a chunk may end mid-tag ("…&lt;thi") or
/// mid-block. Feed chunks in order via Feed(); the returned string is the visible
/// text to emit so far. Call Flush() at end of stream to release any text held back
/// as a possible-but-incomplete tag.
///
/// Only the literal tags &lt;think&gt; / &lt;/think&gt; are recognized (case-sensitive), which
/// is what current reasoning models emit. An unclosed &lt;think&gt; drops everything to
/// the end of the stream. Port of the Swift ThinkTagFilter (a class here, not a
/// struct, to avoid value-copy foot-guns over the mutable pending buffer).
public sealed class ThinkTagFilter
{
    private static readonly char[] Open = "<think>".ToCharArray();
    private static readonly char[] Close = "</think>".ToCharArray();

    private bool _insideThink;
    private readonly List<char> _pending = new();

    /// Feed the next chunk; returns visible text ready to emit.
    public string Feed(string chunk)
    {
        _pending.AddRange(chunk);
        var sb = new StringBuilder();

        while (_pending.Count > 0)
        {
            var tag = _insideThink ? Close : Open;
            int idx = FirstMatch(tag);
            if (idx >= 0)
            {
                if (!_insideThink) AppendRange(sb, 0, idx);
                _pending.RemoveRange(0, idx + tag.Length);
                _insideThink = !_insideThink;
            }
            else
            {
                int partial = LongestSuffixPrefix(tag);
                if (partial > 0)
                {
                    int emitEnd = _pending.Count - partial;
                    if (!_insideThink) AppendRange(sb, 0, emitEnd);
                    _pending.RemoveRange(0, emitEnd);
                    break;
                }
                if (!_insideThink) AppendRange(sb, 0, _pending.Count);
                _pending.Clear();
                break;
            }
        }
        return sb.ToString();
    }

    /// End of stream: emit any held-back text that turned out not to be a tag.
    /// Anything still inside an unclosed think block is dropped.
    public string Flush()
    {
        var s = _insideThink ? "" : new string(_pending.ToArray());
        _pending.Clear();
        return s;
    }

    private void AppendRange(StringBuilder sb, int start, int endExclusive)
    {
        for (int i = start; i < endExclusive; i++) sb.Append(_pending[i]);
    }

    /// Index of the first full occurrence of needle in _pending, or -1.
    private int FirstMatch(char[] needle)
    {
        if (needle.Length > _pending.Count) return -1;
        for (int start = 0; start <= _pending.Count - needle.Length; start++)
        {
            bool ok = true;
            for (int k = 0; k < needle.Length; k++)
                if (_pending[start + k] != needle[k]) { ok = false; break; }
            if (ok) return start;
        }
        return -1;
    }

    /// Longest k&gt;0 where the last k chars of _pending equal the first k of needle;
    /// that suffix might grow into a full tag next chunk, so hold it back. 0 = none.
    private int LongestSuffixPrefix(char[] needle)
    {
        int maxK = Math.Min(needle.Length - 1, _pending.Count);
        for (int k = maxK; k > 0; k--)
        {
            bool ok = true;
            for (int i = 0; i < k; i++)
                if (_pending[_pending.Count - k + i] != needle[i]) { ok = false; break; }
            if (ok) return k;
        }
        return 0;
    }
}
