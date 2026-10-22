using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Extensions.Logging;
using PlexiChore.App.Services;
using PlexiChore.App.Services.Adb;
using PlexiChore.App.VirtualDisplay;
using PlexiChore.Engine;

namespace PlexiChore.App.ViewModels;

public sealed partial class MainViewModel : ObservableObject
{
    private readonly Dispatcher _ui;
    private readonly ServerHost _server;
    private readonly AdbManager _adb;
    private readonly VirtualDisplayDriverProvider _vdd;
    private readonly VddInstaller _vddInstaller;
    private readonly FirewallService _firewall;
    private readonly SettingsService _settings;
    private readonly ILogger<MainViewModel> _log;
    private readonly DispatcherTimer _tick;

    public MainViewModel(ServerHost server, AdbManager adb, VirtualDisplayDriverProvider vdd, VddInstaller vddInstaller,
        FirewallService firewall, SettingsService settings, ILogger<MainViewModel> log)
    {
        _ui = Application.Current.Dispatcher;
        _server = server; _adb = adb; _vdd = vdd; _vddInstaller = vddInstaller; _firewall = firewall; _settings = settings; _log = log;

        var s = settings.Current;
        _startWithWindows = s.StartWithWindows;
        _requireApprovalForWifi = s.RequireApprovalForWifi;
        _showConnectNotifications = s.ShowConnectNotifications;
        _encoderIndex = s.PreferHardwareEncoder ? 0 : 1;
        ReloadTrusted();

        _server.StateChanged += (_, _) => Ui(RefreshHero);
        _server.SessionStarted += (_, e) => Ui(() => OnSessionStarted(e));
        _server.SessionEnded += (_, e) => Ui(() => OnSessionEnded(e));
        _server.SessionUpdated += (_, e) => Ui(() => Sessions.FirstOrDefault(x => x.SessionId == e.SessionId)?.Update(e));
        _server.StatsUpdated += (_, e) => Ui(() => Sessions.FirstOrDefault(x => x.SessionId == e.SessionId)?.Apply(e));
        _adb.Changed += (_, _) => Ui(RefreshAdb);
        _vdd.StatusChanged += (_, _) => Ui(RefreshVdd);
        Sessions.CollectionChanged += (_, _) => { OnPropertyChanged(nameof(HasSessions)); RefreshHero(); };

        _tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        _tick.Tick += (_, _) => { foreach (var x in Sessions) x.Tick(); RefreshNetwork(); };
        _tick.Start();

        RefreshNetwork();
        RefreshHero();
        RefreshAdb();
        RefreshVdd();
        _ = RefreshFirewallAsync();
    }

    private void Ui(Action a)
    {
        if (_ui.CheckAccess()) a(); else _ui.BeginInvoke(a);
    }

    public event EventHandler<SessionInfo>? TabletConnected;

    // ================= Hero / server =================
    public ObservableCollection<SessionViewModel> Sessions { get; } = new();
    public bool HasSessions => Sessions.Count > 0;

    [ObservableProperty] private string _heroTitle = "Starting…";
    [ObservableProperty] private string _heroSubtitle = "";
    [ObservableProperty] private string _heroTone = "info";
    [ObservableProperty] private bool _isPaused;
    [ObservableProperty] private string _serverPill = "Starting";
    [ObservableProperty] private string _hostName = Environment.MachineName;
    [ObservableProperty] private string _ipAddresses = "";
    [ObservableProperty] private string _usbChip = "";
    [ObservableProperty] private string _usbChipTone = "neutral";
    [ObservableProperty] private string _extendChip = "";
    [ObservableProperty] private string _extendChipTone = "neutral";
    [ObservableProperty] private string _wifiChip = "Wi‑Fi discovery";
    [ObservableProperty] private string _wifiChipTone = "neutral";

    public string PauseButtonText => IsPaused ? "Resume" : "Pause";
    public string PauseButtonIcon => IsPaused ? "Play24" : "Pause24";
    partial void OnIsPausedChanged(bool value) { OnPropertyChanged(nameof(PauseButtonText)); OnPropertyChanged(nameof(PauseButtonIcon)); }

