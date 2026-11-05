using System.Security.Cryptography;

namespace Sona.Core;

public sealed record DownloadSpec(Uri Url, long Size, string Sha256);

/// One local Whisper model file and its pinned, verified download.
public sealed record SpeechModel(string FileName, DownloadSpec Download, bool EnglishOnly);

/// One file of a multi-file model. Name is a plain file name inside the model's folder.
public sealed record ModelFile(string Name, DownloadSpec Download);

/// A model made of several files in one folder. It is usable only when every file matches its pinned size and SHA-256.
public sealed record ModelBundle(string FolderName, IReadOnlyList<ModelFile> Files)
{
    public long TotalSize => Files.Sum(file => file.Download.Size);
}

public static class SpeechModels
{
    public static readonly SpeechModel Multilingual = new("ggml-base.bin", VerifiedDownloader.BaseModel, false);
    public static readonly SpeechModel English = new("ggml-base.en.bin", VerifiedDownloader.EnglishBaseModel, true);
    /// NVIDIA Parakeet TDT 0.6B v2, int8, as exported for sherpa-onnx (a converted copy of NVIDIA's model, CC BY 4.0).
    /// English dictation runs on it once it is verified; Whisper base.en stays the backup.
    public static readonly ModelBundle Parakeet = new("parakeet-tdt-0.6b-v2-int8", VerifiedDownloader.ParakeetFiles);
    public static bool IsEnglish(string? language) => string.Equals(language?.Trim(), "en", StringComparison.OrdinalIgnoreCase);
    /// English gets the English-only base.en model; "auto" and every other language keep multilingual base.
    public static SpeechModel For(string? language) => IsEnglish(language) ? English : Multilingual;
    /// The language Whisper is told. An English-only model only ever hears "en".
    public static string WhisperLanguage(SpeechModel model, string language) => model.EnglishOnly ? "en" : language;
}

public sealed class VerifiedDownloader(HttpClient client)
{
    public static readonly DownloadSpec BaseModel = new(
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin"),
        147951465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe");
    // English-only base model at the same pinned revision. Size and SHA-256 are the file's Git LFS metadata
    // (lfs.oid and lfs.size), read 2026-11-04 from
    // https://huggingface.co/api/models/ggerganov/whisper.cpp/paths-info/5359861c739e955e79d9a303bcbc70fb988958b1
    // (POST paths=ggml-base.en.bin) and shown on
    // https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin
    public static readonly DownloadSpec EnglishBaseModel = new(
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin"),
        147964211, "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002");

    // Parakeet TDT 0.6B v2 int8 for sherpa-onnx, pinned to commit 1ab9323565ddb038682214b292f588070a538ce2 of
    // https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 (license cc-by-4.0 on the model card).
    // The three ONNX files' sizes and SHA-256 are their Git LFS metadata (lfs.size and lfs.oid), read 2026-11-04 from
    // https://huggingface.co/api/models/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/paths-info/1ab9323565ddb038682214b292f588070a538ce2
    // and identical at the earlier commit b9bd32696df49cbb1e7e499238a22804c82f9ef7. tokens.txt is a plain Git file:
    // its SHA-256 was computed from the pinned resolve URL on 2026-11-04, and its Git blob id matched the API's oid
    // f0742785f6073e80b911964c455b05f3609bf23b.
    private const string ParakeetRoot = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/1ab9323565ddb038682214b292f588070a538ce2/";
    public static readonly IReadOnlyList<ModelFile> ParakeetFiles =
    [
        new("encoder.int8.onnx", new(new Uri(ParakeetRoot + "encoder.int8.onnx"), 652184296, "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab")),
        new("decoder.int8.onnx", new(new Uri(ParakeetRoot + "decoder.int8.onnx"), 7257753, "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e")),
        new("joiner.int8.onnx", new(new Uri(ParakeetRoot + "joiner.int8.onnx"), 1739080, "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2")),
        new("tokens.txt", new(new Uri(ParakeetRoot + "tokens.txt"), 9384, "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d")),
    ];

    /// True only when every file of the bundle is present with its pinned size and SHA-256.
    public static async Task<bool> IsValidAsync(string folder, ModelBundle bundle, CancellationToken cancellation = default)
    {
        foreach (var file in bundle.Files)
            if (!await IsValidAsync(Path.Combine(folder, file.Name), file.Download, cancellation)) return false;
        return true;
    }

    /// Fetches each missing or wrong file of the bundle to a temporary name, verifies it, then moves it into place.
    /// Files that already verify are kept. Progress covers the whole bundle by bytes.
    public async Task DownloadAsync(string folder, ModelBundle bundle, IProgress<double>? progress, CancellationToken cancellation)
    {
        foreach (var file in bundle.Files)
            if (Path.GetFileName(file.Name) != file.Name || file.Name.Length == 0) throw new InvalidDataException("Model file names must be plain file names.");
        DeleteStalePartials(folder, bundle);
        long total = Math.Max(1, bundle.TotalSize), done = 0;
        foreach (var file in bundle.Files)
        {
            long offset = done, size = file.Download.Size;
            var part = progress == null ? null : new InlineProgress(p => progress.Report((offset + p * size) / total));
            await DownloadAsync(Path.Combine(folder, file.Name), file.Download, part, cancellation);
            done += size;
        }
        progress?.Report(1);
    }

    /// A download cut off by shutdown, logoff or a hard exit never reaches its finally block, so its
    /// "name.guid.partial" file stays behind and the next attempt picks a new name. Each run first clears the
    /// leftovers of this bundle's own files. A file still held open by a run that was just cancelled throws
    /// IOException here; that run deletes it in its own finally, so it is skipped.
    private static void DeleteStalePartials(string folder, ModelBundle bundle)
    {
        if (!Directory.Exists(folder)) return;
        foreach (var file in bundle.Files)
            foreach (var stale in Directory.EnumerateFiles(folder, file.Name + ".*.partial"))
            {
                try { File.Delete(stale); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
    }

    private sealed class InlineProgress(Action<double> report) : IProgress<double> { public void Report(double value) => report(value); }

    public static async Task<bool> IsValidAsync(string path, DownloadSpec spec, CancellationToken cancellation = default)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != spec.Size) return false;
        await using var input = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(input, cancellation);
        return Convert.ToHexString(hash).Equals(spec.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    public async Task DownloadAsync(string path, DownloadSpec spec, IProgress<double>? progress, CancellationToken cancellation)
    {
        if (await IsValidAsync(path, spec, cancellation)) { progress?.Report(1); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string partial = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using var response = await client.GetAsync(spec.Url, HttpCompletionOption.ResponseHeadersRead, cancellation);
            response.EnsureSuccessStatusCode();
            await using (var input = await response.Content.ReadAsStreamAsync(cancellation))
            await using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
            {
                byte[] buffer = new byte[81920];
                long total = 0;
                int count;
                while ((count = await input.ReadAsync(buffer, cancellation)) > 0)
                {
                    total += count;
                    if (total > spec.Size) throw new InvalidDataException("Download exceeds its expected size.");
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellation);
                    progress?.Report((double)total / spec.Size);
                }
            }
            if (!await IsValidAsync(partial, spec, cancellation)) throw new InvalidDataException("Download integrity check failed. Please retry.");
            File.Move(partial, path, true);
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
    }
}
