namespace AnywhereLLM.Core;

/// One parsed streaming line, shared by SseParser and OllamaChatParser so the
/// LLM client consumes both through one loop (mirrors the Swift LineResult).
public enum LineKind { Content, Done, Error, Ignore }

public readonly record struct LineResult(LineKind Kind, string Text)
{
    public static readonly LineResult Ignore = new(LineKind.Ignore, "");
    public static readonly LineResult Done = new(LineKind.Done, "");
    public static LineResult Content(string s) => new(LineKind.Content, s);
    public static LineResult Error(string s) => new(LineKind.Error, s);
}