    private void RefreshHero()
    {
        IsPaused = _server.State == ServerState.Paused;
        var n = Sessions.Count;
        switch (_server.State)
        {
            case ServerState.Paused:
                HeroTitle = "Paused";
                HeroSubtitle = "Tablets can't connect while the server is paused. Resume to make this PC visible again.";
                HeroTone = "warn"; ServerPill = "Paused";
                break;
            case ServerState.Error:
                HeroTitle = "Server couldn't start";
                HeroSubtitle = _server.LastError ?? "Unknown error. See logs for details.";
                HeroTone = "bad"; ServerPill = "Error";
                break;
            case ServerState.Starting:
                HeroTitle = "Starting…";
                HeroSubtitle = "Preparing the display server.";
                HeroTone = "info"; ServerPill = "Starting";
                break;
            case ServerState.Stopped:
                HeroTitle = "Stopped";
                HeroSubtitle = "";
                HeroTone = "neutral"; ServerPill = "Stopped";
                break;
            default:
                if (n == 0)
                {
                    HeroTitle = "Ready — waiting for tablet";
                    HeroSubtitle = "Open PlexiChore on your tablet. Connect with a USB cable, or pick this PC on the same Wi‑Fi network.";
                    HeroTone = "good";
                }
                else
                {
                    HeroTitle = n == 1 ? $"{Sessions[0].DeviceName} connected" : $"{n} tablets connected";
                    HeroSubtitle = n == 1
                        ? $"{Sessions[0].ModeText} over {Sessions[0].TransportText} · {Sessions[0].Resolution}"
                        : string.Join(" · ", Sessions.Select(s => s.DeviceName));
                    HeroTone = "accent";
                }
                ServerPill = "Online";
                break;
        }
        WifiChip = _server.State == ServerState.Running ? "Wi‑Fi discovery on" : "Wi‑Fi discovery off";
        WifiChipTone = _server.State == ServerState.Running ? "good" : "neutral";
    }

