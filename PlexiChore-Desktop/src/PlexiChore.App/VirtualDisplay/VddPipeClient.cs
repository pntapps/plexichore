using System.IO.Pipes;
using System.Text;

namespace PlexiChore.App.VirtualDisplay;

/// Health-check client for the driver's control pipe \\.\pipe\MTTVirtualDisplayPipe (ACL: Everyone).
///
/// Protocol (verified against MttVDD 25.7.23): one command per connection, UTF-16LE, message mode, no terminator.
/// The driver writes its reply and immediately calls DisconnectNamedPipe WITHOUT FlushFileBuffers, which discards any
/// reply the client has not read yet — so the client must have an overlapped read posted BEFORE it writes the command.
/// PING → "PONG" (4 ANSI bytes); GETSETTINGS → UTF-16 "SETTINGS DEBUG=.. LOG=..".
///
/// Only read-only commands are allowed. RELOAD_DRIVER and every command that ends in ReloadDriver (SETDISPLAYCOUNT,
/// SETGPU, HDRPLUS, SDR10, CUSTOMEDID, PREVENTSPOOF, CEAOVERRIDE, HARDWARECURSOR) crash the driver host
/// (WUDFHost access violation: ReloadDriver passes the pipe HANDLE to WdfObjectGet_…). Settings changes need an
/// elevated device restart instead (see VddInstaller).
public static class VddPipeClient
{
    public const string PipeName = "MTTVirtualDisplayPipe";

    public static readonly IReadOnlySet<string> AllowedCommands =
        new HashSet<string>(StringComparer.Ordinal) { "PING", "GETSETTINGS" };

    public static bool IsAllowed(string command) => AllowedCommands.Contains(command);

    /// Wire format of a command (UTF-16LE, no BOM, no NUL terminator).
    internal static byte[] Encode(string command) => Encoding.Unicode.GetBytes(command);

    public static Task<string> SendAsync(string command, TimeSpan? replyWait = null, CancellationToken ct = default) =>
        SendAsync(PipeName, command, replyWait, ct);

    internal static async Task<string> SendAsync(string pipeName, string command, TimeSpan? replyWait, CancellationToken ct)
    {
        if (!IsAllowed(command))
            throw new InvalidOperationException($"Pipe command '{command}' is not allowed (it would crash the driver or change its state).");

        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(2000, ct);
        try { pipe.ReadMode = PipeTransmissionMode.Message; } catch { /* byte mode fallback is fine */ }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(replyWait ?? TimeSpan.FromMilliseconds(1500));
        var buf = new byte[4096];
        var received = new MemoryStream();

        // 1) post the read first: the reply is lost if the driver disconnects before a read is pending
        var firstRead = pipe.ReadAsync(buf, cts.Token).AsTask();
        // 2) send the command (no Flush: FlushFileBuffers can fail/block once the server disconnects)
        await pipe.WriteAsync(Encode(command), cts.Token);

        try
        {
            var n = await firstRead;
            if (n > 0) received.Write(buf, 0, n);
            // rest of a long message (message mode) — stop at end of message or when the server disconnects
            while (n > 0 && !SafeIsMessageComplete(pipe))
            {
                n = await pipe.ReadAsync(buf, cts.Token);
                if (n > 0) received.Write(buf, 0, n);
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
        catch (IOException) { }
        return Decode(received.ToArray());
    }

    private static bool SafeIsMessageComplete(PipeStream p)
    {
        try { return p.IsMessageComplete; }
        catch { return true; }
    }

    /// The driver answers PING in ANSI and everything else in UTF-16; pick whichever looks right.
    internal static string Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length >= 2 && data.Length % 2 == 0 && data[1] == 0)
            return Encoding.Unicode.GetString(data).TrimEnd('\0');
        return Encoding.UTF8.GetString(data).TrimEnd('\0');
    }

    /// Parses "SETTINGS DEBUG=true LOG=false" into a key/value map (keys upper-case). Null if not a settings reply.
    internal static IReadOnlyDictionary<string, string>? ParseSettings(string reply)
    {
        var parts = reply.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || !parts[0].Equals("SETTINGS", StringComparison.OrdinalIgnoreCase)) return null;
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in parts.Skip(1))
        {
            var i = p.IndexOf('=');
            if (i > 0) map[p[..i].ToUpperInvariant()] = p[(i + 1)..];
        }
        return map;
    }

    public static async Task<bool> PingAsync(CancellationToken ct = default)
    {
        try { return (await SendAsync("PING", TimeSpan.FromSeconds(1), ct)).Contains("PONG"); }
        catch { return false; }
    }

    public static async Task<IReadOnlyDictionary<string, string>?> GetSettingsAsync(CancellationToken ct = default)
    {
        try { return ParseSettings(await SendAsync("GETSETTINGS", TimeSpan.FromSeconds(1), ct)); }
        catch { return null; }
    }
}
