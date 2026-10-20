using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PlexiChore.Engine.Capture;

/// Keeps one idle D3D11 device per adapter alive between pipelines. Creating a device costs ~30 ms warm but
/// 0.9-2.2 s when the PC is short of memory (driver pages faulted back in), and a downscale / reconnect used to pay
/// it every time. A device is lent to one pipeline at a time (its immediate context carries pipeline state);
/// a second concurrent pipeline gets a fresh device.
internal static class DevicePool
{
    private static readonly object Lock = new();
    private static readonly Dictionary<string, (ID3D11Device dev, ID3D11DeviceContext ctx)> Idle = new();

    // LUID = 8 bytes (LowPart, HighPart): use the raw value as the key, whatever the wrapper type is called
    private static unsafe string Key<T>(T luid) where T : unmanaged => sizeof(T) == 8 ? (*(long*)&luid).ToString("X16") : luid.ToString() ?? "";

    private static readonly FeatureLevel[] Levels = { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0 };

    /// A device on `adapter` (pooled when one is idle and healthy). `pooled` tells whether it came from the pool.
    public static (ID3D11Device dev, ID3D11DeviceContext ctx) Rent(IDXGIAdapter1 adapter, out bool pooled)
    {
        string key = Key(adapter.Description1.Luid);
        lock (Lock)
        {
            if (Idle.Remove(key, out var d))
            {
                if (d.dev.DeviceRemovedReason.Success) { pooled = true; return d; }
                d.ctx.Dispose(); d.dev.Dispose();
            }
        }
        pooled = false;
        D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            Levels, out ID3D11Device device, out ID3D11DeviceContext ctx).CheckError();
        using (var mt = device.QueryInterface<ID3D11Multithread>()) mt.SetMultithreadProtected(true);
        return (device, ctx);
    }

    /// Gives a device back (state cleared). Keeps it when the slot is free and the device is healthy, else disposes it.
    public static void Return(ID3D11Device dev, ID3D11DeviceContext ctx)
    {
        try
        {
            ctx.ClearState();
            ctx.Flush();
            using var dxgi = dev.QueryInterface<IDXGIDevice>();
            using var adapter = dxgi.GetAdapter();
            string key = Key(adapter.Description.Luid);
            lock (Lock)
            {
                if (dev.DeviceRemovedReason.Success && !Idle.ContainsKey(key)) { Idle[key] = (dev, ctx); return; }
            }
        }
        catch { /* fall through: dispose */ }
        ctx.Dispose();
        dev.Dispose();
    }

    /// Engine warm-up: park a device on the default adapter (keeps the user-mode driver loaded).
    public static void Park(ID3D11Device dev, ID3D11DeviceContext ctx) => Return(dev, ctx);
}
