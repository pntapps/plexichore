using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.Input;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using PlexiChore.App.ViewModels;

namespace PlexiChore.App.Services;

/// System tray icon: click opens the window; menu shows connected tablets, Pause/Resume and Quit.
public sealed class TrayService : IDisposable
{
    private readonly TaskbarIcon _icon;
    private readonly MainViewModel _vm;
    private readonly Action _open;
    private readonly Action _quit;

    public TrayService(MainViewModel vm, Action open, Action quit)
    {
        _vm = vm; _open = open; _quit = quit;
        _icon = new TaskbarIcon
        {
            ToolTipText = "PlexiChore",
            IconSource = new BitmapImage(new Uri("pack://application:,,,/Assets/PlexiChore.ico")),
            NoLeftClickDelay = true,
            LeftClickCommand = new RelayCommand(open),
            ContextMenu = new ContextMenu(),
        };
        _icon.ContextMenu.Opened += (_, _) => BuildMenu();
        BuildMenu();
        _icon.ForceCreate(enablesEfficiencyMode: false);
        _vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MainViewModel.HeroTitle)) UpdateTooltip();
        };
        UpdateTooltip();
    }

    private void UpdateTooltip()
    {
        var t = $"PlexiChore — {_vm.HeroTitle}";
        _icon.ToolTipText = t.Length > 120 ? t[..120] : t;
    }

    private void BuildMenu()
    {
        var m = _icon.ContextMenu!;
        m.Items.Clear();
        var open = new MenuItem { Header = "Open PlexiChore", FontWeight = FontWeights.SemiBold };
        open.Click += (_, _) => _open();
        m.Items.Add(open);
        m.Items.Add(new Separator());

        if (_vm.Sessions.Count == 0)
        {
            m.Items.Add(new MenuItem { Header = _vm.IsPaused ? "Server paused" : "No tablets connected", IsEnabled = false });
        }
        else
        {
            m.Items.Add(new MenuItem { Header = "Connected tablets", IsEnabled = false });
            foreach (var s in _vm.Sessions)
            {
                var item = new MenuItem { Header = $"{s.DeviceName}  ·  {s.TransportText} · {s.ModeText}" };
                var disc = new MenuItem { Header = "Disconnect" };
                var captured = s;
                disc.Click += (_, _) => _vm.DisconnectCommand.Execute(captured);
                item.Items.Add(disc);
                m.Items.Add(item);
            }
        }
        m.Items.Add(new Separator());
        var pause = new MenuItem { Header = _vm.IsPaused ? "Resume server" : "Pause server" };
        pause.Click += async (_, _) => await _vm.TogglePauseAsync();
        m.Items.Add(pause);
        var quit = new MenuItem { Header = "Quit PlexiChore" };
        quit.Click += (_, _) => _quit();
        m.Items.Add(quit);
    }

    public void Notify(string title, string message)
    {
        try { _icon.ShowNotification(title, message, NotificationIcon.Info); }
        catch { }
    }

    public void Dispose() => _icon.Dispose();
}
