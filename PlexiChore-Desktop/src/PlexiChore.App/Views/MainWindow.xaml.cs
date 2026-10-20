using System.ComponentModel;
using System.Windows;
using PlexiChore.App.ViewModels;

namespace PlexiChore.App.Views;

public partial class MainWindow : Wpf.Ui.Controls.FluentWindow
{
    public MainWindow(MainViewModel vm)
    {
        DataContext = vm;
        InitializeComponent();
    }

    /// Closing the window hides it to the tray; only App.Quit really exits.
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!App.IsQuitting)
        {
            e.Cancel = true;
            Hide();
            App.Current.NotifyHiddenToTrayOnce();
            return;
        }
        base.OnClosing(e);
    }

    public void BringToFront()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;   // reliable foreground on Windows 10
        Topmost = false;
        Focus();
    }
}
