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
    private string ModelPath(SpeechModel model) => Path.Combine(data, "models", model.FileName);
    private string ParakeetFolder => Path.Combine(data, "models", SpeechModels.Parakeet.FolderName);
    // English dictation switches to Parakeet only after all of its files verify; until then it runs on Whisper base.en.
    private bool parakeetVerified;
    private CancellationTokenSource? parakeetDownload;
    // The verified model file dictation runs: the language's own model, or for an English install from before
    // the English-only model, its verified multilingual model until Settings downloads base.en.
    private SpeechModel? activeModel;
    private AppSettings settings = new();
    private Mutex? instance;
    private Forms.NotifyIcon? tray;
    private System.Drawing.Icon? idleIcon, activeIcon;
    private HotkeyService? hotkey;
    private RecordingPanel? panel;
    private SettingsWindow? preferences;
    private readonly AudioRecorder recorder = new();
    private readonly Transcriber transcriber = new();
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(8) };
    private readonly DispatcherTimer limit = new();
    // Shows the recording panel when the first live audio is late (DictationDeadlines.FirstAudio).
    private readonly DispatcherTimer firstAudio = new();
    private RecordingStart? recordingStart;
    private nint recordingWindow;
    private CancellationTokenSource? operation;
    private FocusTarget? target;
    private UiaSession? selectionSession, learningSession;
    private readonly CorrectionLease learningLease = new(() => Environment.TickCount64);
    private CancellationTokenSource? learningCancellation;
    private WordCorrection? correction;
    private bool ready, busy, recording, quitting;
    private string latest = "";
    // Numbers each dictation, and names the one whose text is in latest, so a late result never replaces newer text.
    private int session, deliveredSession;
    // Strict cleanup for code editors and terminals, from the app focused when the dictation started.
    private CleanupMode sessionMode;
    private string? sessionFailure;
    private System.Media.SoundPlayer? startCue, stopCue;

    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length == 1 && args[0] is "--uia-session" or "--uia-session-test")
        {
            var worker = new Thread(() => UiaWorker.Run(args[0] == "--uia-session-test")); worker.SetApartmentState(ApartmentState.MTA); worker.Start(); worker.Join(); return;
        }
        // Old worker invocations are inert, even if another process still has their names.
        if (args.Length == 1 && args[0] is "--assistant-context" or "--assistant-context-test" or "--assistant-action") return;
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (args.Length >= 2 && args[0] == "--panel-preview")
        {
            // Offscreen panel renders for visual review. Never opens the microphone, hotkeys, network, settings or tray.
            app.Startup += (_, _) =>
            {
                try { PanelPreview.Write(args[1]); app.Shutdown(0); }
                catch (Exception e)
                {
                    try { Directory.CreateDirectory(args[1]); File.WriteAllText(Path.Combine(args[1], "panel-preview-error.txt"), e.ToString()); } catch { }
                    app.Shutdown(1);
                }
            };
        }
        else if (args.Length >= 2 && args[0] == "--self-test")
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
        idleIcon = (System.Drawing.Icon)icon.Clone(); activeIcon = TrayIcons.Active();
        tray = new Forms.NotifyIcon { Icon = idleIcon, Text = "Sona", Visible = true };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => Dispatcher.Invoke(OpenSettings));
        menu.Items.Add("Copy last dictation", null, (_, _) => Dispatcher.Invoke(() =>
        {
            if (latest.Length == 0) { Notify("There is no dictation to copy yet."); return; }
            try { Clipboard.SetText(latest); Notify("Last dictation copied."); } catch { Notify("The clipboard is busy. Try again."); }
        }));
        menu.Items.Add("Review dictionary suggestion…", null, (_, _) => Dispatcher.Invoke(ReviewCorrection));
        menu.Items.Add("Review last dictation…", null, (_, _) => Dispatcher.Invoke(ReviewLatest));
        menu.Items.Add("Cancel recording or processing", null, (_, _) => Dispatcher.InvokeAsync(CancelAsync));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Sona", null, (_, _) => Dispatcher.InvokeAsync(QuitAsync));
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => Dispatcher.Invoke(OpenSettings);
        tray.BalloonTipClicked += (_, _) => Dispatcher.Invoke(() => { if (correction != null) ReviewCorrection(); else ReviewLatest(); });
        // Anything that still escapes is logged (type and stack only) instead of silently ending Sona.
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => { if (e.ExceptionObject is Exception error) Log("fatal", error); };
        TaskScheduler.UnobservedTaskException += (_, e) => { Log("task", e.Exception); e.SetObserved(); };
        hotkey = new HotkeyService();
        hotkey.Triggered += async () => { try { await ToggleAsync(); } catch (Exception e) { Recover("shortcut", e); } };
        // The shortcut's keyboard hook is re-armed after an unlock or a resume, when Windows is most likely to have dropped it.
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        try { panel = new RecordingPanel(); panel.Prepare(); }
        catch (Exception e)
        {
            // A panel fault leaves dictation working without the panel rather than ending Sona.
            Log("panel", e);
            try { panel?.Close(); } catch { }
            panel = null;
        }
        // Like the Mac, the panel follows the 48 voice bands, only while dictating.
        recorder.Spectrum += bands => Dispatcher.BeginInvoke(() => { if (recording) panel?.SetSpectrum(bands); });
        // The chime, the panel's Recording state and the tray icon follow the microphone's first live audio.
        recorder.FirstAudio += generation => Dispatcher.BeginInvoke(() =>
        {
            if (recording && generation == recorder.Generation) ShowRecording(recordingStart?.AudioArrived() ?? RecordingCue.None);
        });
        firstAudio.Tick += (_, _) =>
        {
            firstAudio.Stop();
            if (recording) ShowRecording(recordingStart?.DeadlinePassed() ?? RecordingCue.None);
        };
        // A microphone that goes away mid-dictation ends the recording early, and what it heard is still transcribed.
        recorder.UnexpectedStop += e => Dispatcher.BeginInvoke(async () =>
        {
            try
            {
                if (!recording) return;
                Log("microphone_stopped", e ?? new IOException());
                Notify("The microphone stopped, so Sona ended the recording early. Check your selected device and Windows microphone access.");
                await FinishAsync();
            }
            catch (Exception error) { Recover("microphone", error); }
        });
        limit.Tick += async (_, _) =>
        {
            try { limit.Stop(); if (recording) await FinishAsync(); }
            catch (Exception e) { Recover("limit", e); }
        };
        startCue = LoadCue("start.wav"); stopCue = LoadCue("stop.wav");
        if (!settings.SetupComplete) { OpenSettings(); return; }
        try
        {
            var wanted = SpeechModels.For(settings.Language);
            if (await VerifiedDownloader.IsValidAsync(ModelPath(wanted), wanted.Download)) activeModel = wanted;
            else if (wanted != SpeechModels.Multilingual && await VerifiedDownloader.IsValidAsync(ModelPath(SpeechModels.Multilingual), SpeechModels.Multilingual.Download))
                activeModel = SpeechModels.Multilingual;
            ready = activeModel != null;
            bool wantsParakeet = SpeechEngines.Preferred(settings.Language) == SpeechEngine.Parakeet;
            // Hashing about 661 MB runs off the UI thread.
            parakeetVerified = wantsParakeet && await Task.Run(() => VerifiedDownloader.IsValidAsync(ParakeetFolder, SpeechModels.Parakeet));
            if (parakeetVerified) _ = transcriber.PreloadParakeetAsync(ParakeetFolder);
            if (activeModel == wanted && (!wantsParakeet || parakeetVerified)) ResumeShortcut();
            // Migration: dictation keeps working on the verified Whisper model; Save in Settings fetches what is missing.
            else if (ready && activeModel == wanted) OpenSettings($"Sona now uses NVIDIA Parakeet as its English engine, with Whisper as the backup. Save to download it once (about {SpeechModels.Parakeet.TotalSize / 1_000_000} MB, in the background). Until it is verified, dictation keeps using Whisper.");
            else if (ready) OpenSettings("Sona now uses Whisper's English-only model as the English backup and NVIDIA Parakeet as the English engine. Save to download them once (about 148 MB, then about " + SpeechModels.Parakeet.TotalSize / 1_000_000 + " MB in the background). Until then, dictation keeps using the current model.");
            else OpenSettings();
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
    private void OpenSettings() => OpenSettings(null);
    private void OpenSettings(string? notice)
    {
        if (busy) { Notify("Finish or cancel this dictation before opening settings."); return; }
        if (preferences != null) { preferences.Activate(); return; }
        StopLearning();
        hotkey?.Disable();
        preferences = new SettingsWindow(settings, AiPath, ApplySettingsAsync, AssistAsync, () => { preferences = null; ResumeShortcut(); }, notice);
        preferences.Show();
    }
    private async Task ApplySettingsAsync(AppSettings next, string provider, string model, string[] vocabulary, Snippet[] snippets, IProgress<double> progress, CancellationToken cancellation)
    {
        // Verify availability while the settings window owns focus, then disable until setup finishes.
        hotkey!.Configure(next.Shortcut); hotkey.Disable();
        StopLearning();
        var speech = SpeechModels.For(next.Language);
        await new VerifiedDownloader(http).DownloadAsync(ModelPath(speech), speech.Download, progress, cancellation);
        JsonObject document;
        try { document = JsonNode.Parse(File.ReadAllText(AiPath)) as JsonObject ?? throw new InvalidDataException("AI configuration must be a JSON object."); }
        catch (FileNotFoundException) { document = new(); }
        catch (JsonException) { throw new InvalidDataException("AI configuration is invalid JSON. Open it and correct it before saving."); }
        var ai = document["ai"] == null ? new JsonObject() : document["ai"] as JsonObject ?? throw new InvalidDataException("The ai field must be a JSON object.");
        string? previousProvider = ai["provider"]?.GetValue<string>();
        if (previousProvider != provider)
        {
            // A different provider starts with its own default transport selectors.
            // Credential values never live here; only API environment-variable names do.
            ai.Remove("endpoint"); ai.Remove("apiKeyEnv");
            ai.Remove("executable"); ai.Remove("args");
        }
        ai["provider"] = provider; ai["model"] = string.IsNullOrEmpty(model) ? "economy" : model;
        ai["timeoutMs"] ??= 15000; document["ai"] = ai; document["vocabulary"] = JsonSerializer.SerializeToNode(FeatureConfig.Vocabulary(vocabulary));
        document["snippets"] = JsonSerializer.SerializeToNode(FeatureConfig.Snippets(snippets), SettingsStore.JsonOptions);
        var appDocument = SettingsStore.MergeDocument(ConfigPath, next);
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        object? oldStartup = key.GetValue("Sona");
        bool registryChanged = false;
        try
        {
            if (next.StartAtLogin) key.SetValue("Sona", "\"" + Environment.ProcessPath + "\""); else key.DeleteValue("Sona", false);
            registryChanged = true;
            FeatureConfig.CommitDocuments((AiPath, document), (ConfigPath, appDocument));
        }
        catch
        {
            if (registryChanged)
            {
                try { if (oldStartup == null) key.DeleteValue("Sona", false); else key.SetValue("Sona", oldStartup); }
                catch { throw new InvalidDataException("Saving settings failed and the startup preference could not be restored. Review Windows startup settings."); }
            }
            throw;
        }
        settings = next; activeModel = speech; ready = true;
        if (SpeechEngines.Preferred(next.Language) == SpeechEngine.Parakeet) StartParakeetDownload();
        else { parakeetDownload?.Cancel(); parakeetVerified = false; transcriber.ReleaseParakeet(); }
    }
    // Runs after the user saved Settings, never before. Dictation stays on Whisper until every Parakeet file verifies.
    private void StartParakeetDownload()
    {
        parakeetDownload?.Cancel();
        var cancellation = parakeetDownload = new CancellationTokenSource();
        _ = DownloadParakeetAsync(cancellation.Token);
    }
    private async Task DownloadParakeetAsync(CancellationToken cancellation)
    {
        bool wasVerified = parakeetVerified;
        try
        {
            // Off the UI thread: about 661 MB to fetch and hash. Files that already verify are kept.
            string folder = ParakeetFolder;
            await Task.Run(() => new VerifiedDownloader(http).DownloadAsync(folder, SpeechModels.Parakeet, null, cancellation), cancellation);
            if (cancellation.IsCancellationRequested || quitting || SpeechEngines.Preferred(settings.Language) != SpeechEngine.Parakeet) return;
            await transcriber.PreloadParakeetAsync(folder);
            parakeetVerified = true;
            // A load failure is already logged and leaves English on Whisper; only a working switch is announced.
            if (!wasVerified && !quitting && transcriber.Health.ShouldTry(folder)) Notify("English dictation now uses NVIDIA Parakeet. Whisper stays as the backup.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception e)
        {
            Log(SpeechEngines.ParakeetDownloadFailed, e);
            if (!quitting) Notify("The Parakeet download did not finish. English dictation keeps using Whisper. Save Settings to try again.");
        }
    }
    private async Task ToggleAsync()
    {
        if (recording) { await FinishAsync(); return; }
        if (busy) return;
        if (!ready) { OpenSettings(); return; }
        StopLearning(); correction = null; sessionFailure = null;
        busy = true; session++;
        try
        {
            operation = new CancellationTokenSource();
            var capture = await TextInsertion.CaptureWithStatusAsync();
            target = capture.Target;
            if (operation.IsCancellationRequested) { Reset(); return; }
            if (target == null)
            {
                Reset();
                Notify(TextInsertion.NotAnswering(capture.Status)
                    ? "That app is not answering Sona yet. Try again in a moment."
                    : "Place the cursor in an editable, non-password text field, then tap your shortcut.");
                return;
            }
            sessionMode = CleanupModes.ForProcess(ProcessName(target.Process));
            recordingStart = new RecordingStart(); recordingWindow = target.Window;
            recorder.Start(settings.MicrophoneId); recording = true;
            firstAudio.Interval = DictationDeadlines.FirstAudio; firstAudio.Start();
            limit.Interval = TimeSpan.FromSeconds(settings.MaximumRecordingSeconds); limit.Start();
        }
        // Shown in the panel, like the Mac.
        catch { sessionFailure = "The microphone is unavailable or switching. Try again."; Reset(); }
    }
    private async Task FinishAsync()
    {
        if (!recording) return;
        recording = false; limit.Stop(); firstAudio.Stop();
        int id = session;
        try
        {
            ShowPanel(() => panel?.Processing()); if (tray != null) tray.Text = "Sona: processing";
            // Listen a moment longer, then close the microphone. The stop cue follows the close, so it is never recorded.
            await Task.Delay(DictationDeadlines.StopGrace);
            var captured = await recorder.StopAsync();
            // A stop that errored or never confirmed still hands back the audio already recorded.
            if (captured.End != CaptureEnd.Clean) Log(captured.End == CaptureEnd.TimedOut ? "microphone_stop_timeout" : "microphone_stop_failed", captured.Error ?? new IOException());
            var audio = captured.Wav;
            if (recordingStart?.StopCue == true) { try { stopCue?.Play(); } catch { } }
            recorder.Dispose();
            // One conversion, off the UI thread: the speech check judges exactly the 16 kHz mono the engine hears.
            var samples = await Task.Run(() => SpeechAudio.Mono16k(audio));
            if (!SpeechActivity.Detect(samples, SpeechAudio.SampleRate)) { sessionFailure = "No speech was detected."; return; }
            operation!.CancelAfter(TimeSpan.FromSeconds(120));
            var speech = activeModel ?? SpeechModels.For(settings.Language);
            bool onParakeet = SpeechEngines.ForDictation(settings.Language, parakeetVerified) == SpeechEngine.Parakeet;
            var route = new SpeechRoute(ModelPath(speech), SpeechModels.WhisperLanguage(speech, settings.Language), onParakeet ? ParakeetFolder : null);
            var text = (await transcriber.TranscribeAsync(samples, route, operation.Token, late => Dispatcher.BeginInvoke(() => KeepLate(id, late)))).Text;
            if (string.IsNullOrWhiteSpace(text)) { sessionFailure = "No speech was detected."; return; }
            // The exact raw transcript stays in Copy last dictation whatever happens to cleanup or the paste.
            latest = text; deliveredSession = id;
            // Snippets run inside the bridge before optional cleanup, including when cleanup is off.
            string raw = text;
            text = BridgeProtocol.DictationText(await RequestAsync(BridgeProtocol.Dictate(raw, settings.CleanupEnabled, sessionMode), operation.Token), raw);
            operation.Token.ThrowIfCancellationRequested(); latest = text;
            if (target != null) selectionSession = await UiaSession.PrepareCorrectionAsync(settings.AutoAddToDictionary, target);
            bool pasted = target != null && await TextInsertion.PasteAsync(target, text);
            // The Mac shows this one in the panel ("Text is ready in Copy pending text."), not as a notification.
            if (!pasted) sessionFailure = "Text is ready in Copy last dictation.";
            else if (settings.AutoAddToDictionary && selectionSession != null && await selectionSession.ArmAsync(text))
            {
                learningSession = selectionSession; selectionSession = null;
                learningLease.Start(true); learningCancellation = new();
                _ = ObserveCorrectionsAsync(learningSession, target!, learningCancellation.Token);
            }
        }
        catch (OperationCanceledException) { if (!quitting) Notify("Dictation cancelled."); }
        catch (Exception e)
        {
            // Whisper.net caches a failed native load for the life of the process, so a repair needs a restart
            // too. That one needs action and stays a notification; the rest show in the panel, like the Mac.
            if (SpeechRuntimeFailed(e))
                Notify("The local speech runtime could not load. Run the Sona installer to repair its Microsoft Visual C++ dependency, then restart Sona.");
            else sessionFailure = "Dictation could not finish. Try again.";
        }
        finally { Reset(); }
    }
    private async Task CancelAsync()
    {
        StopLearning();
        operation?.Cancel();
        if (recording)
        {
            recording = false; limit.Stop();
            try { await recorder.StopAsync(); } catch { }
            Reset();
        }
    }
    // A transcript that arrived after its dictation stopped waiting (Parakeet past its limit, or the session past its
    // budget) goes to Copy last dictation only, never into whatever is focused now, unless the dictation already
    // delivered text or a newer one has (the Mac's retainLate).
    private void KeepLate(int id, string text)
    {
        if (quitting || deliveredSession >= id) return;
        latest = text; deliveredSession = id;
        // Only while nothing newer owns the panel.
        if (!busy) ShowPanel(() => { if (panel != null) panel.ShowError("Text is ready in Copy last dictation."); else Notify("Text is ready in Copy last dictation."); });
    }
    private static string? ProcessName(uint id)
    {
        try { using var process = Process.GetProcessById((int)id); return process.ProcessName; }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }
    private static bool SpeechRuntimeFailed(Exception e) =>
        e is DllNotFoundException or TypeInitializationException ||
        e.Message.StartsWith("Failed to load native whisper library", StringComparison.Ordinal) ||
        e is FileNotFoundException && e.Message.StartsWith("Native Library not found", StringComparison.Ordinal);
    private void Reset()
    {
        // Flags first, and every step guarded, so no fault below can leave a session half open.
        recording = false; busy = false;
        string? failure = sessionFailure; sessionFailure = null;
        var session = selectionSession; selectionSession = null; target = null;
        Guard(() => session?.Dispose());
        Guard(limit.Stop);
        Guard(firstAudio.Stop);
        Guard(recorder.Dispose);
        if (failure != null && !quitting)
        {
            try { if (panel != null) panel.ShowError(failure); else Notify(failure); }
            catch (Exception e) { Log("reset", e); Guard(() => Notify(failure)); }
        }
        else Guard(() => panel?.Dismiss());
        var done = operation; operation = null;
        Guard(() => done?.Dispose());
        Guard(() => { if (tray != null) { tray.Text = "Sona"; tray.Icon = idleIcon; } });
        Guard(() => hotkey?.Rearm());
    }
    private void ShowRecording(RecordingCue cue)
    {
        // The chime first, like the Mac: it marks the microphone as live.
        if (cue.HasFlag(RecordingCue.Chime)) { try { startCue?.Play(); } catch { } }
        if (!cue.HasFlag(RecordingCue.Show)) return;
        if (tray != null) { tray.Icon = activeIcon; tray.Text = "Sona: recording"; }
        var window = recordingWindow;
        ShowPanel(() => panel?.Recording(window));
    }
    // The panel is feedback only: a fault in it is logged and the panel hidden, and the dictation goes on.
    private void ShowPanel(Action show)
    {
        try { show(); }
        catch (Exception e) { Log("panel", e); Guard(() => panel?.HideNow()); }
    }
    private void Guard(Action step)
    {
        try { step(); } catch (Exception e) { Log("reset", e); }
    }
    // The dictation path itself threw and has unwound: release the microphone, hide the panel and
    // return to ready, the state that used to need a quit and reopen.
    private void Recover(string where, Exception error)
    {
        Log(where, error);
        Guard(() => operation?.Cancel());
        Reset();
        Guard(() => panel?.HideNow());
    }
    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log("dispatcher", e.Exception);
        if (tray == null) return; // Startup failed before the tray existed: end as before rather than run invisibly.
        e.Handled = true;
        // Usually the panel (its frame handler would throw every frame); dictation code recovers on its own path.
        Guard(() => panel?.HideNow());
    }
    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionUnlock) hotkey?.Rearm();
    }
    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) hotkey?.Rearm();
    }
    private static readonly object LogGate = new();
    private static int logEntries;
    /// %LOCALAPPDATA%\Sona\sona.log: where and the exception types and stacks. Never messages, dictated or clipboard text.
    internal static void Log(string where, Exception error)
    {
        try
        {
            if (Interlocked.Increment(ref logEntries) > 200) return;
            var entry = new System.Text.StringBuilder();
            entry.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", System.Globalization.CultureInfo.InvariantCulture)).Append(' ').AppendLine(where);
            for (Exception? e = error; e != null; e = e.InnerException)
                entry.Append("  ").Append(e.GetType().FullName).Append(" 0x").AppendLine(e.HResult.ToString("X8", System.Globalization.CultureInfo.InvariantCulture)).AppendLine(e.StackTrace);
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sona");
            lock (LogGate)
            {
                Directory.CreateDirectory(folder);
                string path = Path.Combine(folder, "sona.log");
                if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024) File.Move(path, path + ".old", true);
                File.AppendAllText(path, entry.ToString());
            }
        }
        catch { }
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
    private async Task<ProcessResult> RequestAsync(string request, CancellationToken cancellation, string? configOverride = null)
    {
        string bridge = Path.Combine(AppContext.BaseDirectory, "bridge", "sona-cleanup.mjs");
        string bundledNode = Path.Combine(AppContext.BaseDirectory, "runtime", "node", "node.exe");
        string node = settings.NodePath ?? (File.Exists(bundledNode) ? bundledNode : "node.exe");
        if (!File.Exists(bridge)) return new(false, "", "bridge_missing");
        return await BoundedProcess.RunAsync(node, [bridge, "--request", "--config", configOverride ?? AiPath], request, TimeSpan.FromSeconds(35), cancellation);
    }
    private async Task<BridgeReply> AssistAsync(string context, CancellationToken cancellation)
        => BridgeProtocol.Parse(await RequestAsync(BridgeProtocol.Assist(context), cancellation), "snippet_assist", context: context);
    private void StopLearning()
    {
        learningLease.Stop(); learningCancellation?.Cancel(); learningSession?.Dispose(); learningSession = null;
        learningCancellation?.Dispose(); learningCancellation = null;
    }
    private async Task ObserveCorrectionsAsync(UiaSession session, FocusTarget originalTarget, CancellationToken cancellation)
    {
        try
        {
            while (settings.AutoAddToDictionary && learningLease.Active && !cancellation.IsCancellationRequested)
            {
                await Task.Delay(100, cancellation);
                if (Native.GetForegroundWindow() != originalTarget.Window || Native.FocusAt(originalTarget.Window) != (originalTarget.Process, originalTarget.Focus)) break;
                var result = await session.ObserveAsync();
                if (cancellation.IsCancellationRequested || !learningLease.Active || !settings.AutoAddToDictionary) break;
                if (result.Candidate != null) { correction = result.Candidate; Notify("A possible word correction is ready. Review it before adding it to your dictionary."); break; }
                if (!result.Active) break;
            }
        }
        catch (OperationCanceledException) { }
        finally { if (ReferenceEquals(learningSession, session)) StopLearning(); else session.Dispose(); }
    }
    private void ReviewCorrection()
    {
        if (correction == null) { Notify("There is no dictionary suggestion to review."); return; }
        StopLearning(); var candidate = correction; correction = null;
        if (MessageBox.Show($"Add “{candidate.Replacement}” to your dictionary?\n\nObserved correction: {candidate.Original} → {candidate.Replacement}\nOnly this word will be saved.", "Review dictionary suggestion", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        try
        {
            var document = JsonNode.Parse(File.ReadAllText(AiPath))?.AsObject() ?? throw new InvalidDataException();
            var words = document["vocabulary"]?.AsArray().Select(v => v!.GetValue<string>()) ?? Enumerable.Empty<string>();
            document["vocabulary"] = JsonSerializer.SerializeToNode(FeatureConfig.Vocabulary(words.Append(candidate.Replacement)));
            FeatureConfig.WriteAtomic(AiPath, document); Notify("Word added. Manage your dictionary in Settings.");
        }
        catch { Notify("The dictionary could not be saved. Open Settings to review it."); }
    }
    private async Task QuitAsync()
    {
        quitting = true; hotkey?.Disable(); parakeetDownload?.Cancel(); await CancelAsync();
        SystemEvents.SessionSwitch -= OnSessionSwitch; SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        // Native inference receives cancellation. Do not dispose its factory while a call is active.
        if (!busy) transcriber.Dispose();
        panel?.Close(); tray?.Dispose(); idleIcon?.Dispose(); activeIcon?.Dispose(); startCue?.Dispose(); stopCue?.Dispose(); hotkey?.Dispose(); http.Dispose(); instance?.Dispose();
        Shutdown();
    }
}
