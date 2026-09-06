using System.Diagnostics;
using System.Text;

namespace Sona.Core;

public sealed record ProcessResult(bool Success, string Output, string? Failure);

public static class BoundedProcess
{
    // No shell, no transcript in argv, bounded output and time, and no inherited CLI stdin.
    public static async Task<ProcessResult> RunAsync(string executable, IEnumerable<string> arguments,
        string input, TimeSpan timeout, CancellationToken cancellation = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(timeout);
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(executable)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false), WorkingDirectory = Path.GetTempPath()
            }
        };
        foreach (var arg in arguments) process.StartInfo.ArgumentList.Add(arg);
        try
        {
            process.Start();
            var output = ReadLimited(process.StandardOutput, 131072, deadline.Token);
            var error = ReadLimited(process.StandardError, 32768, deadline.Token);
            // Pipe failures (including an overproducing child) end the process immediately.
            _ = Task.WhenAny(output, error).ContinueWith(t =>
            {
                if (t.Result.IsFaulted) { deadline.Cancel(); TryKill(process); }
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            await process.StandardInput.WriteAsync(input.AsMemory(), deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            var text = await output;
            await error; // Drain, but do not persist provider output or credentials in a log.
            if (process.ExitCode != 0) return new(false, input, "process_exit");
            if (string.IsNullOrWhiteSpace(text)) return new(false, input, "empty_output");
            return new(true, text, null);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            TryKill(process);
            return new(false, input, e is OperationCanceledException ? "timeout_or_cancelled" : "process_unavailable");
        }
    }

    private static async Task<string> ReadLimited(StreamReader reader, int limit, CancellationToken cancellation)
    {
        var result = new StringBuilder();
        char[] buffer = new char[4096];
        int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory(), cancellation)) > 0)
        {
            if (result.Length + read > limit) throw new InvalidDataException("Process output limit exceeded.");
            result.Append(buffer, 0, read);
        }
        return result.ToString();
    }

    private static void TryKill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
    }
}
