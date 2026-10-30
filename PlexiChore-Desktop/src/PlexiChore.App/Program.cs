using System.Runtime.CompilerServices;
using PlexiChore.App.Services;

namespace PlexiChore.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == Watchdog.Arg && int.TryParse(args[1], out var pid)) return Watchdog.Run(pid);
        return RunApp();
    }

    // separate method so the watchdog process never loads WPF
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static int RunApp()
    {
        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
