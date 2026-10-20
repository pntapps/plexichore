// Shared contract between PlexiChore.Engine (streaming core) and PlexiChore.App (WPF tray UI).
// Do not change signatures without updating both sides. Wire protocol: ../../../PROTOCOL.md
using System.Drawing;

namespace PlexiChore.Engine;

public sealed record ServerOptions
{
    public int TcpPort { get; init; } = 47800;
    public int DiscoveryPort { get; init; } = 47801;
    public string HostId { get; init; } = "";          // stable GUID persisted by App
    public string HostName { get; init; } = Environment.MachineName;
    public bool RequireApprovalForWifi { get; init; } = true;
    public IReadOnlyCollection<string> TrustedDeviceIds { get; init; } = Array.Empty<string>();
    public bool PreferHardwareEncoder { get; init; } = true;
    /// Additive: for USB (loopback / adb reverse) sessions, resolves the physical link from the tablet's HELLO model:
    /// "usb-cable" or "usb-wireless-adb" (null = unknown). Sent to the tablet as CONFIG `link`.
    public Func<string?, CancellationToken, Task<string?>>? LoopbackLinkResolver { get; init; }
}

public sealed record SessionInfo(
    Guid SessionId,
    string DeviceId,
    string DeviceName,
    string Model,
    bool IsUsb,
    string Mode,            // "extend" | "primary" | "mirror"
    int Width, int Height, int Fps,
    string Codec)
{
    /// Additive: Windows display scale applied to the virtual monitor (e.g. 200), 0 = not applicable (mirror) / unknown.
    public int ScalePercent { get; init; }
    /// Additive: true when the tablet asked for automatic scaling (scalePercent 0).
    public bool ScaleAuto { get; init; }
}

public sealed record SessionStats(Guid SessionId, double CaptureFps, double EncodeMs, int BitrateKbps, double RttMs);

public sealed class PairingRequest
{
    public required string DeviceId { get; init; }
    public required string DeviceName { get; init; }
    public required string Code { get; init; }      // 4 digits, also shown on tablet
    public required Action<bool> Respond { get; init; } // true = approve (App then adds to trusted list)
}

/// Implemented by Engine (PlexiServer class). App creates one instance at startup.
public interface IPlexiServer : IAsyncDisposable
{
    Task StartAsync(ServerOptions options, CancellationToken ct = default);
    Task StopAsync();
    bool IsRunning { get; }
    IReadOnlyList<SessionInfo> Sessions { get; }
    event EventHandler<SessionInfo>? SessionStarted;
    event EventHandler<SessionInfo>? SessionEnded;
    event EventHandler<SessionStats>? StatsUpdated;
    event EventHandler<PairingRequest>? PairingRequested;
    void Disconnect(Guid sessionId);
}

public sealed record VirtualMonitor(
    string DeviceName,      // GDI name e.g. \\.\DISPLAY3 — used to pick DXGI output to capture
    Rectangle DesktopBounds // virtual-desktop coordinates, used for input mapping
);

/// Implemented by App (wraps the signed open-source Virtual Display Driver). Engine calls it for "extend" and "primary" modes.
/// If null / not installed, Engine falls back to mirror mode and reports mode="mirror" in CONFIG.
public interface IVirtualDisplayProvider
{
    bool IsAvailable { get; }
    Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, CancellationToken ct = default);
    Task DetachAsync(VirtualMonitor monitor);

    /// "primary" mode: like AttachAsync, but the virtual monitor also becomes the Windows PRIMARY display (origin 0,0).
    /// <paramref name="position"/> keeps its meaning (where the tablet sits relative to the PC monitor). The returned
    /// DesktopBounds are the bounds AFTER the primary switch. DetachAsync must restore the original primary + layout.
    /// Default implementation (providers without primary support): returns null when makePrimary is true, so the
    /// Engine falls back to mirror mode.
    Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, bool makePrimary, CancellationToken ct = default) =>
        makePrimary ? Task.FromResult<VirtualMonitor?>(null) : AttachAsync(width, height, refreshHz, position, ct);

    /// Additive: sets the Windows display scale (DPI) of the attached VIRTUAL monitor only — never a physical monitor.
    /// <paramref name="scalePercent"/> is one of DisplayScale.Requestable (0 = auto from <paramref name="tabletDensityDpi"/>);
    /// it is clamped to what Windows allows for that monitor. Returns the scale in effect afterwards (percent), or 0 when
    /// unsupported / failed. Windows persists the value per monitor, so it is not undone on detach.
    /// Default implementation (providers without scaling support): returns 0.
    Task<int> SetScaleAsync(VirtualMonitor monitor, int scalePercent, int tabletDensityDpi, CancellationToken ct = default) =>
        Task.FromResult(0);
}

// Engine's PlexiServer constructor: public PlexiServer(IVirtualDisplayProvider? virtualDisplays, Microsoft.Extensions.Logging.ILogger? logger = null)
