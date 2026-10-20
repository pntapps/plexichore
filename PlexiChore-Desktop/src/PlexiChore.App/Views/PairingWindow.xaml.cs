using System.Media;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using PlexiChore.Engine;

namespace PlexiChore.App.Views;

/// Topmost approval popup for an unknown Wi-Fi tablet. Exactly one Respond() call is made (approve, reject,
/// close or 60 s timeout → reject).
public partial class PairingWindow : Window
{
    private readonly PairingRequest _request;
    private readonly Action<PairingRequest, bool, bool> _onDecision;
    private readonly DispatcherTimer _timer;
    private int _remaining = 60;
    private bool _answered;

    public PairingWindow(PairingRequest request, Action<PairingRequest, bool, bool> onDecision)
    {
        _request = request;
        _onDecision = onDecision;
        InitializeComponent();
        DeviceNameText.Text = string.IsNullOrWhiteSpace(request.DeviceName) ? "A tablet" : request.DeviceName;
        CodeDigits.ItemsSource = (request.Code ?? "----").Select(c => c.ToString()).ToList();
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) =>
        {
            _remaining--;
            CountdownText.Text = $"Expires in {_remaining} s";
            if (_remaining <= 0) Answer(false);
        };
        Loaded += (_, _) =>
        {
            _timer.Start();
            try { SystemSounds.Asterisk.Play(); } catch { }
            Activate();
        };
    }

    public string DeviceId => _request.DeviceId;

    private void OnDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch { }
    }

    private void OnApprove(object sender, RoutedEventArgs e) => Answer(true);
    private void OnReject(object sender, RoutedEventArgs e) => Answer(false);

    public void Answer(bool approve)
    {
        if (_answered) return;
        _answered = true;
        _timer.Stop();
        _onDecision(_request, approve, RememberBox.IsChecked == true);
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        if (!_answered) { _answered = true; _timer.Stop(); _onDecision(_request, false, false); }
        base.OnClosed(e);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Answer(false);
        base.OnKeyDown(e);
    }
}
