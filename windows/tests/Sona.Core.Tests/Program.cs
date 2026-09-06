using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Sona.Core;

// A dependency-free executable test harness. Throws/nonzero on failure.
if (args.Length > 0 && args[0] == "--child")
{
    var text = await Console.In.ReadToEndAsync();
    switch (args[1])
    {
        case "echo": Console.Write(text); break;
        case "empty": break;
        case "fail": return 7;
        case "hang": await Task.Delay(TimeSpan.FromMinutes(2)); break;
        case "flood": Console.Write(new string('x', 200000)); await Task.Delay(10000); break;
    }
    return 0;
}
int tests = 0;
void Check(bool value, string name) { tests++; if (!value) throw new Exception("FAIL: " + name); Console.WriteLine("PASS " + name); }
var tap = new ModifierTap();
tap.Down(100, false); Check(tap.Up(180), "short modifier tap");
tap.Down(100, false); tap.Down(110, false); Check(tap.Up(200), "autorepeat does not restart modifier");
tap.Down(100, false); tap.OtherKeyDown(); Check(!tap.Up(200), "modifier chord is ignored");
tap.Down(100, true); Check(!tap.Up(200), "other held modifier blocks tap");
tap.Down(100, false); Check(!tap.Up(900), "hold is not a tap");
Check(!tap.Up(1000), "unpaired release ignored");
Check(new Shortcut(0xA3, 0).IsValid && new Shortcut(0xA3, 0).IsModifierOnly, "right control selectable");
Check(!new Shortcut(0x7B, 0).IsValid, "F12 reserved");
Check(!new Shortcut(0x5B, 0).IsValid, "Windows key alone reserved");
Check(!new Shortcut(0xA3, 2).IsValid, "modifier cannot carry duplicate modifier mask");
Check(InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, false, true), "same field accepted");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 9, 2, 3, false, true), "changed app rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 8, false, true), "changed child field rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, true, true), "password rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, false, false), "changed UIA field rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 9, 3, false, true), "recycled window process rejected");
Check(InsertionPolicy.MayRestoreClipboard(10, 10) && !InsertionPolicy.MayRestoreClipboard(10, 11), "clipboard user change preserved");
string temp = Path.Combine(Path.GetTempPath(), "Sona-core-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temp);
try
{
    string config = Path.Combine(temp, "settings.json");
    Check(!SettingsStore.Load(config).SetupComplete, "blank machine requires setup");
    SettingsStore.Save(config, new AppSettings { SetupComplete = true, Shortcut = new Shortcut(0xA3, 0) });
    Check(SettingsStore.Load(config).Shortcut.VirtualKey == 0xA3, "chosen shortcut persists");
    await File.WriteAllTextAsync(config, "{bad");
    Check(!SettingsStore.Load(config).SetupComplete, "corrupt config returns to setup");
    byte[] payload = Encoding.UTF8.GetBytes("verified test model");
    var spec = new DownloadSpec(new Uri("https://example.invalid/test"), payload.Length, Convert.ToHexString(SHA256.HashData(payload)));
    string model = Path.Combine(temp, "model.bin");
    using var http = new HttpClient(new BytesHandler(payload));
    await new VerifiedDownloader(http).DownloadAsync(model, spec, null, CancellationToken.None);
    Check(await VerifiedDownloader.IsValidAsync(model, spec), "download size and SHA256 validated");
    await File.WriteAllTextAsync(model, "damaged");
    using var badHttp = new HttpClient(new BytesHandler(Encoding.UTF8.GetBytes("bad payload")));
    bool failed = false;
    try { await new VerifiedDownloader(badHttp).DownloadAsync(model, spec, null, CancellationToken.None); } catch (InvalidDataException) { failed = true; }
    Check(failed && await File.ReadAllTextAsync(model) == "damaged", "bad download does not replace prior file");
    using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
    bool cancelled = false;
    try { await new VerifiedDownloader(http).DownloadAsync(model, spec, null, cancellation.Token); } catch (OperationCanceledException) { cancelled = true; }
    Check(cancelled && !Directory.EnumerateFiles(temp, "*.partial").Any(), "cancel removes only partial download");
    byte[] large = new byte[200000]; Random.Shared.NextBytes(large);
    using var largeHttp = new HttpClient(new BytesHandler(large));
    using var midCancel = new CancellationTokenSource();
    var largeSpec = new DownloadSpec(spec.Url, large.Length, Convert.ToHexString(SHA256.HashData(large)));
    bool midCancelled = false;
    try { await new VerifiedDownloader(largeHttp).DownloadAsync(model, largeSpec, new InlineProgress(_ => midCancel.Cancel()), midCancel.Token); }
    catch (OperationCanceledException) { midCancelled = true; }
    Check(midCancelled && !Directory.EnumerateFiles(temp, "*.partial").Any() && await File.ReadAllTextAsync(model) == "damaged", "mid-download cancellation preserves prior model and removes partial");
    string executable = Environment.ProcessPath!;
    var prefix = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
        ? new[] { typeof(BytesHandler).Assembly.Location } : Array.Empty<string>();
    const string raw = "Exact transcript.\nUnicode ✓ and $ literal.";
    foreach (var mode in new[] { "echo", "empty", "fail", "hang", "flood" })
    {
        var watch = Stopwatch.StartNew();
        var result = await BoundedProcess.RunAsync(executable, prefix.Concat(new[] { "--child", mode }), raw, TimeSpan.FromMilliseconds(700));
        Check(result.Output == raw && result.Success == (mode == "echo"), "process " + mode + " preserves original");
        Check(watch.Elapsed < TimeSpan.FromSeconds(5), "process " + mode + " is bounded");
    }
}
finally { Directory.Delete(temp, recursive: true); }
Console.WriteLine($"{tests} checks passed.");
return 0;

sealed class BytesHandler(byte[] bytes) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
    }
}

sealed class InlineProgress(Action<double> action) : IProgress<double> { public void Report(double value) => action(value); }
