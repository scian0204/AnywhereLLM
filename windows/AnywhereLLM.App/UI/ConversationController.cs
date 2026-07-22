using System.Diagnostics;
using System.Windows.Threading;
using AnywhereLLM.Services;

namespace AnywhereLLM.UI;

/// One line of the in-panel transcript.
internal sealed class TranscriptEntry
{
    public string Role = "user"; // "user" | "assistant"
    public string Text = "";
}

/// Drives one panel session. UX branches on editability × selection × applyMode
/// (ports the Swift ConversationController):
///  - view-only (target not editable): show result, keep it, no apply.
///  - transcript UX (editable + (selection or applyMode=preview)): stream into the
///    panel; preview shows a confirm button, immediate+selection auto-applies.
///  - live typing (editable + no selection + immediate): hide panel, type the
///    response straight into the target field.
///
/// StateChanged is raised (on the UI thread) whenever observable state changes so
/// the window can re-render. The On* events drive panel show/hide/apply.
internal sealed class ConversationController
{
    public const string ApplyModeKey = "applyMode";
    public const string IncludeAppNameKey = "includeAppName";
    public const string IncludeFullTextKey = "includeFullText";
    public const string SystemPromptKey = "systemPrompt";

    private readonly TargetContext _context;
    private readonly LlmClient _client = new();
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly List<TranscriptEntry> _transcript = new();
    private CancellationTokenSource? _cts;

    public ConversationController(TargetContext context) => _context = context;

