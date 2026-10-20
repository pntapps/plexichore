using System.Collections.Concurrent;
using System.Text;
using Microsoft.Extensions.Logging;

namespace PlexiChore.App.Services;

/// Minimal daily-rolling file logger (%LOCALAPPDATA%\PlexiChore\logs\plexichore-yyyyMMdd.log), 7 days retained.
public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _dir;
    private readonly BlockingCollection<string> _queue = new(10_000);
    private readonly Thread _writer;
    private readonly ConcurrentDictionary<string, FileLogger> _loggers = new();

    public FileLoggerProvider(string dir)
    {
        _dir = dir;
        Directory.CreateDirectory(dir);
        Prune();
        _writer = new Thread(WriteLoop) { IsBackground = true, Name = "PlexiChore log writer" };
        _writer.Start();
    }

    public string CurrentFile => Path.Combine(_dir, $"plexichore-{DateTime.Now:yyyyMMdd}.log");

    public ILogger CreateLogger(string categoryName) =>
        _loggers.GetOrAdd(categoryName, n => new FileLogger(n, this));

    internal void Enqueue(string line) => _queue.TryAdd(line);

    private void WriteLoop()
    {
        foreach (var line in _queue.GetConsumingEnumerable())
        {
            try
            {
                var sb = new StringBuilder(line).AppendLine();
                while (_queue.TryTake(out var more)) sb.AppendLine(more);
                File.AppendAllText(CurrentFile, sb.ToString());
            }
            catch { /* never let logging crash the app */ }
        }
    }

    private void Prune()
    {
        try
        {
            foreach (var f in new DirectoryInfo(_dir).GetFiles("plexichore-*.log")
                         .Where(f => f.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-7)))
                f.Delete();
        }
        catch { }
    }

    public void Dispose()
    {
        _queue.CompleteAdding();
        _writer.Join(TimeSpan.FromSeconds(2));
    }

    private sealed class FileLogger(string category, FileLoggerProvider owner) : ILogger
    {
        private readonly string _short = category.Contains('.') ? category[(category.LastIndexOf('.') + 1)..] : category;

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Debug;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            var lvl = logLevel switch
            {
                LogLevel.Trace => "TRC", LogLevel.Debug => "DBG", LogLevel.Information => "INF",
                LogLevel.Warning => "WRN", LogLevel.Error => "ERR", LogLevel.Critical => "CRT", _ => "???"
            };
            var msg = $"{DateTime.Now:HH:mm:ss.fff} [{lvl}] {_short}: {formatter(state, exception)}";
            if (exception != null) msg += Environment.NewLine + exception;
            owner.Enqueue(msg);
        }
    }
}
