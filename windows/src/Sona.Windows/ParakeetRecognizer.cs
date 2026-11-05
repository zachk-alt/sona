using System.Reflection;
using System.Runtime.InteropServices;
using SherpaOnnx;

namespace Sona.Windows;

/// NVIDIA Parakeet TDT 0.6B v2 (int8 sherpa-onnx export) on sherpa-onnx's offline recognizer.
/// Created once for a verified model folder and kept loaded between dictations. One decode at a time: the caller serializes.
/// It uses no Windows-only API except the guarded native preload and short-path lookup, so a Mac console can run the same code.
internal sealed class ParakeetRecognizer : IDisposable
{
    public const int SampleRate = 16000;
    private OfflineRecognizer? recognizer;

    public string Folder { get; }

    public ParakeetRecognizer(string folder, int threads)
    {
        Folder = folder;
        if (OperatingSystem.IsWindows()) PreloadOnnxRuntime();
        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = SampleRate;
        config.ModelConfig.Transducer.Encoder = NativePath(Path.Combine(folder, "encoder.int8.onnx"));
        config.ModelConfig.Transducer.Decoder = NativePath(Path.Combine(folder, "decoder.int8.onnx"));
        config.ModelConfig.Transducer.Joiner = NativePath(Path.Combine(folder, "joiner.int8.onnx"));
        config.ModelConfig.Tokens = NativePath(Path.Combine(folder, "tokens.txt"));
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.NumThreads = Math.Max(1, threads);
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.Debug = 0;
        config.DecodingMethod = "greedy_search";
        var created = new OfflineRecognizer(config);
        // sherpa-onnx returns a null native handle for a config it rejects, and the wrapper does not check it.
        // Using a null recognizer would crash in native code, so it is refused here and the caller falls back.
        if (NativeHandle(created) == IntPtr.Zero) { created.Dispose(); throw new InvalidDataException("Parakeet did not load."); }
        recognizer = created;
    }

    /// 16 kHz mono float samples in, trimmed text out.
    public string Transcribe(float[] samples)
    {
        var current = recognizer ?? throw new ObjectDisposedException(nameof(ParakeetRecognizer));
        using var stream = current.CreateStream();
        stream.AcceptWaveform(SampleRate, samples);
        current.Decode(stream);
        return stream.Result.Text.Trim();
    }

    public void Dispose() { recognizer?.Dispose(); recognizer = null; }

    private static IntPtr NativeHandle(OfflineRecognizer created) =>
        typeof(OfflineRecognizer).GetField("_handle", BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(created) is HandleRef handle ? handle.Handle : IntPtr.Zero;

    // Windows 11 can carry an older onnxruntime.dll of its own. Loading Sona's copy by full path first makes
    // sherpa-onnx bind to the version it was built against.
    private static void PreloadOnnxRuntime()
    {
        string bundled = Path.Combine(AppContext.BaseDirectory, "onnxruntime.dll");
        if (File.Exists(bundled)) NativeLibrary.TryLoad(bundled, out _);
    }

    // sherpa-onnx takes ANSI paths on Windows. A profile folder with characters outside the ANSI code page gets
    // its 8.3 short form when the volume has one; otherwise the load fails and the dictation falls back to Whisper.
    private static string NativePath(string path)
    {
        if (!OperatingSystem.IsWindows() || path.All(c => c < 128)) return path;
        var buffer = new char[1024];
        uint length = GetShortPathNameW(path, buffer, (uint)buffer.Length);
        return length > 0 && length < buffer.Length ? new string(buffer, 0, (int)length) : path;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathNameW(string longPath, char[] shortPath, uint bufferLength);
}
