using System.Diagnostics;
using System.Collections.ObjectModel;
using System.Windows.Data;
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
    private readonly CheckBox autoAdd = new() { Content = "Suggest dictionary words from corrections for 15 seconds after dictation" };
    private readonly TextBox vocabulary = new() { AcceptsReturn = true, Height = 120, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap };
    private readonly ObservableCollection<SnippetRow> snippets = new();
    private readonly DataGrid snippetGrid = new() { Height = 190, AutoGenerateColumns = false, CanUserAddRows = true, CanUserDeleteRows = true };
    private readonly Func<string, CancellationToken, Task<BridgeReply>> assist;
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
    private readonly Func<AppSettings, string, string, string[], Snippet[], IProgress<double>, CancellationToken, Task> apply;
    private readonly Action resume;
    private bool preparing;
    private bool configReadFailed;
    private CancellationTokenSource? assistanceCancellation;
    private CancellationTokenSource? setupCancellation;

    public SettingsWindow(AppSettings settings, string aiConfigPath,
        Func<AppSettings, string, string, string[], Snippet[], IProgress<double>, CancellationToken, Task> apply, Func<string, CancellationToken, Task<BridgeReply>> assist, Action resume)
    {
        current = settings; selectedShortcut = settings.Shortcut; this.apply = apply; this.assist = assist; this.resume = resume;
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
        foreach (var option in new[] {
            new ProviderOption("auto", "Automatic (installed CLI)"),
            new ProviderOption("claude", "Claude CLI (existing login)"),
            new ProviderOption("codex", "Codex CLI (existing login)"),
            new ProviderOption("gemini-cli", "Gemini CLI (unavailable: local history)"),
            new ProviderOption("gemini", "Gemini API"),
            new ProviderOption("kimi", "Kimi API"),
            new ProviderOption("opencode", "OpenCode API"),
            new ProviderOption("anthropic", "Anthropic API"),
            new ProviderOption("openai", "OpenAI API"),
            new ProviderOption("grok", "Grok API"),
            new ProviderOption("custom", "Custom API (unavailable: model policy)"),
            new ProviderOption("none", "None (plain dictation)")
        }) provider.Items.Add(option);
        JsonNode? document = null, ai = null;
        try { document = JsonNode.Parse(File.ReadAllText(aiConfigPath)); ai = document?["ai"]; }
        catch (FileNotFoundException) { }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException or InvalidOperationException) { configReadFailed = true; status.Text = "Configuration could not be read. Correct the file and reopen Settings before saving."; }
        string ReadAi(string key, string fallback)
        {
            try { return ai?[key]?.GetValue<string>() ?? fallback; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return fallback; }
        }
        provider.SelectedItem = provider.Items.Cast<ProviderOption>().FirstOrDefault(option => option.Id == ReadAi("provider", "auto")) ?? provider.Items[0];
        model.Text = "economy"; model.IsReadOnly = true;
        provider.SelectionChanged += (_, _) => model.Text = "economy";
        stack.Children.Add(provider); stack.Children.Add(new TextBlock { Text = "Model", Margin = new Thickness(0, 7, 0, 3) }); stack.Children.Add(model);
        stack.Children.Add(Description("Auto uses installed Claude or Codex. Sona uses a fixed economical model and no local provider session history. Gemini CLI and Custom are unavailable under this policy. API routes may need credentials and account charges still apply. Sona does not sign you in or store credentials."));
        stack.Children.Add(Description("Model is fixed to the reviewed economical preset. Open AI configuration for an executable, endpoint or API key environment-variable name; stored model overrides are not used."));
        var advanced = new Button { Content = "Open AI configuration", HorizontalAlignment = HorizontalAlignment.Left };
        advanced.Click += (_, _) =>
        {
            if (!File.Exists(aiConfigPath)) File.WriteAllText(aiConfigPath, "{\n  \"ai\": { \"provider\": \"auto\", \"model\": \"economy\", \"timeoutMs\": 15000 },\n  \"vocabulary\": []\n}\n");
            Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = false, ArgumentList = { aiConfigPath } });
        }; stack.Children.Add(advanced);
        Label(stack, "Vocabulary");
        try { vocabulary.Text = string.Join("\n", document?["vocabulary"]?.AsArray().Select(v => v!.GetValue<string>()) ?? Enumerable.Empty<string>()); }
        catch { configReadFailed = true; status.Text = "Vocabulary could not be read. Correct the configuration file and reopen Settings before saving."; }
        stack.Children.Add(Description("One word or phrase per line. Add, edit or remove entries here. Vocabulary guides optional AI cleanup; it does not retrain the local speech engine.")); stack.Children.Add(vocabulary);
        Label(stack, "Snippets");
        try { foreach (var row in document?["snippets"]?.AsArray() ?? new JsonArray()) snippets.Add(new() { Trigger = row!["trigger"]!.GetValue<string>(), Expansion = row["expansion"]!.GetValue<string>() }); }
        catch { configReadFailed = true; status.Text = "Snippets could not be read. Correct the configuration file and reopen Settings before saving."; }
        snippetGrid.ItemsSource = snippets;
        snippetGrid.Columns.Add(new DataGridTextColumn { Header = "Spoken trigger", Binding = new Binding(nameof(SnippetRow.Trigger)), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        snippetGrid.Columns.Add(new DataGridTextColumn { Header = "Expansion", Binding = new Binding(nameof(SnippetRow.Expansion)), Width = new DataGridLength(2, DataGridLengthUnitType.Star) });
        stack.Children.Add(snippetGrid);
        var snippetButtons = new StackPanel { Orientation = Orientation.Horizontal };
        var addSnippet = new Button { Content = "Add / edit selected…", Margin = new Thickness(0, 6, 8, 0) };
        addSnippet.Click += (_, _) => EditSnippet(snippetGrid.SelectedItem as SnippetRow);
        var deleteSnippet = new Button { Content = "Delete selected", Margin = new Thickness(0, 6, 0, 0) };
        deleteSnippet.Click += (_, _) => { if (snippetGrid.SelectedItem is SnippetRow row) snippets.Remove(row); };
        snippetButtons.Children.Add(addSnippet); snippetButtons.Children.Add(deleteSnippet); stack.Children.Add(snippetButtons);
        stack.Children.Add(Description("Literal phrase expansion runs before optional AI cleanup. No commands, macros or recursive expansion. New rows are saved only with Save."));
        Label(stack, "Optional setup assistance");
        var context = new TextBox { Height = 80, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 12000, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        stack.Children.Add(Description("Describe snippets you want. Only the context you type here is sent to your saved provider when you click Suggest. Proposals must be reviewed, added to the editor and saved. No automatic setup calls.")); stack.Children.Add(context);
        var suggest = new Button { Content = "Suggest snippets for review", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        string savedProvider = ReadAi("provider", "none");
        void AssistAvailable() => suggest.IsEnabled = File.Exists(aiConfigPath) && savedProvider is not ("none" or "gemini-cli" or "custom") && (provider.SelectedItem as ProviderOption)?.Id == savedProvider;
        AssistAvailable(); provider.SelectionChanged += (_, _) => { assistanceCancellation?.Cancel(); AssistAvailable(); };
        suggest.Click += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(context.Text)) { status.Text = "Enter context, or add snippets manually above."; return; }
            suggest.IsEnabled = false;
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(35)); assistanceCancellation = cancellation;
            try
            {
                var reply = await assist(context.Text, cancellation.Token);
                if (reply.Status == "ok" && reply.Snippets is { Length: > 0 }) ReviewProposals(reply.Snippets);
                else status.Text = "No proposals are available. Add or edit snippets manually. Your settings were not changed.";
            }
            catch { status.Text = "Assistance could not complete. Use the manual snippet editor."; }
            finally { assistanceCancellation = null; AssistAvailable(); }
        }; stack.Children.Add(suggest);
        stack.Children.Add(Description("Save provider changes first. Assistance is unavailable with None, Gemini CLI or Custom; it never switches providers or starts a login."));
        Label(stack, "Correction suggestions"); autoAdd.IsChecked = settings.AutoAddToDictionary; stack.Children.Add(autoAdd);
        stack.Children.Add(Description("Off by default. When enabled, Sona supports initially empty plain-text fields and single-line ASCII dictation up to 4096 characters. For up to 15 seconds, select a whole alphabetic word, replace it with letter keys and pause 500 ms. Backspace, punctuation and later clicks stop this first capability. It stops on outside typing, navigation, paste, focus change, a new recording or an ambiguous range before reading changed text. Only a possible single-word replacement is offered for your confirmation. No word is saved silently and no document history is saved. Unsupported fields are skipped."));
        Label(stack, "Node executable (optional override)"); node.Text = settings.NodePath ?? ""; stack.Children.Add(node);
        stack.Children.Add(Description("The installer includes Node for the shared cleanup bridge. An existing Node 20+ installation can also be used; Gemini CLI requires Node 24+."));
        login.IsChecked = settings.StartAtLogin; login.Margin = new Thickness(0, 12, 0, 10); stack.Children.Add(login);
        stack.Children.Add(Description("First setup downloads the verified multilingual Whisper base model, about 148 MB. The model stays in your local Sona folder. Sona keeps recordings and the last transcript in memory. Selected AI providers have their own retention policies."));
        stack.Children.Add(progress); stack.Children.Add(status); stack.Children.Add(save);
        var cancelSetup = new Button { Content = "Cancel setup download", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        cancelSetup.Click += (_, _) => setupCancellation?.Cancel(); stack.Children.Add(cancelSetup);
        save.Click += async (_, _) => await SaveAsync();
        Closing += (_, e) => { if (preparing) { e.Cancel = true; setupCancellation?.Cancel(); status.Text = "Cancelling setup…"; } };
        Closed += (_, _) => { assistanceCancellation?.Cancel(); resume(); };
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
        selectedShortcut = value; shortcutButton.Content = HotkeyService.Label(value);
        status.Text = "Shortcut ready. Save to activate it.";
    }
    private async Task SaveAsync()
    {
        if (preparing) return;
        if (configReadFailed) { status.Text = "The existing configuration was not fully read. Correct it with Open AI configuration and reopen Settings. Nothing has been saved."; return; }
        assistanceCancellation?.Cancel();
        preparing = true; save.IsEnabled = false; capturing = false;
        setupCancellation = new CancellationTokenSource();
        status.Text = "Preparing local speech recognition…";
        try
        {
            var next = current with
            {
                SetupComplete = true, Shortcut = selectedShortcut, AutoAddToDictionary = autoAdd.IsChecked == true, CleanupEnabled = cleanup.IsChecked == true,
                MicrophoneId = (devices.SelectedItem as DeviceOption)?.Id, Language = language.SelectedItem as string ?? "auto",
                NodePath = node.Text, StartAtLogin = login.IsChecked == true
            };
            snippetGrid.CommitEdit(DataGridEditingUnit.Cell, true); snippetGrid.CommitEdit(DataGridEditingUnit.Row, true);
            var words = FeatureConfig.Vocabulary(vocabulary.Text.Replace("\r", "").Split('\n'));
            var entries = FeatureConfig.Snippets(snippets.Select(row => new Snippet(row.Trigger, row.Expansion)));
            await apply(next.Validate(), (provider.SelectedItem as ProviderOption)?.Id ?? "auto", model.Text.Trim(), words, entries, new Progress<double>(p =>
            {
                progress.Value = p; status.Text = $"Preparing the local speech model… {p:P0}";
            }), setupCancellation.Token);
            preparing = false; Close();
        }
        catch (OperationCanceledException) { status.Text = "Setup cancelled. Your previous configuration is unchanged."; }
        catch (Exception e) { status.Text = e.Message; }
        finally { preparing = false; save.IsEnabled = true; setupCancellation?.Dispose(); setupCancellation = null; }
    }
    private void EditSnippet(SnippetRow? row)
    {
        var trigger = new TextBox { Text = row?.Trigger ?? "", Margin = new Thickness(0, 0, 0, 12) };
        var expansion = new TextBox { Text = row?.Expansion ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 180, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var content = new StackPanel { Margin = new Thickness(20) }; content.Children.Add(new TextBlock { Text = "Spoken trigger" }); content.Children.Add(trigger); content.Children.Add(new TextBlock { Text = "Literal expansion" }); content.Children.Add(expansion);
        var button = new Button { Content = "Apply to editor", Margin = new Thickness(0, 12, 0, 0) }; content.Children.Add(button);
        var dialog = new Window { Title = "Edit snippet", Width = 480, Height = 340, Content = content, Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        button.Click += (_, _) =>
        {
            try
            {
                var proposal = new Snippet(trigger.Text.Trim(), expansion.Text);
                FeatureConfig.Snippets(snippets.Where(s => s != row).Select(s => new Snippet(s.Trigger, s.Expansion)).Append(proposal));
                if (row != null) snippets.Remove(row); snippets.Add(new() { Trigger = proposal.Trigger, Expansion = proposal.Expansion }); dialog.Close();
            }
            catch (Exception e) { MessageBox.Show(dialog, e.Message, "Snippet validation"); }
        }; dialog.ShowDialog();
    }
    private void ReviewProposals(Snippet[] proposals)
    {
        var content = new StackPanel { Margin = new Thickness(20) };
        var choices = proposals.Select(p => (Snippet: p, Check: new CheckBox { Content = new TextBlock { Text = p.Trigger + "\n" + p.Expansion, TextWrapping = TextWrapping.Wrap }, Margin = new Thickness(0, 0, 0, 18), IsChecked = false })).ToArray();
        foreach (var choice in choices) content.Children.Add(choice.Check);
        var add = new Button { Content = "Add checked proposals to editor" }; content.Children.Add(add);
        var dialog = new Window { Title = "Review snippet proposals", Width = 560, Height = 550, Owner = this, Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        add.Click += (_, _) =>
        {
            try
            {
                var accepted = choices.Where(c => c.Check.IsChecked == true).Select(c => c.Snippet).ToArray();
                FeatureConfig.Snippets(snippets.Select(s => new Snippet(s.Trigger, s.Expansion)).Concat(accepted));
                foreach (var p in accepted) snippets.Add(new() { Trigger = p.Trigger, Expansion = p.Expansion });
                dialog.Close(); status.Text = "Reviewed proposals are in the editor. Save to persist them.";
            }
            catch (Exception e) { MessageBox.Show(dialog, e.Message, "Snippet validation"); }
        }; dialog.ShowDialog();
    }
    public sealed class SnippetRow { public string Trigger { get; set; } = ""; public string Expansion { get; set; } = ""; }
    private sealed record ProviderOption(string Id, string Label) { public override string ToString() => Label; }
    private sealed record DeviceOption(string? Id, string Name) { public override string ToString() => Name; }
}