    private void RefreshNetwork()
    {
        try
        {
            var ips = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up &&
                            n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !a.Address.ToString().StartsWith("169.254"))
                .Select(a => a.Address.ToString()).Distinct().Take(3);
            IpAddresses = string.Join("  ·  ", ips);
        }
        catch { IpAddresses = ""; }
    }

    private void OnSessionStarted(SessionInfo e)
    {
        var existing = Sessions.FirstOrDefault(x => x.SessionId == e.SessionId);
        if (existing != null) existing.Update(e);
        else Sessions.Add(new SessionViewModel(e));
        RefreshHero();
        TabletConnected?.Invoke(this, e);
    }

    private void OnSessionEnded(SessionInfo e)
    {
        var vm = Sessions.FirstOrDefault(x => x.SessionId == e.SessionId);
        if (vm != null) Sessions.Remove(vm);
        RefreshHero();
    }

    [RelayCommand]
    public async Task TogglePauseAsync()
    {
        if (_server.State == ServerState.Paused || _server.State == ServerState.Error || _server.State == ServerState.Stopped)
        {
            _settings.Update(s => s.ServerPaused = false);
            await _server.StartAsync();
        }
        else
        {
            _settings.Update(s => s.ServerPaused = true);
            await _server.StopAsync(paused: true);
            Sessions.Clear();
        }
        RefreshHero();
    }

    [RelayCommand]
    private void Disconnect(SessionViewModel? s)
    {
        if (s == null) return;
        try { _server.Disconnect(s.SessionId); }
        catch (Exception ex) { _log.LogWarning(ex, "Disconnect failed"); }
    }

    // ================= USB / ADB =================
    public ObservableCollection<AdbDeviceViewModel> AdbDevices { get; } = new();
    [ObservableProperty] private string _adbStatusText = "Looking for adb…";
    [ObservableProperty] private string _adbStatusTone = "info";
    [ObservableProperty] private string _adbPathText = "";
    [ObservableProperty] private bool _adbMissing;
    [ObservableProperty] private bool _adbDownloading;
    [ObservableProperty] private double _adbDownloadProgress;
    [ObservableProperty] private string? _adbError;
    public bool HasAdbDevices => AdbDevices.Count > 0;

    private void RefreshAdb()
    {
        AdbMissing = _adb.Status == AdbStatus.NotFound;
        AdbDownloading = _adb.Status == AdbStatus.Downloading;
        AdbPathText = _adb.AdbPath == null ? "" : $"{_adb.AdbPath}{(string.IsNullOrEmpty(_adb.AdbVersion) ? "" : "  ·  " + _adb.AdbVersion)}";
        AdbError = _adb.Status == AdbStatus.Error ? _adb.LastError : null;
        var reversed = _adb.ReversedSerials;
        var devices = _adb.Devices;
        AdbDevices.Clear();
        foreach (var d in devices) AdbDevices.Add(new AdbDeviceViewModel(d, reversed.Contains(d.Serial)));
        OnPropertyChanged(nameof(HasAdbDevices));

        // One tablet can appear twice (USB cable + wireless debugging); count physical devices.
        var ready = devices.Where(d => d.IsReady).Select(d => d.PhysicalSerial ?? d.Serial).Distinct().Count();
        var unauth = devices.Count(d => d.IsUnauthorized);
        (AdbStatusText, AdbStatusTone) = _adb.Status switch
        {
            AdbStatus.Searching => ("Looking for adb…", "info"),
            AdbStatus.NotFound => ("Android platform-tools not found", "warn"),
            AdbStatus.Downloading => ("Downloading platform-tools…", "info"),
            AdbStatus.Error => ("adb error", "bad"),
            _ when ready > 0 => (
                (ready == 1 ? "1 tablet ready" : $"{ready} tablets ready") +
                (devices.Where(d => d.IsReady).All(d => d.IsWireless) ? " via wireless debugging" : " over USB"), "good"),
            _ when unauth > 0 => ("Authorize this PC on your tablet", "warn"),
            _ => ("adb running — no tablet detected", "neutral"),
        };
        (UsbChip, UsbChipTone) = _adb.Status switch
        {
            AdbStatus.NotFound => ("USB: adb missing", "warn"),
            AdbStatus.Running when ready > 0 => (ready == 1 ? "USB: 1 tablet" : $"USB: {ready} tablets", "good"),
            AdbStatus.Running when unauth > 0 => ("USB: authorize tablet", "warn"),
            AdbStatus.Running => ("USB: no tablet", "neutral"),
            AdbStatus.Error => ("USB: adb error", "bad"),
            _ => ("USB: starting", "info"),
        };
    }

    [RelayCommand]
    private async Task DownloadAdbAsync()
    {
        AdbError = null;
        var progress = new Progress<double>(p => AdbDownloadProgress = p * 100);
        try { await _adb.DownloadPlatformToolsAsync(progress); }
        catch (Exception ex) { AdbError = "Download failed: " + ex.Message; }
        RefreshAdb();
    }

    [RelayCommand]
    private void RescanAdb()
    {
        _adb.Rescan();
        _adb.ReapplyAll();
    }

    [RelayCommand]
    private void ReapplyReverse() => _adb.ReapplyAll();

    // ================= Extended display (VDD) =================
    [ObservableProperty] private string _vddTitle = "Checking…";
    [ObservableProperty] private string _vddDetail = "";
    [ObservableProperty] private string _vddTone = "info";
    [ObservableProperty] private bool _vddInstalled;
    [ObservableProperty] private bool _vddNeedsRepair;
    [ObservableProperty] private bool _vddBusy;
    [ObservableProperty] private string? _vddProgress;
    [ObservableProperty] private string? _vddError;
    [ObservableProperty] private string _vddSettingsPath = VddSettingsFile.ResolvePath();
    [ObservableProperty] private string _vddInstance = "";
    [ObservableProperty] private string _vddMonitors = "None";
    [ObservableProperty] private string _vddModes = "—";
    /// "Your tablet asked for 2224×1668; 2048×1536 is used." — shown with the "Add this resolution" button.
    [ObservableProperty] private string? _vddModeHint;
    public bool VddNotInstalled => !VddInstalled;
    partial void OnVddInstalledChanged(bool value) => OnPropertyChanged(nameof(VddNotInstalled));

    private void RefreshVdd()
    {
        var st = _vdd.Status;
        VddInstalled = st.State is VddState.Ready or VddState.Error or VddState.Disabled or VddState.NeedsRepair;
        VddNeedsRepair = st.State == VddState.NeedsRepair;
        VddInstance = st.InstanceId ?? "";
        VddSettingsPath = VddSettingsFile.ResolvePath();
        var active = _vdd.ActiveMonitors;
        VddMonitors = st.State switch
        {
            VddState.Ready when active.Count > 0 => "In use: " + string.Join(", ", active.Select(a =>
                _vdd.AppliedScales.TryGetValue(a, out var pct) ? $"{a} · scale {pct}%" : a)),
            VddState.Ready => "Connected, off the desktop until a tablet uses it",
            VddState.NeedsRepair => "Missing — the adapter started without a monitor",
            _ => "None",
        };
        VddModes = DescribeModes();
        var fb = _vdd.LastModeFallback;
        VddModeHint = st.State == VddState.Ready && fb != null
            ? $"Your tablet asked for {fb.RequestedWidth}×{fb.RequestedHeight}, which isn't in the driver's mode list, so {fb.Used.Width}×{fb.Used.Height} is used and the picture is scaled."
            : null;
        (VddTitle, VddDetail, VddTone) = st.State switch
        {
            VddState.Ready => ("Virtual display ready", "Tablets that ask for “Extend” or “Primary” get their own monitor. With no monitor plugged in, the tablet becomes the main screen.", "good"),
            VddState.NeedsRepair => ("Needs repair", "Virtual monitor didn't start — click Repair (admin). PlexiChore rewrites the driver settings with a compact mode list and restarts the virtual display.", "bad"),
            VddState.NotInstalled => ("Not installed", "Without the driver, tablets can only mirror an existing monitor. Install it to use your tablet as a second screen.", "warn"),
            VddState.Disabled => ("Driver disabled", st.Detail ?? "Enable it in Device Manager or click Repair.", "warn"),
            VddState.Error => ("Driver problem", st.Detail ?? "Click Repair to reinstall.", "bad"),
            _ => ("Checking…", "", "info"),
        };
        ExtendChip = st.State switch
        {
            VddState.Ready => "Extend: ready",
            VddState.NotInstalled => "Extend: not installed",
            VddState.Unknown => "Extend: checking",
            _ => "Extend: needs repair",
        };
        ExtendChipTone = st.State switch { VddState.Ready => "good", VddState.Unknown => "info", VddState.NotInstalled => "neutral", _ => "warn" };
    }

    private string DescribeModes()
    {
        try
        {
            var path = VddSettingsFile.ResolvePath();
            if (!File.Exists(path)) return "—";
            var f = VddSettingsFile.Load(path);
            var text = $"{f.Resolutions.Count} resolutions · {f.GeneratedModeCount} modes";
            return f.IsWithinCap ? text : text + " — too many, click Repair";
        }
        catch { return "—"; }
    }

    private async Task RunVddAsync(Func<IProgress<string>, Task> op, string success)
    {
        if (VddBusy) return;
        VddBusy = true; VddError = null;
        var p = new Progress<string>(m => VddProgress = m);
        try
        {
            await op(p);
            VddProgress = success;
        }
        catch (OperationCanceledException ex) { VddProgress = null; VddError = ex.Message; }
        catch (Exception ex)
        {
            _log.LogError(ex, "VDD operation failed");
            VddProgress = null;
            VddError = ex.Message;
        }
        finally
        {
            await _vdd.RefreshAsync();
            RefreshVdd();
            VddBusy = false;
        }
    }

    /// After install / restart the monitor arrives and Windows extends onto it: wait for it, then take it off the
    /// desktop again unless a tablet is using it.
    private async Task AfterDeviceStartAsync()
    {
        for (var i = 0; i < 16; i++)
        {
            await Task.Delay(500);
            if ((await _vdd.RefreshAsync()).MonitorPresent) break;
        }
        await Task.Delay(1000); // let Windows finish auto-extending
        if (_server.Sessions.Count == 0) await _vdd.DetachStrayAsync();
    }

    private bool ConfirmDeviceRestart()
    {
        if (_server.Sessions.Count == 0) return true;
        return MessageBox.Show("A tablet is using the virtual monitor. Restarting the virtual display interrupts that session. Continue?",
            "PlexiChore", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
    }

    [RelayCommand]
    private Task InstallVddAsync() => RunVddAsync(async p =>
    {
        await _vddInstaller.InstallAsync(p);
        await AfterDeviceStartAsync();
    }, "Installed. Tablets can now use Extend and Primary mode.");

    /// Repair: driver files missing/broken → reinstall; otherwise rewrite the compact settings + elevated restart.
    [RelayCommand]
    private Task RepairVddAsync()
    {
        if (!ConfirmDeviceRestart()) return Task.CompletedTask;
        return RunVddAsync(async p =>
        {
            var st = await _vdd.RefreshAsync();
            if (st.State is VddState.NotInstalled || st.ConfigManagerErrorCode is 1 or 18 or 19 or 28 or 31 or 39 or 48 or 52)
                await _vddInstaller.InstallAsync(p);
            else
                await _vddInstaller.RepairAsync(st.InstanceId, p);
            await AfterDeviceStartAsync();
            if (!_vdd.Status.MonitorPresent && _vdd.Status.State != VddState.NotInstalled)
                throw new InvalidOperationException("The virtual monitor still didn't start. Try again, or restart Windows.");
        }, "Repaired — the virtual monitor is back.");
    }

    [RelayCommand]
    private Task UninstallVddAsync()
    {
        var r = MessageBox.Show("Remove the Virtual Display Driver? Tablets will only be able to mirror an existing screen.",
            "PlexiChore", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (r != MessageBoxResult.Yes) return Task.CompletedTask;
        return RunVddAsync(p => _vddInstaller.UninstallAsync(p), "Driver removed.");
    }

    [RelayCommand]
    private Task RestartVddAsync()
    {
        if (!ConfirmDeviceRestart()) return Task.CompletedTask;
        return RunVddAsync(async p =>
        {
            var id = _vdd.Status.InstanceId ?? throw new InvalidOperationException("Driver is not installed.");
            p.Report("Restarting the virtual display (approve the Windows prompt)…");
            await _vddInstaller.RestartDeviceAsync(id);
            await AfterDeviceStartAsync();
        }, "Virtual display restarted.");
    }

    /// Adds the last tablet's exact resolution (within the mode cap) and restarts the device — one UAC prompt.
    [RelayCommand]
    private Task AddTabletModeAsync()
    {
        var fb = _vdd.LastModeFallback;
        if (fb == null) return Task.CompletedTask;
        if (!ConfirmDeviceRestart()) return Task.CompletedTask;
        var (w, h) = (fb.RequestedWidth, fb.RequestedHeight);
        return RunVddAsync(async p =>
        {
            var extras = VddExtraModes.Load();
            var preview = VddSettingsFile.Load(VddSettingsFile.ResolvePath());
            preview.Normalize(extras);
            switch (preview.TryAddMode(w, h))
            {
                case AddModeResult.CapReached:
                    throw new InvalidOperationException(
                        $"The mode list is full ({VddSettingsFile.MaxResolutions} resolutions). Too many modes stop the virtual monitor from starting.");
                case AddModeResult.Invalid:
                    throw new InvalidOperationException($"{w}×{h} is not a valid resolution.");
            }
            VddExtraModes.Add(w, h);
            _vdd.ClearModeFallback();
            await _vddInstaller.RepairAsync(_vdd.Status.InstanceId, p, VddExtraModes.Load());
            await AfterDeviceStartAsync();
        }, $"Added {w}×{h}. It is used the next time the tablet connects in Extend mode.");
    }

    [RelayCommand]
    private void OpenVddSettings()
    {
        var dir = Path.GetDirectoryName(VddSettingsPath);
        if (dir != null && Directory.Exists(dir)) Process.Start("explorer.exe", $"\"{dir}\"");
    }

    // ================= Settings =================
    [ObservableProperty] private bool _startWithWindows;
    [ObservableProperty] private bool _requireApprovalForWifi;
    [ObservableProperty] private bool _showConnectNotifications;
    [ObservableProperty] private int _encoderIndex;
    [ObservableProperty] private bool _firewallOk;
    [ObservableProperty] private string _firewallText = "Checking…";
    [ObservableProperty] private string? _firewallError;
    public ObservableCollection<TrustedDevice> TrustedDevices { get; } = new();
    public bool HasTrustedDevices => TrustedDevices.Count > 0;

    partial void OnStartWithWindowsChanged(bool value)
    {
        try { StartupRegistration.Set(value); }
        catch (Exception ex) { _log.LogWarning(ex, "Run key update failed"); }
        _settings.Update(s => s.StartWithWindows = value);
    }

    partial void OnRequireApprovalForWifiChanged(bool value)
    {
        _settings.Update(s => s.RequireApprovalForWifi = value);
        _ = _server.ApplyOptionsAsync();
    }

    partial void OnShowConnectNotificationsChanged(bool value) => _settings.Update(s => s.ShowConnectNotifications = value);

    partial void OnEncoderIndexChanged(int value)
    {
        _settings.Update(s => s.PreferHardwareEncoder = value == 0);
        _ = _server.ApplyOptionsAsync();
    }

    public void AddTrusted(string id, string name)
    {
        _settings.AddTrusted(id, name);
        ReloadTrusted();
        _ = _server.ApplyOptionsAsync();
    }

    [RelayCommand]
    private void RemoveTrusted(TrustedDevice? d)
    {
        if (d == null) return;
        _settings.RemoveTrusted(d.Id);
        ReloadTrusted();
        _ = _server.ApplyOptionsAsync();
    }

    private void ReloadTrusted()
    {
        TrustedDevices.Clear();
        foreach (var t in _settings.Current.TrustedDevices.OrderByDescending(t => t.AddedUtc)) TrustedDevices.Add(t);
        OnPropertyChanged(nameof(HasTrustedDevices));
    }

    private async Task RefreshFirewallAsync()
    {
        FirewallOk = await _firewall.AreRulesPresentAsync();
        FirewallText = FirewallOk
            ? "Inbound rules for TCP 47800 and UDP 47801 are present."
            : "Not configured. Add rules so tablets on Wi‑Fi can find and reach this PC.";
    }

    [RelayCommand]
    private async Task AddFirewallRulesAsync()
    {
        FirewallError = null;
        try { await _firewall.AddRulesAsync(); }
        catch (OperationCanceledException ex) { FirewallError = ex.Message; }
        catch (Exception ex) { FirewallError = ex.Message; }
        await RefreshFirewallAsync();
    }

    [RelayCommand]
    private void OpenLogs()
    {
        Directory.CreateDirectory(AppPaths.LogsDir);
        Process.Start("explorer.exe", $"\"{AppPaths.LogsDir}\"");
    }

    [RelayCommand]
    private void OpenUrl(string? url)
    {
        if (string.IsNullOrEmpty(url)) return;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    // ================= About =================
    public string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";
    public string HostId => _settings.Current.HostId;
    public string LogsPath => AppPaths.LogsDir;

#if DEBUG
    /// Design-time helper (PLEXICHORE_DEMO_UI=1, Debug builds only): shows a fake connected session.
    internal void InjectDemoSession()
    {
        var info = new SessionInfo(Guid.NewGuid(), "demo", "Galaxy Tab S8", "SM-X700", true, "extend", 2560, 1600, 60, "h264");
        OnSessionStarted(info);
        Sessions.First(s => s.SessionId == info.SessionId).Apply(new SessionStats(info.SessionId, 59.8, 4.2, 18450, 3.6));
    }
#endif

    // ================= Navigation =================
    [ObservableProperty] private int _selectedPage;

    [RelayCommand]
    private void Navigate(string? page)
    {
        if (int.TryParse(page, out var i)) SelectedPage = i;
    }
}
