using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Sona.Core;

namespace Sona.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly AppSettings current;
    private Shortcut selectedShortcut;
    private bool capturing;
    private bool chordCaptured;
    private readonly Button shortcutButton = new();
    private readonly CheckBox cleanup = new() { Content = "Use my existing AI account for cleanup" };
    private readonly CheckBox login = new() { Content = "Open Sona when I sign in" };
    private readonly ComboBox devices = new();
    private readonly ComboBox language = new();
    private readonly ComboBox provider = new();
    private readonly TextBox model = new();
    private readonly TextBox node = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.SteelBlue };
    private readonly ProgressBar progress = new() { Minimum = 0, Maximum = 1, Height = 5, Margin = new Thickness(0, 8, 0, 8) };
    private readonly Button save = new() { Content = "Save and prepare Sona", Padding = new Thickness(16, 9, 16, 9), HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Func<AppSettings, string, string, IProgress<double>, CancellationToken, Task> apply;
    private readonly Action resume;
    private bool preparing;
    private CancellationTokenSource? setupCancellation;

    public SettingsWindow(AppSettings settings, string aiConfigPath,
        Func<AppSettings, string, string, IProgress<double>, CancellationToken, Task> apply, Action resume)
    {
        current = settings; selectedShortcut = settings.Shortcut; this.apply = apply; this.resume = resume;
        Title = settings.SetupComplete ? "Sona settings" : "Welcome to Sona";
        Width = 550; Height = 770; MinWidth = 470; MinHeight = 570; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(247, 248, 250));
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/SonaAppIcon.png"));
        var stack = new StackPanel { Margin = new Thickness(30, 24, 30, 28) };
        Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        stack.Children.Add(new TextBlock { Text = "Your voice. Your shortcut.", FontSize = 27, FontWeight = FontWeights.SemiBold });
        stack.Children.Add(Description("Tap once to record, tap again to finish. Sona transcribes on this PC and pastes only if the original text field still has focus."));
        Label(stack, "Keyboard shortcut");
        shortcutButton.Content = HotkeyService.Label(selectedShortcut); shortcutButton.Padding = new Thickness(14, 9, 14, 9);
        shortcutButton.Click += (_, _) => { capturing = true; chordCaptured = false; shortcutButton.Content = "Press a key or chord…"; shortcutButton.Focus(); };
        shortcutButton.PreviewKeyDown += CaptureDown; shortcutButton.PreviewKeyUp += CaptureUp;
        stack.Children.Add(shortcutButton);
        stack.Children.Add(Description("Click to choose a single key or chord. A bare letter is reserved while Sona runs. A modifier tap must be short; normal modifier shortcuts still work. F12 and Windows-only keys are reserved."));
        Label(stack, "Microphone"); devices.Items.Add(new DeviceOption(null, "Windows default communications microphone"));
        try { foreach (var d in AudioRecorder.Devices()) devices.Items.Add(new DeviceOption(d.Id, d.Name)); }
        catch { status.Text = "No microphone is available. Check Windows sound and privacy settings."; }
        devices.SelectedItem = devices.Items.Cast<DeviceOption>().FirstOrDefault(x => x.Id == settings.MicrophoneId) ?? devices.Items[0]; stack.Children.Add(devices);
        var privacy = new Button { Content = "Open microphone privacy settings", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        privacy.Click += (_, _) => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); stack.Children.Add(privacy);
        stack.Children.Add(Description("Windows must allow microphone access and let desktop apps access your microphone. Desktop apps do not always show an individual permission prompt. Sona opens the microphone only while recording."));
        Label(stack, "Speech language");
        foreach (var l in new[] { "auto", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "hi", "ar" }) language.Items.Add(l);
        language.SelectedItem = settings.Language; if (language.SelectedIndex < 0) language.SelectedIndex = 0; stack.Children.Add(language);
        Label(stack, "Optional AI cleanup"); cleanup.IsChecked = settings.CleanupEnabled; stack.Children.Add(cleanup);
        foreach (var p in new[] { "auto", "claude", "codex", "gemini", "kimi", "opencode", "anthropic", "openai", "grok", "custom", "none" }) provider.Items.Add(p);
        JsonNode? ai = null;
        try { ai = JsonNode.Parse(File.ReadAllText(aiConfigPath))?["ai"]; } catch (Exception e) when (e is IOException or System.Text.Json.JsonException or InvalidOperationException) { }
        string ReadAi(string key, string fallback)
        {
            try { return ai?[key]?.GetValue<string>() ?? fallback; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return fallback; }
        }
        provider.SelectedItem = ReadAi("provider", "auto");
        if (provider.SelectedIndex < 0) provider.SelectedItem = "auto";
        model.Text = ReadAi("model", "economy");
        stack.Children.Add(provider); stack.Children.Add(new TextBlock { Text = "Model", Margin = new Thickness(0, 7, 0, 3) }); stack.Children.Add(model);
        stack.Children.Add(Description("Auto uses a supported CLI already signed in on this PC. AI account limits and charges still apply. API providers require an explicitly configured endpoint and an environment variable for the key. Sona does not store credentials."));
        var advanced = new Button { Content = "Open AI configuration", HorizontalAlignment = HorizontalAlignment.Left };
        advanced.Click += (_, _) =>
        {
            if (!File.Exists(aiConfigPath)) File.WriteAllText(aiConfigPath, "{\n  \"ai\": { \"provider\": \"auto\", \"model\": \"economy\", \"timeoutMs\": 15000 },\n  \"vocabulary\": []\n}\n");
            Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = false, ArgumentList = { aiConfigPath } });
        }; stack.Children.Add(advanced);
        Label(stack, "Node executable (optional override)"); node.Text = settings.NodePath ?? ""; stack.Children.Add(node);
        stack.Children.Add(Description("The installer includes Node for the shared cleanup bridge. An existing Node 20+ installation can also be used."));
        login.IsChecked = settings.StartAtLogin; login.Margin = new Thickness(0, 12, 0, 10); stack.Children.Add(login);
        stack.Children.Add(Description("First setup downloads the verified multilingual Whisper base model, about 148 MB. The model stays in your local Sona folder. Recordings and transcripts are kept in memory, not written to a history."));
        stack.Children.Add(progress); stack.Children.Add(status); stack.Children.Add(save);
        var cancelSetup = new Button { Content = "Cancel setup download", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        cancelSetup.Click += (_, _) => setupCancellation?.Cancel(); stack.Children.Add(cancelSetup);
        save.Click += async (_, _) => await SaveAsync();
        Closing += (_, e) => { if (preparing) { e.Cancel = true; setupCancellation?.Cancel(); status.Text = "Cancelling setup…"; } };
        Closed += (_, _) => resume();
    }
    private static TextBlock Description(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Color.FromRgb(82, 91, 107)), Margin = new Thickness(0, 7, 0, 10) };
    private static void Label(Panel panel, string text) => panel.Children.Add(new TextBlock { Text = text, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 13, 0, 6) });
    private void CaptureDown(object sender, KeyEventArgs e)
    {
        if (!capturing) return;
        e.Handled = true; if (e.IsRepeat) return;
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        int vk = KeyInterop.VirtualKeyFromKey(key);
        if (vk is >= 0xA0 and <= 0xA5 || vk is 0x5B or 0x5C) return;
        uint modifiers = 0;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= 2;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= 1;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= 4;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) modifiers |= 8;
        chordCaptured = true; Choose(new Shortcut(vk, modifiers));
    }
    private void CaptureUp(object sender, KeyEventArgs e)
    {
        if (!capturing) return;
        e.Handled = true;
        int vk = KeyInterop.VirtualKeyFromKey(e.Key == Key.System ? e.SystemKey : e.Key);
        if (!chordCaptured && vk is >= 0xA0 and <= 0xA5) Choose(new Shortcut(vk, 0));
    }
    private void Choose(Shortcut value)
    {
        capturing = false;
        if (!value.IsValid) { status.Text = "That key is reserved. Choose another shortcut."; shortcutButton.Content = HotkeyService.Label(selectedShortcut); return; }
        selectedShortcut = value; shortcutButton.Content = HotkeyService.Label(value); status.Text = "Shortcut ready. Save to activate it.";
    }
    private async Task SaveAsync()
    {
        if (preparing) return;
        preparing = true; save.IsEnabled = false; capturing = false;
        setupCancellation = new CancellationTokenSource();
        status.Text = "Preparing local speech recognition…";
        try
        {
            var next = current with
            {
                SetupComplete = true, Shortcut = selectedShortcut, CleanupEnabled = cleanup.IsChecked == true,
                MicrophoneId = (devices.SelectedItem as DeviceOption)?.Id, Language = language.SelectedItem as string ?? "auto",
                NodePath = node.Text, StartAtLogin = login.IsChecked == true
            };
            await apply(next.Validate(), provider.SelectedItem as string ?? "auto", model.Text.Trim(), new Progress<double>(p =>
            {
                progress.Value = p; status.Text = $"Preparing the local speech model… {p:P0}";
            }), setupCancellation.Token);
            preparing = false; Close();
        }
        catch (OperationCanceledException) { status.Text = "Setup cancelled. Your previous configuration is unchanged."; }
        catch (Exception e) { status.Text = e.Message; }
        finally { preparing = false; save.IsEnabled = true; setupCancellation?.Dispose(); setupCancellation = null; }
    }
    private sealed record DeviceOption(string? Id, string Name) { public override string ToString() => Name; }
}
