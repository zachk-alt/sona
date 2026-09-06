using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Sona.Core;
using Forms = System.Windows.Forms;

namespace Sona.Windows;

internal sealed class App : Application
{
    private readonly string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sona");
    private string ConfigPath => Path.Combine(data, "settings.json");
    private string AiPath => Path.Combine(data, "ai.json");
    private string ModelPath => Path.Combine(data, "models", "ggml-base.bin");
    private AppSettings settings = new();
    private Mutex? instance;
    private Forms.NotifyIcon? tray;
    private HotkeyService? hotkey;
    private RecordingPanel? panel;
    private SettingsWindow? preferences;
    private readonly AudioRecorder recorder = new();
    private readonly Transcriber transcriber = new();
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(8) };
    private readonly DispatcherTimer limit = new();
    private CancellationTokenSource? operation;
    private FocusTarget? target;
    private bool ready, busy, recording, quitting;
    private string latest = "";
    private System.Media.SoundPlayer? startCue, stopCue;

    [STAThread]
    public static void Main(string[] args)
    {
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (args.Length >= 2 && args[0] == "--self-test")
        {
            app.Startup += async (_, _) =>
            {
                try { await WindowsSelfTest.RunAsync(args[1], args.Length >= 4 && args[2] == "--fixture" ? args[3] : null); app.Shutdown(0); }
                catch (Exception e) { if (!File.Exists(args[1])) File.WriteAllText(args[1], JsonSerializer.Serialize(new { success = false, error = e.GetType().Name, message = e.Message })); app.Shutdown(1); }
            };
        }
        else app.Startup += async (_, _) => await app.InitializeAsync();
        app.Run();
    }
    private async Task InitializeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != System.Runtime.InteropServices.Architecture.X64)
        {
            MessageBox.Show("This Sona build requires Windows 11 x64. ARM64 and Windows 10 are not supported by this release.", "Sona"); Shutdown(1); return;
        }
        instance = new Mutex(true, "Local\\Sona.Dictation", out bool first);
        if (!first) { MessageBox.Show("Sona is already running in the system tray.", "Sona"); Shutdown(); return; }
        Directory.CreateDirectory(data);
        settings = SettingsStore.Load(ConfigPath);
        using var resource = GetResourceStream(new Uri("pack://application:,,,/Assets/Sona.ico"))!.Stream;
        using var icon = new System.Drawing.Icon(resource);
        tray = new Forms.NotifyIcon { Icon = (System.Drawing.Icon)icon.Clone(), Text = "Sona", Visible = true };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => Dispatcher.Invoke(OpenSettings));
        menu.Items.Add("Copy last dictation", null, (_, _) => Dispatcher.Invoke(() =>
        {
            if (latest.Length == 0) { Notify("There is no dictation to copy yet."); return; }
            try { Clipboard.SetText(latest); Notify("Last dictation copied."); } catch { Notify("The clipboard is busy. Try again."); }
        }));
        menu.Items.Add("Review last dictation…", null, (_, _) => Dispatcher.Invoke(ReviewLatest));
        menu.Items.Add("Cancel recording or processing", null, (_, _) => Dispatcher.InvokeAsync(CancelAsync));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Sona", null, (_, _) => Dispatcher.InvokeAsync(QuitAsync));
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => Dispatcher.Invoke(OpenSettings);
        tray.BalloonTipClicked += (_, _) => Dispatcher.Invoke(ReviewLatest);
        hotkey = new HotkeyService(); hotkey.Triggered += async () => await ToggleAsync();
        panel = new RecordingPanel();
        recorder.Level += v => Dispatcher.BeginInvoke(() => panel?.SetLevel(v));
        recorder.UnexpectedStop += e => Dispatcher.BeginInvoke(async () => { await CancelAsync(); Notify("The microphone stopped. Check your selected device and Windows microphone access."); });
        limit.Tick += async (_, _) => { limit.Stop(); if (recording) await FinishAsync(); };
        startCue = LoadCue("start.wav"); stopCue = LoadCue("stop.wav");
        if (!settings.SetupComplete) { OpenSettings(); return; }
        try
        {
            ready = await VerifiedDownloader.IsValidAsync(ModelPath, VerifiedDownloader.BaseModel);
            if (ready) ResumeShortcut(); else OpenSettings();
        }
        catch { OpenSettings(); }
    }
    private System.Media.SoundPlayer? LoadCue(string name)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "sounds", name);
        if (!File.Exists(path)) return null;
        try { var sound = new System.Media.SoundPlayer(path); sound.Load(); return sound; } catch { return null; }
    }
    private void ResumeShortcut()
    {
        if (!ready || preferences != null || busy) return;
        try { hotkey?.Configure(settings.Shortcut); }
        catch (Exception e) { Notify(e.Message); }
    }
    private void OpenSettings()
    {
        if (busy) { Notify("Finish or cancel this dictation before opening settings."); return; }
        if (preferences != null) { preferences.Activate(); return; }
        hotkey?.Disable();
        preferences = new SettingsWindow(settings, AiPath, ApplySettingsAsync, () => { preferences = null; ResumeShortcut(); });
        preferences.Show();
    }
    private async Task ApplySettingsAsync(AppSettings next, string provider, string model, IProgress<double> progress, CancellationToken cancellation)
    {
        // Verify availability while the settings window owns focus, then disable until setup finishes.
        hotkey!.Configure(next.Shortcut); hotkey.Disable();
        await new VerifiedDownloader(http).DownloadAsync(ModelPath, VerifiedDownloader.BaseModel, progress, cancellation);
        JsonObject document;
        try { document = JsonNode.Parse(File.ReadAllText(AiPath))?.AsObject() ?? new(); }
        catch (FileNotFoundException) { document = new(); }
        catch (JsonException) { throw new InvalidDataException("AI configuration is invalid JSON. Open it and correct it before saving."); }
        var ai = document["ai"] as JsonObject ?? new JsonObject();
        string? previousProvider = ai["provider"]?.GetValue<string>();
        if (previousProvider != provider)
        {
            // A different provider starts with its own default transport selectors.
            // Credential values never live here; only API environment-variable names do.
            ai.Remove("endpoint"); ai.Remove("apiKeyEnv");
            ai.Remove("executable"); ai.Remove("args");
        }
        ai["provider"] = provider; ai["model"] = string.IsNullOrEmpty(model) ? "economy" : model;
        ai["timeoutMs"] ??= 15000; document["ai"] = ai; document["vocabulary"] ??= new JsonArray();
        string temporary = AiPath + ".tmp";
        File.WriteAllText(temporary, document.ToJsonString(SettingsStore.JsonOptions)); File.Move(temporary, AiPath, true);
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (next.StartAtLogin) key.SetValue("Sona", "\"" + Environment.ProcessPath + "\""); else key.DeleteValue("Sona", false);
        SettingsStore.Save(ConfigPath, next); settings = next; ready = true;
    }
    private async Task ToggleAsync()
    {
        if (recording) { await FinishAsync(); return; }
        if (busy) return;
        if (!ready) { OpenSettings(); return; }
        busy = true;
        try
        {
            target = await TextInsertion.CaptureAsync();
            if (target == null) { Notify("Place the cursor in an editable, non-password text field, then tap your shortcut."); busy = false; return; }
            operation = new CancellationTokenSource();
            recorder.Start(settings.MicrophoneId);
            recording = true; panel!.Recording(target.Window, HotkeyService.Label(settings.Shortcut));
            try { startCue?.Play(); } catch { }
            limit.Interval = TimeSpan.FromSeconds(settings.MaximumRecordingSeconds); limit.Start();
            tray!.Text = "Sona: recording";
        }
        catch { Reset(); Notify("Sona could not open the microphone. Check Windows microphone privacy settings and your selected device."); }
    }
    private async Task FinishAsync()
    {
        if (!recording) return;
        recording = false; limit.Stop(); panel!.Processing(); tray!.Text = "Sona: processing";
        try
        {
            var audio = await recorder.StopAsync();
            try { stopCue?.Play(); } catch { }
            bool audible = recorder.HasSpeech; recorder.Dispose();
            if (!audible || audio.Length < 4000) { Notify("No speech was detected. Try speaking a little closer to the microphone."); return; }
            operation!.CancelAfter(TimeSpan.FromMinutes(2));
            var text = await transcriber.TranscribeAsync(audio, ModelPath, settings.Language, operation.Token);
            if (string.IsNullOrWhiteSpace(text)) { Notify("No speech was detected."); return; }
            if (settings.CleanupEnabled)
            {
                panel.Processing("Polishing");
                var bridge = Path.Combine(AppContext.BaseDirectory, "bridge", "sona-cleanup.mjs");
                if (File.Exists(bridge))
                {
                    string bundledNode = Path.Combine(AppContext.BaseDirectory, "runtime", "node", "node.exe");
                    string node = settings.NodePath ?? (File.Exists(bundledNode) ? bundledNode : "node.exe");
                    var result = await BoundedProcess.RunAsync(node, [bridge, "--config", AiPath], text, TimeSpan.FromSeconds(35), operation.Token);
                    text = result.Output; // The bridge and caller both preserve original text on failure.
                }
            }
            operation.Token.ThrowIfCancellationRequested();
            latest = text;
            bool pasted = target != null && await TextInsertion.PasteAsync(target, text);
            if (!pasted) Notify("Dictation is ready. Focus changed or this field blocked safe pasting. Use Copy last dictation in the Sona tray menu.");
        }
        catch (OperationCanceledException) { if (!quitting) Notify("Dictation cancelled."); }
        catch (Exception e)
        {
            string message = e is DllNotFoundException or TypeInitializationException
                ? "The local speech runtime could not load. Run the Sona installer to repair its Microsoft Visual C++ dependency."
                : "Dictation could not finish. Check your microphone and retry. No text was inserted.";
            Notify(message);
        }
        finally { Reset(); }
    }
    private async Task CancelAsync()
    {
        operation?.Cancel();
        if (recording)
        {
            recording = false; limit.Stop();
            try { await recorder.StopAsync(); } catch { }
            Reset();
        }
    }
    private void Reset()
    {
        limit.Stop(); recorder.Dispose(); panel?.Dismiss(); recording = false; busy = false; target = null;
        operation?.Dispose(); operation = null; if (tray != null) tray.Text = "Sona";
    }
    private void Notify(string message)
    {
        if (quitting) return;
        tray?.ShowBalloonTip(5000, "Sona", message, Forms.ToolTipIcon.Info);
    }
    private void ReviewLatest()
    {
        if (latest.Length == 0) { Notify("There is no dictation to review yet."); return; }
        var text = new TextBox { Text = latest, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(20), FontSize = 18 };
        new Window { Title = "Last dictation · Sona", Width = 600, Height = 360, Content = text, WindowStartupLocation = WindowStartupLocation.CenterScreen }.Show();
    }
    private async Task QuitAsync()
    {
        quitting = true; hotkey?.Disable(); await CancelAsync();
        // Native inference receives cancellation. Do not dispose its factory while a call is active.
        if (!busy) transcriber.Dispose();
        panel?.Close(); tray?.Dispose(); startCue?.Dispose(); stopCue?.Dispose(); hotkey?.Dispose(); http.Dispose(); instance?.Dispose();
        Shutdown();
    }
}