    // Observable state.
    public bool IsStreaming { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string? PendingResult { get; private set; }

    public event Action? StateChanged;
    public event Action<string>? OnApply;
    public event Action? OnStreamingInsertStart;
    public event Action? OnStreamingInsertDone;
    public event Action? OnStreamingInsertError;

    // Derived.
    public bool HasSelection => !string.IsNullOrEmpty(_context.SelectedText);
    /// True when this session is an image (screen-capture) query — always view-only.
    public bool HasImage => _context.Image != null;
    /// Captured PNG bytes for the panel thumbnail; null for text sessions.
    public byte[]? CapturedImage => _context.Image;
    /// Base64 of the captured image; attached to the first user message only.
    private string? ImageBase64 => _context.Image is { } b ? Convert.ToBase64String(b) : null;
    public bool IsViewOnly => !_context.IsEditable;
    public string ApplyMode => AppSettings.GetString(ApplyModeKey, "preview");
    public bool ShowsTranscriptUI => IsViewOnly || HasSelection || ApplyMode != "immediate";
    public string? SelectionPreview => HasSelection ? _context.SelectedText : null;
    public string? LatestAssistantText
    {
        get
        {
            for (int i = _transcript.Count - 1; i >= 0; i--)
                if (_transcript[i].Role == "assistant") return _transcript[i].Text;
            return null;
        }
    }
    public bool TranscriptIsEmpty => _transcript.Count == 0;

    // MARK: - Sending

    /// Returns whether the turn was accepted; false ⇒ the view keeps the input
    /// (a rejected turn's text must not silently vanish).
    public bool Send(string input)
    {
        var trimmed = input.Trim();
        if (IsStreaming) return false;

        var profile = (AppSettings.GetString(SystemPromptKey) ?? "").Trim();
        // First turn may be empty. Images are always view-only, so an instruction-less
        // send is harmless — allowed even without a profile. Selection still requires a
        // non-empty profile (else an instruction-less reply would auto-replace it in
        // immediate mode).
        if (trimmed.Length == 0
            && !(TranscriptIsEmpty && (HasImage || (HasSelection && profile.Length > 0))))
            return false;

        ErrorMessage = null;
        PendingResult = null;

        if (ShowsTranscriptUI) SendTranscriptTurn(trimmed);
        else SendInsertTurn(trimmed);
        return true;
    }

    // MARK: - Insert mode (live streaming into the target)

    private void SendInsertTurn(string input)
    {
        var messages = new List<ChatMessage>
        {
            new("system", SystemContent()),
            new("user", UserContent(input, firstTurn: true)),
        };
        IsStreaming = true;
        RaiseChanged();

        var hwnd = _context.TargetHwnd;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;

        _ = Task.Run(async () =>
        {
            var filter = new AnywhereLLM.Core.ThinkTagFilter();
            var buffer = "";
            var lastFlush = Stopwatch.StartNew();
            bool typingStarted = false;

            async Task BeginTypingIfNeeded()
            {
                if (typingStarted) return;
                typingStarted = true;
                await _dispatcher.InvokeAsync(() => OnStreamingInsertStart?.Invoke());
                TextTargetService.RefocusTarget(hwnd);
                await Task.Delay(TextTargetService.FocusReturnDelayMs, ct);
            }

            void Flush()
            {
                if (buffer.Length == 0) return;
                TextTargetService.TypeText(buffer, hwnd);
                buffer = "";
            }

            try
            {
                await foreach (var chunk in _client.StreamChatAsync(messages, ct))
                {
                    ct.ThrowIfCancellationRequested();
                    buffer += filter.Feed(chunk);
                    if (buffer.Length == 0) continue;
                    await BeginTypingIfNeeded();
                    if (lastFlush.ElapsedMilliseconds >= 100) { Flush(); lastFlush.Restart(); }
                }
                ct.ThrowIfCancellationRequested();
                buffer += filter.Flush();
                if (buffer.Length > 0) await BeginTypingIfNeeded();
                Flush();
            }
            catch (OperationCanceledException)
            {
                // Cancelled: keep what was typed, drop the rest.
            }
            catch (Exception ex)
            {
                if (typingStarted) Flush();
                Post(() => ErrorMessage = ex.Message);
            }

            Post(() =>
            {
                IsStreaming = false;
                RaiseChangedCore();
                if (ErrorMessage == null) OnStreamingInsertDone?.Invoke();
                else OnStreamingInsertError?.Invoke();
            });
        });
    }

    // MARK: - Transcript mode (view-only + all select mode + insert preview)

    private void SendTranscriptTurn(string input)
    {
        var prior = _transcript
            .Select(e => new ChatMessage(e.Role, e.Text))
            .ToList();
        var composed = UserContent(input, firstTurn: prior.Count == 0);
        _transcript.Add(new TranscriptEntry { Role = "user", Text = composed });
        int assistantIndex = _transcript.Count;
        _transcript.Add(new TranscriptEntry { Role = "assistant", Text = "" });

        var messages = new List<ChatMessage> { new("system", SystemContent()) };
        messages.AddRange(prior);
        messages.Add(new ChatMessage("user", composed));
        // 이미지 질의: 캡처 이미지를 첫 user 메시지에만 붙인다. 매 턴 첫 user 턴에
        // 재부착해 multi-turn에서도 이미지 컨텍스트가 유지된다 (prior는 텍스트만 복원).
        if (ImageBase64 is { } b64)
        {
            int i = messages.FindIndex(m => m.Role == "user");
            if (i >= 0) messages[i] = messages[i] with { ImagePngBase64 = b64 };
        }

        IsStreaming = true;
        RaiseChanged();

        _cts = new CancellationTokenSource();
        var ct = _cts.Token;

        _ = Task.Run(async () =>
        {
            var filter = new AnywhereLLM.Core.ThinkTagFilter();
            try
            {
                await foreach (var chunk in _client.StreamChatAsync(messages, ct))
                {
                    if (ct.IsCancellationRequested) break;
                    var visible = filter.Feed(chunk);
                    if (visible.Length > 0)
                        Post(() => { if (assistantIndex < _transcript.Count) _transcript[assistantIndex].Text += visible; RaiseChangedCore(); });
                }
                var tail = filter.Flush();
                if (tail.Length > 0)
                    Post(() => { if (assistantIndex < _transcript.Count) _transcript[assistantIndex].Text += tail; RaiseChangedCore(); });
            }
            catch (OperationCanceledException) { /* leave partial text */ }
            catch (Exception ex)
            {
                Post(() => ErrorMessage = ex.Message);
            }

            Post(() => FinishTranscriptStreaming(assistantIndex, ct.IsCancellationRequested));
        });
    }

    private void FinishTranscriptStreaming(int assistantIndex, bool cancelled)
    {
        IsStreaming = false;
        var result = assistantIndex < _transcript.Count ? _transcript[assistantIndex].Text.Trim() : "";

        // A zero-token turn (error/no reply) drops the user+assistant pair so an
        // empty assistant isn't sent as prior next turn, and an empty-⏎ retry after
        // a first-turn failure isn't blocked by the first-turn guard.
        if (result.Length == 0 && assistantIndex < _transcript.Count && assistantIndex >= 1)
            _transcript.RemoveRange(assistantIndex - 1, 2);

        RaiseChangedCore();

        if (cancelled || ErrorMessage != null || result.Length == 0) return;
        if (IsViewOnly) return; // nowhere to apply — result stays in the panel

        if (ApplyMode == "immediate") OnApply?.Invoke(result);
        else { PendingResult = result; RaiseChangedCore(); }
    }

    public void ApplyPending()
    {
        if (PendingResult is { } r) OnApply?.Invoke(r);
    }

    public void Cancel()
    {
        _cts?.Cancel();
        _cts = null;
    }

    // MARK: - Prompt construction

    private string SystemContent()
    {
        var parts = new List<string>();

        var global = (AppSettings.GetString(SystemPromptKey) ?? "").Trim();
        if (global.Length > 0) parts.Add(global);

        if (AppSettings.GetBool(IncludeAppNameKey, true) && !string.IsNullOrEmpty(_context.AppName))
            parts.Add(Loc.L("prompt.appContext", _context.AppName!));

        if (IsViewOnly) parts.Add(Loc.L("prompt.viewOnly"));
        else if (HasSelection) parts.Add(Loc.L("prompt.editSelection"));
        else parts.Add(Loc.L("prompt.insertAtCursor"));

        if (AppSettings.GetBool(LlmClient.DisableThinkKey, false)) parts.Add("/no_think");

        return string.Join("\n\n", parts);
    }

    private string UserContent(string input, bool firstTurn)
    {
        if (!firstTurn) return input;

        var parts = new List<string>();
        if (SelectionPreview is { } sel)
            parts.Add(Loc.L("prompt.sectionSelection") + "\n" + sel);
        else if (AppSettings.GetBool(IncludeFullTextKey, false) && !string.IsNullOrEmpty(_context.FullText))
            parts.Add(Loc.L("prompt.sectionFullText") + "\n" + _context.FullText);

        if (input.Length > 0)
            parts.Add(Loc.L("prompt.sectionRequest") + "\n" + input);
        return string.Join("\n\n", parts);
    }

    // MARK: - Dispatch helpers

    private void Post(Action a)
    {
        if (_dispatcher.CheckAccess()) a();
        else _dispatcher.BeginInvoke(a);
    }

    private void RaiseChanged()
    {
        if (_dispatcher.CheckAccess()) StateChanged?.Invoke();
        else _dispatcher.BeginInvoke(() => StateChanged?.Invoke());
    }

    private void RaiseChangedCore() => StateChanged?.Invoke();
}
