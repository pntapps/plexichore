using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace PlexiChore.App.Views;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var b = value switch
        {
            bool x => x,
            int i => i != 0,
            string s => !string.IsNullOrWhiteSpace(s),
            null => false,
            _ => true,
        };
        if (Invert) b = !b;
        return b ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// Maps a Tone string (good|warn|bad|info|neutral) to a foreground or soft background brush.
public sealed class ToneToBrushConverter : IValueConverter
{
    public bool Soft { get; set; }
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var key = (value as string ?? "neutral") switch
        {
            "good" => Soft ? "Plexi.GreenSoftBrush" : "Plexi.GreenBrush",
            "warn" => Soft ? "Plexi.AmberSoftBrush" : "Plexi.AmberBrush",
            "bad" => Soft ? "Plexi.RedSoftBrush" : "Plexi.RedBrush",
            "info" => Soft ? "Plexi.CyanSoftBrush" : "Plexi.CyanBrush",
            "accent" => Soft ? "Plexi.VioletSoftBrush" : "Plexi.VioletLightBrush",
            _ => Soft ? "Plexi.SubtleBrush2" : "Plexi.TextSecondaryBrush",
        };
        return Application.Current.TryFindResource(key) as Brush ?? Brushes.Gray;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// Visible when the bound int equals ConverterParameter (page switching).
public sealed class IndexToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is int i && int.TryParse(parameter?.ToString(), out var p) && i == p ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
