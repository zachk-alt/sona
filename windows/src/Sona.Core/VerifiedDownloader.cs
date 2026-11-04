using System.Security.Cryptography;

namespace Sona.Core;

public sealed record DownloadSpec(Uri Url, long Size, string Sha256);

/// One local Whisper model file and its pinned, verified download.
public sealed record SpeechModel(string FileName, DownloadSpec Download, bool EnglishOnly);

public static class SpeechModels
{
    public static readonly SpeechModel Multilingual = new("ggml-base.bin", VerifiedDownloader.BaseModel, false);
    public static readonly SpeechModel English = new("ggml-base.en.bin", VerifiedDownloader.EnglishBaseModel, true);
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
