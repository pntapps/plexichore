using System.Windows;
using System.Windows.Threading;
using Microsoft.Extensions.Logging;
using PlexiChore.App.Services;
using PlexiChore.App.Services.Adb;
using PlexiChore.App.ViewModels;
using PlexiChore.App.Views;
using PlexiChore.App.VirtualDisplay;
using PlexiChore.Engine;

namespace PlexiChore.App;

public partial class App : Application
{
    public static new App Current => (App)Application.Current;
    public static bool IsQuitting { get; private set; }

    private SingleInstance? _single;
    private ILoggerFactory? _loggerFactory;
    private FileLoggerProvider? _fileLog;
    private ILogger<App>? _log;
    private SettingsService? _settings;
    private ServerHost? _server;
    private AdbManager? _adb;
    private VirtualDisplayDriverProvider? _vdd;
    private MainViewModel? _vm;
    private MainWindow? _window;
    private TrayService? _tray;
    private bool _toldAboutTray;
    private readonly Dictionary<string, PairingWindow> _pairings = new();

    public App()
    {
        BootTrace.Mark("App ctor");
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        BootTrace.Mark("OnStartup");
        base.OnStartup(e);
        var minimized = e.Args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase) ||
                                        a.Equals("/minimized", StringComparison.OrdinalIgnoreCase));

        _single = SingleInstance.TryAcquire(() => Dispatcher.BeginInvoke(ShowMainWindow));
        if (_single == null) { Shutdown(0); return; }
        BootTrace.Mark("single instance acquired");

        _fileLog = new FileLoggerProvider(AppPaths.LogsDir);
        _loggerFactory = LoggerFactory.Create(b => b.SetMinimumLevel(LogLevel.Debug).AddProvider(_fileLog));
        _log = _loggerFactory.CreateLogger<App>();
        _log.LogInformation("PlexiChore Desktop starting (minimized={Min}) from {Exe}", minimized, AppPaths.ExecutablePath);
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, ev) => _log?.LogCritical(ev.ExceptionObject as Exception, "Unhandled exception");
        TaskScheduler.UnobservedTaskException += (_, ev) => { _log?.LogError(ev.Exception, "Unobserved task exception"); ev.SetObserved(); };

        // Brand accent (violet) for WPF-UI controls such as toggles, checkboxes and focus rings.
        Wpf.Ui.Appearance.ApplicationAccentColorManager.Apply(
            System.Windows.Media.Color.FromRgb(0x7C, 0x4D, 0xFF), Wpf.Ui.Appearance.ApplicationTheme.Dark);

        _settings = new SettingsService();
        FirstRun(_settings);

        _vdd = new VirtualDisplayDriverProvider(_loggerFactory.CreateLogger<VirtualDisplayDriverProvider>());
        _server = new ServerHost(_settings, _vdd, _loggerFactory);
        _vdd.HasActiveSessions = () => _server.Sessions.Count > 0;
        _adb = new AdbManager(_loggerFactory.CreateLogger<AdbManager>(), () => _settings.Current.AdbPath)
        {
            AutoReverse = _settings.Current.AutoAdbReverse,
        };
        var adbForLink = _adb;
        _server.LoopbackLinkResolver = (model, ct) => adbForLink.ResolveLoopbackLinkAsync(model, ct);
        var firewall = new FirewallService(_loggerFactory.CreateLogger<FirewallService>());
        var installer = new VddInstaller(_loggerFactory.CreateLogger<VddInstaller>());

        _vm = new MainViewModel(_server, _adb, _vdd, installer, firewall, _settings, _loggerFactory.CreateLogger<MainViewModel>());
        _vm.TabletConnected += OnTabletConnected;
        _server.PairingRequested += (_, req) => Dispatcher.BeginInvoke(() => ShowPairing(req));

        BootTrace.Mark("creating window");
        _window = new MainWindow(_vm);
        BootTrace.Mark("window created");
        _tray = new TrayService(_vm, ShowMainWindow, Quit);
        if (!minimized) _window.Show();
        BootTrace.Mark("window shown");

        _adb.Start();
        _vdd.StartMonitoring();
        // crash recovery: removes leftover virtual monitors and puts the original primary display back
        try
        {
            await _vdd.DetachAllOwnedAsync();
            // the monitor is permanently connected and Windows auto-extends onto it after a reboot / driver restart;
            // no tablet session exists yet, so take it off the desktop
            await _vdd.DetachStrayAsync();
        }
        catch (Exception ex) { _log.LogWarning(ex, "Startup VDD cleanup failed"); }
        if (!_settings.Current.ServerPaused) await _server.StartAsync();
        else await _server.StopAsync(paused: true);
