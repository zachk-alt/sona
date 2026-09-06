using System.Security.Cryptography;

namespace Sona.Core;

public sealed record DownloadSpec(Uri Url, long Size, string Sha256);

public sealed class VerifiedDownloader(HttpClient client)
{
    public static readonly DownloadSpec BaseModel = new(
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin"),
        147951465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe");

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
