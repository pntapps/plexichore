using Vortice.Direct3D11;

namespace PlexiChore.Engine.Streaming;

/// Diagnostics (PLEXI_GPUTIME=1): GPU time of the capture-side work (cursor + scale/convert) via timestamp queries,
/// sampled every few frames and read back without stalling.
internal sealed unsafe class GpuTimer : IDisposable
{
    public static readonly bool Enabled = Environment.GetEnvironmentVariable("PLEXI_GPUTIME") != null;
    private readonly ID3D11DeviceContext _ctx;
    private readonly ID3D11Query _disjoint, _a, _b;
    private bool _pending;
    private int _n;
    public double LastMs { get; private set; }
    public double SumMs; public int Samples;

    public GpuTimer(ID3D11Device dev, ID3D11DeviceContext ctx)
    {
        _ctx = ctx;
        _disjoint = dev.CreateQuery(new QueryDescription(QueryType.TimestampDisjoint));
        _a = dev.CreateQuery(new QueryDescription(QueryType.Timestamp));
        _b = dev.CreateQuery(new QueryDescription(QueryType.Timestamp));
    }

    public bool Begin()
    {
        Poll();
        if (_pending || (++_n % 4) != 0) return false;
        _ctx.Begin(_disjoint);
        _ctx.End(_a);
        return true;
    }

    public void End()
    {
        _ctx.End(_b);
        _ctx.End(_disjoint);
        _pending = true;
    }

    private void Poll()
    {
        if (!_pending) return;
        QueryDataTimestampDisjoint dj;
        ulong a, b;
        if (_ctx.GetData(_disjoint, (IntPtr)(&dj), (uint)sizeof(QueryDataTimestampDisjoint), AsyncGetDataFlags.DoNotFlush).Code != 0) return;
        if (_ctx.GetData(_a, (IntPtr)(&a), 8, AsyncGetDataFlags.DoNotFlush).Code != 0) return;
        if (_ctx.GetData(_b, (IntPtr)(&b), 8, AsyncGetDataFlags.DoNotFlush).Code != 0) return;
        _pending = false;
        if (dj.Disjoint || dj.Frequency == 0) return;
        LastMs = (b - a) * 1000.0 / dj.Frequency;
        SumMs += LastMs; Samples++;
    }

    public void Dispose() { _disjoint.Dispose(); _a.Dispose(); _b.Dispose(); }
}