#if DEBUG
        if (Environment.GetEnvironmentVariable("PLEXICHORE_DEMO_UI") == "1")
        {
            _vm.InjectDemoSession();
            ShowPairing(new PairingRequest { DeviceId = "demo-pair", DeviceName = "Galaxy Tab S9 FE", Code = "4821", Respond = _ => { } });
        }
#endif
    }

    private void FirstRun(SettingsService settings)
    {
        if (settings.Current.FirstRunCompleted)
        {
            StartupRegistration.Sync(settings.Current.StartWithWindows);
            return;
        }
        // Don't register dev builds (bin\Debug|Release) to run at login; installed/published builds default to on.
        var exe = AppPaths.ExecutablePath;
        var isDevBuild = exe.Contains(@"\bin\Debug\", StringComparison.OrdinalIgnoreCase) ||
                         exe.Contains(@"\bin\Release\", StringComparison.OrdinalIgnoreCase);
        settings.Update(s =>
        {
            s.FirstRunCompleted = true;
            s.StartWithWindows = !isDevBuild && (StartupRegistration.IsEnabled() || s.StartWithWindows);
        });
        StartupRegistration.Sync(settings.Current.StartWithWindows);
    }

    public void ShowMainWindow() => _window?.BringToFront();

    public void NotifyHiddenToTrayOnce()
    {
        if (_toldAboutTray) return;
        _toldAboutTray = true;
        _tray?.Notify("PlexiChore is still running", "Tablets can keep connecting. Use the tray icon to open or quit.");
    }

    private void OnTabletConnected(object? sender, SessionInfo s)
    {
        if (_settings?.Current.ShowConnectNotifications != true) return;
        var mode = s.Mode?.ToLowerInvariant() switch
        {
            "extend" => "extended display",
            "primary" => "primary display",
            _ => "mirrored display",
        };
        _tray?.Notify($"{(string.IsNullOrWhiteSpace(s.DeviceName) ? "Tablet" : s.DeviceName)} connected",
            $"{(s.IsUsb ? "USB" : "Wi‑Fi")} · {mode} · {s.Width}×{s.Height} @ {s.Fps} fps");
    }

    private void ShowPairing(PairingRequest req)
    {
        // If the same tablet re-asks, replace the old prompt (the old request gets rejected).
        if (_pairings.Remove(req.DeviceId, out var old)) old.Answer(false);
        var w = new PairingWindow(req, (r, approve, remember) =>
        {
            _pairings.Remove(r.DeviceId);
            _log?.LogInformation("Pairing {Device} ({Id}): {Result}", r.DeviceName, r.DeviceId, approve ? "approved" : "rejected");
            if (approve && remember) _vm?.AddTrusted(r.DeviceId, r.DeviceName);
            try { r.Respond(approve); } catch (Exception ex) { _log?.LogWarning(ex, "Pairing respond failed"); }
        });
        _pairings[req.DeviceId] = w;
        w.Show();
        w.Activate();
    }

    public async void Quit()
    {
        if (IsQuitting) return;
        IsQuitting = true;
        _log?.LogInformation("Quitting");
        foreach (var p in _pairings.Values.ToList()) p.Answer(false);
        try { if (_server != null) await _server.DisposeAsync(); } catch { }
        try { if (_vdd != null) await _vdd.DetachAllOwnedAsync().WaitAsync(TimeSpan.FromSeconds(8)); } catch { }
        try { if (_adb != null) await _adb.DisposeAsync(); } catch { }
        _tray?.Dispose();
        _window?.Close();
        _vdd?.Dispose();
        _loggerFactory?.Dispose();
        _single?.Dispose();
        Shutdown(0);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        _log?.LogError(e.Exception, "UI exception");
        e.Handled = true;
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        IsQuitting = true;
        try { _vdd?.DetachAllOwnedAsync().Wait(TimeSpan.FromSeconds(3)); } catch { }
        base.OnSessionEnding(e);
    }
}
