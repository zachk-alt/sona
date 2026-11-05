using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sona.Windows;

/// About Sona, the Windows side of the Mac's standard About panel (StatusBarController.showAbout): the app
/// icon, the name, the version and the speech credits. A normal window from the tray menu; it may take focus,
/// like Settings.
internal sealed class AboutWindow : Window
{
    private static AboutWindow? shown;
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.SteelBlue, Margin = new Thickness(0, 6, 0, 0) };

    /// The release version: AssemblyInformationalVersion without the "+commit" build metadata.
    internal static string Version { get; } = ReadVersion();

    internal static string VersionLine => "Version " + Version;

    /// Written like the Mac's ThirdPartyCredits.text. The full notices are THIRD-PARTY.md and the licenses folder.
    /// The Parakeet model is CC BY 4.0, which asks for credit, a link to the license and a note of any changes.
    internal const string Credits =
        "English speech recognition on this PC uses Parakeet TDT 0.6B v2 by NVIDIA " +
        "(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2). Sona downloads a converted copy, not NVIDIA's " +
        "original files: the int8 ONNX export for sherpa-onnx published by csukuangfj " +
        "(https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8), converted from NeMo to ONNX " +
        "with int8 weights. The model is licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), " +
        "not under Sona's license. NVIDIA does not endorse Sona.\n\n" +
        "The model runs through sherpa-onnx by k2-fsa (https://github.com/k2-fsa/sherpa-onnx), Apache License 2.0, " +
        "and ONNX Runtime by Microsoft (https://github.com/microsoft/onnxruntime), MIT License.\n\n" +
        "Whisper by OpenAI is the backup engine and serves the other languages. Its models run through whisper.cpp " +
        "(https://github.com/ggml-org/whisper.cpp) and Whisper.net (https://github.com/sandrohanea/whisper.net), " +
        "all under the MIT License. Audio capture uses NAudio (https://github.com/naudio/NAudio), MIT License. " +
        "Sona runs on .NET and WPF by Microsoft, MIT License.\n\n" +
        "Sona's own license does not cover third-party code or models; their notices and rights are unchanged.";

    /// Opens About, or brings the open one forward.
    public static void Open()
    {
        if (shown != null) { shown.Activate(); return; }
        shown = new AboutWindow();
        shown.Closed += (_, _) => shown = null;
        shown.Show();
    }

    internal AboutWindow()
    {
        Title = "About Sona";
        Width = 460; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(247, 248, 250)); // The Settings page color.
        var icon = new BitmapImage(new Uri("pack://application:,,,/Assets/SonaAppIcon.png"));
        Icon = icon;
        var stack = new StackPanel { Margin = new Thickness(30, 24, 30, 24) };
        Content = stack;
        stack.Children.Add(new Image { Source = icon, Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = "Sona", FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 2) });
        stack.Children.Add(new TextBlock { Text = VersionLine, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 14) });
        // Read-only text rather than a label, so the links and notices can be selected and copied, as on the Mac.
        var credits = new TextBox
        {
            Text = Credits, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 11, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, IsTabStop = false
        };
        System.Windows.Automation.AutomationProperties.SetName(credits, "Credits");
        stack.Children.Add(credits);
        var notices = new Button { Content = "Open third-party notices", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 14, 0, 0) };
        notices.Click += (_, _) => OpenNotices();
        stack.Children.Add(notices);
        stack.Children.Add(status);
    }

    /// THIRD-PARTY.md beside Sona.exe (build.ps1 copies it into the release), in Notepad like the AI configuration.
    internal static string NoticesPath => Path.Combine(AppContext.BaseDirectory, "THIRD-PARTY.md");

    private void OpenNotices()
    {
        if (!File.Exists(NoticesPath)) { status.Text = "THIRD-PARTY.md is missing from the Sona folder. Reinstall Sona to restore it."; return; }
        try { Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = false, ArgumentList = { NoticesPath } }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { status.Text = "Notepad could not open. The notices are in THIRD-PARTY.md in the Sona folder."; }
    }

    private static string ReadVersion()
    {
        var assembly = typeof(AboutWindow).Assembly;
        string? informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrEmpty(informational)) return informational.Split('+')[0];
        var version = assembly.GetName().Version;
        return version == null ? "unknown" : $"{version.Major}.{version.Minor}.{version.Build}";
    }
}
