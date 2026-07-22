using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using AnywhereLLM.Services;

namespace AnywhereLLM.UI;

/// Floating prompt panel hosting the conversation UI (ports PromptPanel +
/// ConversationView). One session per open: Present() builds a fresh controller;
/// closing resets it (multi-turn history lives only while the panel is open).
///
/// Windows interaction model note: unlike the macOS non-activating panel, this
/// window activates so the user can type into it. The target's context (hwnd,
/// selection) is captured BEFORE the panel shows; on apply we refocus the target
/// hwnd and type. See docs/progress/31.
public partial class PromptWindow : Window
{
    private ConversationController? _controller;
    private TargetContext? _context;
    private List<PromptProfile> _profiles = new();
    private bool _loadingProfiles;

    public PromptWindow() => InitializeComponent();

    // MARK: - Session lifecycle

    public void Present(TargetContext ctx)
    {
        _controller?.Cancel();
        _context = ctx;

        var c = new ConversationController(ctx);
        _controller = c;
        c.StateChanged += () => { if (_controller == c) Render(); };
        c.OnApply += r => { if (_controller == c) Apply(r); };
        c.OnStreamingInsertStart += () => { if (_controller == c) Hide(); };
        c.OnStreamingInsertDone += () => { if (_controller == c) { ResetSession(); Hide(); } };
        c.OnStreamingInsertError += () => { if (_controller == c) ShowAndActivate(); };

        LoadProfiles();
        InputBox.Text = "";
        Render();

        ShowAndActivate();
        UpdateLayout();
        PanelPositioner.Position(this, ctx);
        InputBox.Focus();
        Keyboard.Focus(InputBox);
    }

    private void ShowAndActivate()
    {
        Show();
        Activate();
        Topmost = true;
    }

    private void ResetSession()
    {
        _controller = null;
        _context = null;
    }

    public void Dismiss()
    {
        _controller?.Cancel();
        ResetSession();
        Hide();
    }

    // MARK: - Apply (confirmed insert/replace)

    private void Apply(string result)
    {
        var ctx = _context;
        Hide();
        ResetSession();
        if (ctx is null) return;

        // Refocus the target and type on a background thread (it sleeps). Skip if a
        // new panel is already up, so a stale result never types into a new session.
        Task.Run(() =>
        {
            bool visibleAgain = Dispatcher.Invoke(() => IsVisible);
            if (visibleAgain) return;
            TextTargetService.ApplyResult(result, ctx);
        });
    }

    // MARK: - Rendering

    private void Render()
    {
        var c = _controller;
        if (c is null) return;
        bool transcript = c.ShowsTranscriptUI;

        SelectionPreview.Text = c.SelectionPreview ?? "";
        SelectionPreview.Visibility = string.IsNullOrEmpty(c.SelectionPreview) ? Visibility.Collapsed : Visibility.Visible;

        var result = c.LatestAssistantText;
        bool showResult = transcript && (c.IsStreaming || !string.IsNullOrEmpty(result));
        ResultBox.Visibility = showResult ? Visibility.Visible : Visibility.Collapsed;
        if (showResult)
        {
            ResultText.Text = string.IsNullOrEmpty(result) ? "…" : result;
            ResultScroll.ScrollToEnd();
        }

        ErrorText.Text = c.ErrorMessage ?? "";
        ErrorText.Visibility = string.IsNullOrEmpty(c.ErrorMessage) ? Visibility.Collapsed : Visibility.Visible;

        InputHint.Text = transcript
            ? (c.HasSelection && c.TranscriptIsEmpty ? Loc.L("input.instructFirst") : Loc.L("input.instruct"))
            : Loc.L("input.ask");
        InputHint.Visibility = string.IsNullOrEmpty(InputBox.Text) ? Visibility.Visible : Visibility.Collapsed;

        LoadingRow.Visibility = c.IsStreaming ? Visibility.Visible : Visibility.Collapsed;
        LoadingText.Text = Loc.L("panel.generating");

        bool showApply = c.PendingResult != null;
        ApplyButton.Visibility = showApply ? Visibility.Visible : Visibility.Collapsed;
        ApplyButton.Content = c.HasSelection ? Loc.L("panel.replace") : Loc.L("panel.insert");
    }

    // MARK: - Profiles

    private void LoadProfiles()
    {
        _loadingProfiles = true;
        _profiles = PromptProfile.LoadAll();
        ProfileBox.ItemsSource = _profiles.Select(p => p.Name).ToList();
        ProfileBox.SelectedItem = PromptProfile.ActiveName(_profiles);
        _loadingProfiles = false;
    }

    private void ProfileBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loadingProfiles) return;
        if (ProfileBox.SelectedItem is string name) PromptProfile.SetActive(name, _profiles);
    }

    private void ProfileBox_DropDownClosed(object? sender, EventArgs e)
    {
        // After Ctrl+P picks a profile, hand focus back to the input field. Deferred to
        // Input priority — focus set during DropDownClosed is swallowed as the ComboBox
        // reclaims focus on close.
        Dispatcher.BeginInvoke(new Action(() =>
        {
            InputBox.Focus();
            Keyboard.Focus(InputBox);
        }), DispatcherPriority.Input);
    }

    // MARK: - Input handling

    private void InputBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
        => InputHint.Visibility = string.IsNullOrEmpty(InputBox.Text) ? Visibility.Visible : Visibility.Collapsed;

    private void InputBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;

        if (e.Key == Key.Enter && ctrl) { _controller?.ApplyPending(); e.Handled = true; return; }
        if (e.Key == Key.Enter && !shift) { Send(); e.Handled = true; return; }
        // Shift+Enter falls through → newline (AcceptsReturn).
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { Dismiss(); e.Handled = true; return; }
        if (e.Key == Key.P && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            ProfileBox.IsDropDownOpen = true;
            e.Handled = true;
        }
    }

    private void ApplyButton_Click(object sender, RoutedEventArgs e) => _controller?.ApplyPending();

    private void Send()
    {
        // Only clear on acceptance — a rejected turn (streaming/empty) must keep the text.
        if (_controller?.Send(InputBox.Text) == true) InputBox.Text = "";
    }
}
