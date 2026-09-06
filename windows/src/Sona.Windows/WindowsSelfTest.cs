using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using Sona.Core;

namespace Sona.Windows;

internal static class WindowsSelfTest
{
    // Explicit CI mode: owned windows, synthetic test keys and temporary clipboard sentinel.
    // Never records the microphone or calls a real AI provider.
    public static async Task RunAsync(string output, string? fixture)
    {
        var checks = new Dictionary<string, object>();
        string? failure = null;
        try
        {
            void Check(string name, bool value) { checks[name] = value; if (!value) throw new InvalidOperationException(name); }
            Check("windows11_or_server2022_plus", OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000));
            using (var icon = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Sona.ico"))!.Stream) Check("icon", icon.Length > 1000);
            Check("input_struct_size", Marshal.SizeOf<Native.Input>() == 40);
            var panel = new RecordingPanel();
            nint handle = new WindowInteropHelper(panel).EnsureHandle();
            long style = Native.GetWindowLongPtr(handle, Native.GwlExStyle).ToInt64();
            Check("nonactivating_style", (style & Native.WsExNoActivate) != 0);
            Check("toolwindow_style", (style & Native.WsExToolWindow) != 0);
            Check("hidden_from_taskbar", !panel.ShowInTaskbar && !panel.ShowActivated);
            panel.Close();
            string bridge = Path.Combine(AppContext.BaseDirectory, "bridge", "sona-cleanup.mjs");
            Check("bridge_packaged", File.Exists(bridge));
            if (fixture != null)
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(8) };
                string model = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(output))!, "models", "ggml-base.bin");
                await new VerifiedDownloader(http).DownloadAsync(model, VerifiedDownloader.BaseModel, null, CancellationToken.None);
                Check("model_sha256", await VerifiedDownloader.IsValidAsync(model, VerifiedDownloader.BaseModel));
                using var transcriber = new Transcriber();
                using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(3));
                string text = await transcriber.TranscribeAsync(await File.ReadAllBytesAsync(fixture), model, "en", cancellation.Token);
                string normalized = text.ToLowerInvariant();
                Check("whisper_jfk_country", normalized.Contains("country"));
                Check("whisper_jfk_ask", normalized.Contains("ask"));
                checks["whisper_fixture_result"] = text; // Public JFK fixture only, never user speech.
                string config = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(output))!, "selftest-ai.json");
                await File.WriteAllTextAsync(config, "{\"ai\":{\"provider\":\"none\"}}");
                string node = Path.Combine(AppContext.BaseDirectory, "runtime", "node", "node.exe");
                if (!File.Exists(node)) node = "node.exe";
                const string raw = "CI keeps this text exactly.\nSecond line.";
                var passthrough = await BoundedProcess.RunAsync(node, [bridge, "--config", config], raw, TimeSpan.FromSeconds(10));
                Check("node_bridge_passthrough", passthrough.Success && passthrough.Output == raw);
            }
            else checks["speech_and_bridge_runtime"] = "skipped: no --fixture path supplied";
            await TestOwnedWindowAsync(checks);
        }
        catch (Exception e) { failure = e.GetType().Name + ": " + e.Message; }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
        File.WriteAllText(output, JsonSerializer.Serialize(new
        {
            status = failure != null ? "failed" : checks.Values.OfType<string>().Any(v => v.StartsWith("skipped:")) ? "partial" : "passed",
            executedChecksPassed = failure == null,
            interactiveOutcome = checks.TryGetValue("interactive_owned_window", out var interactive) ? interactive : checks.ContainsKey("safe_paste_unicode_text") ? "passed" : "not reached",
            checks, failure,
            limitation = "No physical microphone, hardware shortcut, elevated target app, or authenticated AI account is exercised. Interactive checks explicitly report skipped when the runner cannot activate its own window."
        }, new JsonSerializerOptions { WriteIndented = true }));
        if (failure != null) throw new InvalidOperationException(failure);
    }
    private static async Task TestOwnedWindowAsync(Dictionary<string, object> checks)
    {
        var a = new TextBox { Text = "Before ", Height = 55, Margin = new Thickness(10) };
        var b = new TextBox { Text = "Other field", Height = 55, Margin = new Thickness(10) };
        var password = new PasswordBox { Height = 40, Margin = new Thickness(10) };
        var content = new StackPanel(); content.Children.Add(a); content.Children.Add(b); content.Children.Add(password);
        var window = new Window { Title = "Sona CI owned input target", Width = 520, Height = 270, Left = 100, Top = 100, Content = content };
        var panel = new RecordingPanel();
        System.Windows.IDataObject? oldClipboard = null;
        bool touchedClipboard = false;
        try
        {
            window.Show(); window.Activate(); a.Focus(); Keyboard.Focus(a); await Task.Delay(300);
            var handle = new WindowInteropHelper(window).Handle;
            if (Native.GetForegroundWindow() != handle)
            {
                checks["interactive_owned_window"] = "skipped: runner has no activatable interactive desktop";
                return;
            }
            void Check(string name, bool value) { checks[name] = value; if (!value) throw new InvalidOperationException(name); }
            checks["owned_wpf_keyboard_focus"] = a.IsKeyboardFocused;
            // A new desktop can initialize its accessibility provider lazily. Retry only
            // this owned field, with a short deadline and sanitized status evidence.
            FocusTarget? first = null;
            var captureStatuses = new List<string>();
            var captureWatch = System.Diagnostics.Stopwatch.StartNew();
            do
            {
                var capture = await TextInsertion.CaptureWithStatusAsync(allowOwnProcess: true);
                captureStatuses.Add(capture.Status); first = capture.Target;
                if (first != null || Native.GetForegroundWindow() != handle) break;
                await Task.Delay(150);
            } while (captureWatch.Elapsed < TimeSpan.FromSeconds(4));
            checks["owned_capture_statuses"] = captureStatuses;
            checks["owned_capture_elapsed_ms"] = captureWatch.ElapsedMilliseconds;
            Check("capture_owned_editable_field", first != null);
            panel.Recording(handle, "Ctrl + Alt + F10"); await Task.Delay(150);
            Check("overlay_preserves_foreground_recording", Native.GetForegroundWindow() == handle);
            panel.Processing(); await Task.Delay(150);
            Check("overlay_preserves_foreground_processing", Native.GetForegroundWindow() == handle);
            panel.Dismiss();
            using (var hotkey = new HotkeyService())
            {
                var triggered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                hotkey.Triggered += () => triggered.TrySetResult();
                hotkey.Configure(new Shortcut(0x79, 3)); // Ctrl + Alt + F10, CI only.
                Native.Input Key(ushort key, bool up) => new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } } };
                Native.Input[] keys = [Key(0x11, false), Key(0x12, false), Key(0x79, false), Key(0x79, true), Key(0x12, true), Key(0x11, true)];
                Check("shortcut_sendinput", Native.SendInput(6, keys, Marshal.SizeOf<Native.Input>()) == 6);
                await triggered.Task.WaitAsync(TimeSpan.FromSeconds(2)); checks["registered_chord_activation"] = true;
            }
            oldClipboard = Clipboard.GetDataObject();
            Clipboard.SetText("Sona CI clipboard sentinel"); touchedClipboard = true;
            b.Focus(); Keyboard.Focus(b); await Task.Delay(100);
            Check("changed_field_rejected", !await TextInsertion.PasteAsync(first!, "SHOULD NOT INSERT"));
            Check("changed_field_untouched", b.Text == "Other field" && a.Text == "Before ");
            a.Focus(); Keyboard.Focus(a); a.CaretIndex = a.Text.Length; await Task.Delay(100);
            var current = await TextInsertion.CaptureAsync(allowOwnProcess: true);
            Check("safe_paste_accepted", current != null && await TextInsertion.PasteAsync(current, "Sona ✓"));
            Check("safe_paste_unicode_text", a.Text == "Before Sona ✓");
            Check("clipboard_restored", Clipboard.GetText() == "Sona CI clipboard sentinel");
            password.Focus(); Keyboard.Focus(password); await Task.Delay(100);
            Check("password_rejected", await TextInsertion.CaptureAsync(allowOwnProcess: true) == null);
        }
        finally
        {
            if (touchedClipboard) { try { if (oldClipboard != null) Clipboard.SetDataObject(oldClipboard, true); else Clipboard.Clear(); } catch { } }
            panel.Dismiss(); panel.Close(); window.Close();
        }
    }
}
