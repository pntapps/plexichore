using PlexiChore.Engine.Protocol;

namespace PlexiChore.Engine.Streaming;

/// Per-session outbound queue. Control messages are never dropped and go first; video frames are bounded:
/// under backpressure queued frames are discarded and (for H.264) everything is dropped until the next IDR,
/// which is requested from the encoder. Capture never blocks on the socket.
internal sealed class SessionSender
{
    private const int MaxQueuedVideo = 3;

    private readonly Stream _stream;
    private readonly object _lock = new();
    private readonly Queue<byte[]> _control = new();
    private readonly Queue<(byte[] Msg, byte Flags)> _video = new();
    private readonly SemaphoreSlim _signal = new(0, int.MaxValue);
    private bool _waitForKeyframe;
    private bool _videoEnabled;
    private long _bytesSent;
    private long _framesDropped;
    private long _lastKeyRequest = long.MinValue / 2;

    public Action? KeyframeNeeded { get; set; }
    public bool IsMjpeg { get; set; }
    public long FramesDropped => Interlocked.Read(ref _framesDropped);

    public SessionSender(Stream stream) { _stream = stream; }

    public long TakeBytesSent() => Interlocked.Exchange(ref _bytesSent, 0);

    public void EnqueueControl(byte[] msg)
    {
        lock (_lock) _control.Enqueue(msg);
        _signal.Release();
    }

    /// Enables/disables video and clears any queued frames (used around pipeline reconfiguration).
    public void ResetVideo(bool enabled)
    {
        lock (_lock)
        {
            _video.Clear();
            _videoEnabled = enabled;
            _waitForKeyframe = !IsMjpeg; // a fresh stream must start with codec-config + IDR
        }
    }

    public void EnqueueVideo(byte[] msg, byte flags)
    {
        bool requestKey = false;
        lock (_lock)
        {
            if (!_videoEnabled) return;
            bool isKey = (flags & VideoFlags.Keyframe) != 0;
            bool isCfg = (flags & VideoFlags.CodecConfig) != 0;

            if (IsMjpeg)
            {
                while (_video.Count >= MaxQueuedVideo) { _video.Dequeue(); _framesDropped++; }
                _video.Enqueue((msg, flags));
            }
            else
            {
                if (_waitForKeyframe && !isKey && !isCfg) { _framesDropped++; requestKey = true; goto done; }
                if (_video.Count >= MaxQueuedVideo && !isKey && !isCfg)
                {
                    _framesDropped += _video.Count + 1;
                    _video.Clear();
                    _waitForKeyframe = true;
                    requestKey = true;
                    goto done;
                }
                if (isKey)
                {
                    // A new IDR makes everything queued before it (except its own codec-config) obsolete.
                    if (_video.Count > 0)
                    {
                        var keep = _video.Where(v => (v.Flags & VideoFlags.CodecConfig) != 0).TakeLast(1).ToList();
                        _framesDropped += _video.Count - keep.Count;
                        _video.Clear();
                        foreach (var k in keep) _video.Enqueue(k);
                    }
                    _waitForKeyframe = false;
                }
                _video.Enqueue((msg, flags));
            }
        }
        _signal.Release();
    done:
        if (requestKey)
        {
            long now = Environment.TickCount64;
            if (now - Interlocked.Read(ref _lastKeyRequest) >= 250)
            {
                Interlocked.Exchange(ref _lastKeyRequest, now);
                KeyframeNeeded?.Invoke();
            }
        }
    }

    public async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await _signal.WaitAsync(ct).ConfigureAwait(false);
            while (true)
            {
                byte[]? msg = null;
                lock (_lock)
                {
                    if (_control.Count > 0) msg = _control.Dequeue();
                    else if (_video.Count > 0) msg = _video.Dequeue().Msg;
                }
                if (msg == null) break;
                await _stream.WriteAsync(msg, ct).ConfigureAwait(false);
                Interlocked.Add(ref _bytesSent, msg.Length);
            }
        }
    }

    /// Best-effort synchronous flush of pending control messages (used for BYE).
    public async Task FlushControlAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            lock (_lock) if (_control.Count == 0) return;
            await Task.Delay(20).ConfigureAwait(false);
        }
    }
}
