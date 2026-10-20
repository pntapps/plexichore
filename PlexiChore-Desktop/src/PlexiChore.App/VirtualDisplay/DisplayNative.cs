using System.Drawing;
using System.Runtime.InteropServices;
using PlexiChore.Engine;

namespace PlexiChore.App.VirtualDisplay;

/// GDI + DisplayConfig interop used to find, attach, mode-set, position and detach the virtual monitor.
/// All coordinates are physical pixels (process is per-monitor DPI aware v2).
internal static unsafe partial class DisplayNative
{
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int ENUM_REGISTRY_SETTINGS = -2;

    public const uint DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x1;
    public const uint DISPLAY_DEVICE_PRIMARY_DEVICE = 0x4;
    public const uint DISPLAY_DEVICE_MIRRORING_DRIVER = 0x8;
    public const uint DISPLAY_DEVICE_ACTIVE = 0x1; // monitor-level flag

    public const uint DM_POSITION = 0x00000020;
    public const uint DM_BITSPERPEL = 0x00040000;
    public const uint DM_PELSWIDTH = 0x00080000;
    public const uint DM_PELSHEIGHT = 0x00100000;
    public const uint DM_DISPLAYFREQUENCY = 0x00400000;

    public const uint CDS_UPDATEREGISTRY = 0x00000001;
    public const uint CDS_SET_PRIMARY = 0x00000010;
    public const uint CDS_NORESET = 0x10000000;

    public const int DISP_CHANGE_SUCCESSFUL = 0;
    public const int DISP_CHANGE_RESTART = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;

        public static DISPLAY_DEVICE Create() => new() { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;

        public static DEVMODE Create() => new()
        {
            dmDeviceName = "", dmFormName = "",
            dmSize = (ushort)Marshal.SizeOf<DEVMODE>(),
        };
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
    public static extern bool EnumDisplayDevices(string? lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsExW")]
    public static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    public static extern int ChangeDisplaySettingsEx(string? lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    public static extern int ChangeDisplaySettingsExApply(string? lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    // ---------------- DisplayConfig ----------------
    public const uint QDC_ALL_PATHS = 0x1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 0x2;
    public const uint SDC_TOPOLOGY_EXTEND = 0x4;
    public const uint SDC_APPLY = 0x80;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
        public uint rotation; public uint scaling; public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering; public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType; public uint id; public LUID adapterId;
        public fixed byte union[48];
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags; public uint outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_ADAPTER_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string adapterDevicePath;
    }

    public const uint DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
    public const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    public const uint DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME = 4;

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_ADAPTER_NAME requestPacket);

    // ---- per-monitor display scale (undocumented but stable since Windows 10 1607; used by Settings > Display and
    // the open-source SetDPI tool). Values are indices into DisplayScale.DpiVals RELATIVE to the recommended scale.
    // Header adapterId/id = the SOURCE (sourceInfo.adapterId / sourceInfo.id) of an ACTIVE path. No admin needed.
    public const int DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE = -3;
    public const int DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE = -4;

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int minScaleRel;   // ≤ 0 (100% relative to recommended)
        public int curScaleRel;
        public int maxScaleRel;   // ≥ 0
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int scaleRel;
    }

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_GET requestPacket);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_SET setPacket);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    public const uint MONITOR_DEFAULTTONULL = 0;

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY); // 0 = MDT_EFFECTIVE_DPI

    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPathArrayElements, IntPtr pathArray, uint numModeInfoArrayElements, IntPtr modeInfoArray, uint flags);
}

/// A GDI display source (\\.\DISPLAYn) with its adapter/monitor identification.
public sealed record DisplayInfo(
    string GdiName,
    string AdapterString,
    string AdapterId,
    string MonitorName,
    string MonitorId,
    bool AttachedToDesktop,
    bool IsPrimary,
    Rectangle Bounds)
{
    public bool LooksLikeVdd =>
        VirtualDisplayDriverProvider.IsVddIdentity(AdapterId) || VirtualDisplayDriverProvider.IsVddIdentity(AdapterString) ||
        VirtualDisplayDriverProvider.IsVddIdentity(MonitorId) || VirtualDisplayDriverProvider.IsVddIdentity(MonitorName);
}

public sealed record DisplayMode(int Width, int Height, int Hz);

internal static class Displays
{
    public static List<DisplayInfo> Enumerate()
    {
        var list = new List<DisplayInfo>();
        var dd = DisplayNative.DISPLAY_DEVICE.Create();
        for (uint i = 0; DisplayNative.EnumDisplayDevices(null, i, ref dd, 0); i++)
        {
            if ((dd.StateFlags & DisplayNative.DISPLAY_DEVICE_MIRRORING_DRIVER) != 0) { dd = DisplayNative.DISPLAY_DEVICE.Create(); continue; }
            var mon = DisplayNative.DISPLAY_DEVICE.Create();
            string monName = "", monId = "";
            if (DisplayNative.EnumDisplayDevices(dd.DeviceName, 0, ref mon, 1 /*EDD_GET_DEVICE_INTERFACE_NAME*/))
            {
                monName = mon.DeviceString ?? "";
                monId = mon.DeviceID ?? "";
            }
            var attached = (dd.StateFlags & DisplayNative.DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
            var bounds = Rectangle.Empty;
            if (attached) bounds = GetCurrentBounds(dd.DeviceName) ?? Rectangle.Empty;
            list.Add(new DisplayInfo(dd.DeviceName, dd.DeviceString ?? "", dd.DeviceID ?? "", monName, monId,
                attached, (dd.StateFlags & DisplayNative.DISPLAY_DEVICE_PRIMARY_DEVICE) != 0, bounds));
            dd = DisplayNative.DISPLAY_DEVICE.Create();
        }
        return list;
    }

    /// Adapter device paths of active DisplayConfig sources keyed by GDI name (more reliable for IddCx adapters).
    public static Dictionary<string, (string AdapterPath, string MonitorPath, string MonitorName)> QueryActiveSources()
    {
        var map = new Dictionary<string, (string, string, string)>(StringComparer.OrdinalIgnoreCase);
        if (DisplayNative.GetDisplayConfigBufferSizes(DisplayNative.QDC_ONLY_ACTIVE_PATHS, out var np, out var nm) != 0) return map;
        var paths = new DisplayNative.DISPLAYCONFIG_PATH_INFO[np];
        var modes = new DisplayNative.DISPLAYCONFIG_MODE_INFO[nm];
        if (DisplayNative.QueryDisplayConfig(DisplayNative.QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return map;
        for (int i = 0; i < np; i++)
        {
            var p = paths[i];
            var src = new DisplayNative.DISPLAYCONFIG_SOURCE_DEVICE_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_SOURCE_DEVICE_NAME>(), adapterId = p.sourceInfo.adapterId, id = p.sourceInfo.id },
                viewGdiDeviceName = "",
            };
            if (DisplayNative.DisplayConfigGetDeviceInfo(ref src) != 0) continue;
            var ad = new DisplayNative.DISPLAYCONFIG_ADAPTER_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_ADAPTER_NAME>(), adapterId = p.sourceInfo.adapterId },
                adapterDevicePath = "",
            };
            DisplayNative.DisplayConfigGetDeviceInfo(ref ad);
            var tn = new DisplayNative.DISPLAYCONFIG_TARGET_DEVICE_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_TARGET_DEVICE_NAME>(), adapterId = p.targetInfo.adapterId, id = p.targetInfo.id },
                monitorFriendlyDeviceName = "", monitorDevicePath = "",
            };
            DisplayNative.DisplayConfigGetDeviceInfo(ref tn);
            map[src.viewGdiDeviceName] = (ad.adapterDevicePath ?? "", tn.monitorDevicePath ?? "", tn.monitorFriendlyDeviceName ?? "");
        }
        return map;
    }

    /// All connected (targetAvailable) DisplayConfig targets, active or not: adapter device path + monitor identity.
    /// Read-only (QDC_ALL_PATHS).
    public static List<(string AdapterPath, string MonitorPath, string MonitorName)> QueryAvailableTargets()
    {
        var list = new List<(string, string, string)>();
        if (DisplayNative.GetDisplayConfigBufferSizes(DisplayNative.QDC_ALL_PATHS, out var np, out var nm) != 0) return list;
        var paths = new DisplayNative.DISPLAYCONFIG_PATH_INFO[np];
        var modes = new DisplayNative.DISPLAYCONFIG_MODE_INFO[nm];
        if (DisplayNative.QueryDisplayConfig(DisplayNative.QDC_ALL_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return list;
        var seen = new HashSet<(uint, int, uint)>();
        for (int i = 0; i < np; i++)
        {
            var t = paths[i].targetInfo;
            if (t.targetAvailable == 0 || !seen.Add((t.adapterId.LowPart, t.adapterId.HighPart, t.id))) continue;
            var ad = new DisplayNative.DISPLAYCONFIG_ADAPTER_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_ADAPTER_NAME>(), adapterId = t.adapterId },
                adapterDevicePath = "",
            };
            DisplayNative.DisplayConfigGetDeviceInfo(ref ad);
            var tn = new DisplayNative.DISPLAYCONFIG_TARGET_DEVICE_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_TARGET_DEVICE_NAME>(), adapterId = t.adapterId, id = t.id },
                monitorFriendlyDeviceName = "", monitorDevicePath = "",
            };
            DisplayNative.DisplayConfigGetDeviceInfo(ref tn);
            list.Add((ad.adapterDevicePath ?? "", tn.monitorDevicePath ?? "", tn.monitorFriendlyDeviceName ?? ""));
        }
        return list;
    }

    public static Rectangle? GetCurrentBounds(string gdiName)
    {
        var dm = DisplayNative.DEVMODE.Create();
        if (!DisplayNative.EnumDisplaySettingsEx(gdiName, DisplayNative.ENUM_CURRENT_SETTINGS, ref dm, 0)) return null;
        if (dm.dmPelsWidth == 0) return null;
        return new Rectangle(dm.dmPositionX, dm.dmPositionY, (int)dm.dmPelsWidth, (int)dm.dmPelsHeight);
    }

    public static List<DisplayMode> GetModes(string gdiName)
    {
        var set = new HashSet<DisplayMode>();
        var dm = DisplayNative.DEVMODE.Create();
        for (int i = 0; DisplayNative.EnumDisplaySettingsEx(gdiName, i, ref dm, 0); i++)
        {
            if (dm.dmBitsPerPel is 0 or 32)
                set.Add(new DisplayMode((int)dm.dmPelsWidth, (int)dm.dmPelsHeight, (int)dm.dmDisplayFrequency));
            dm = DisplayNative.DEVMODE.Create();
        }
        return set.ToList();
    }

    /// Stages a mode + position for a device (attaches it to the desktop if detached). Call ApplyStaged() afterwards.
    public static int StageModeAndPosition(string gdiName, DisplayMode? mode, Point pos)
    {
        var dm = DisplayNative.DEVMODE.Create();
        dm.dmDeviceName = gdiName;
        dm.dmFields = DisplayNative.DM_POSITION;
        dm.dmPositionX = pos.X;
        dm.dmPositionY = pos.Y;
        if (mode != null)
        {
            dm.dmFields |= DisplayNative.DM_PELSWIDTH | DisplayNative.DM_PELSHEIGHT;
            dm.dmPelsWidth = (uint)mode.Width;
            dm.dmPelsHeight = (uint)mode.Height;
            if (mode.Hz > 0) { dm.dmFields |= DisplayNative.DM_DISPLAYFREQUENCY; dm.dmDisplayFrequency = (uint)mode.Hz; }
        }
        return DisplayNative.ChangeDisplaySettingsEx(gdiName, ref dm, IntPtr.Zero,
            DisplayNative.CDS_UPDATEREGISTRY | DisplayNative.CDS_NORESET, IntPtr.Zero);
    }

    /// Stages a new desktop position (mode untouched). With <paramref name="setPrimary"/> the device becomes the primary
    /// display — Windows requires the primary at (0,0), so callers must shift every other monitor by the same offset
    /// and stage them in the same batch before ApplyStaged().
    public static int StagePosition(string gdiName, Point pos, bool setPrimary)
    {
        var dm = DisplayNative.DEVMODE.Create();
        dm.dmDeviceName = gdiName;
        dm.dmFields = DisplayNative.DM_POSITION;
        dm.dmPositionX = pos.X;
        dm.dmPositionY = pos.Y;
        var flags = DisplayNative.CDS_UPDATEREGISTRY | DisplayNative.CDS_NORESET;
        if (setPrimary) flags |= DisplayNative.CDS_SET_PRIMARY;
        return DisplayNative.ChangeDisplaySettingsEx(gdiName, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
    }

    /// Stages removal of a device from the desktop (0x0 at 0,0).
    public static int StageDetach(string gdiName)
    {
        var dm = DisplayNative.DEVMODE.Create();
        dm.dmDeviceName = gdiName;
        dm.dmFields = DisplayNative.DM_POSITION | DisplayNative.DM_PELSWIDTH | DisplayNative.DM_PELSHEIGHT;
        return DisplayNative.ChangeDisplaySettingsEx(gdiName, ref dm, IntPtr.Zero,
            DisplayNative.CDS_UPDATEREGISTRY | DisplayNative.CDS_NORESET, IntPtr.Zero);
    }

    public static int ApplyStaged() =>
        DisplayNative.ChangeDisplaySettingsExApply(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);

    /// DisplayConfig source (adapter LUID + source id) of an ACTIVE path whose GDI name is <paramref name="gdiName"/>.
    public static bool TryFindActiveSource(string gdiName, out DisplayNative.LUID adapterId, out uint sourceId)
    {
        adapterId = default; sourceId = 0;
        if (DisplayNative.GetDisplayConfigBufferSizes(DisplayNative.QDC_ONLY_ACTIVE_PATHS, out var np, out var nm) != 0) return false;
        var paths = new DisplayNative.DISPLAYCONFIG_PATH_INFO[np];
        var modes = new DisplayNative.DISPLAYCONFIG_MODE_INFO[nm];
        if (DisplayNative.QueryDisplayConfig(DisplayNative.QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return false;
        for (int i = 0; i < np; i++)
        {
            var s = paths[i].sourceInfo;
            var src = new DisplayNative.DISPLAYCONFIG_SOURCE_DEVICE_NAME
            {
                header = new() { type = DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_SOURCE_DEVICE_NAME>(), adapterId = s.adapterId, id = s.id },
                viewGdiDeviceName = "",
            };
            if (DisplayNative.DisplayConfigGetDeviceInfo(ref src) != 0) continue;
            if (!string.Equals(src.viewGdiDeviceName, gdiName, StringComparison.OrdinalIgnoreCase)) continue;
            adapterId = s.adapterId; sourceId = s.id;
            return true;
        }
        return false;
    }

    /// Read-only: the scale range/current value of an active source (GET_DPI_SCALE), or null.
    public static DisplayScale.Range? GetDpiScale(DisplayNative.LUID adapterId, uint sourceId)
    {
        var g = new DisplayNative.DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
        {
            header = new()
            {
                type = unchecked((uint)DisplayNative.DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE),
                size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_SOURCE_DPI_SCALE_GET>(), adapterId = adapterId, id = sourceId,
            },
        };
        if (DisplayNative.DisplayConfigGetDeviceInfo(ref g) != 0) return null;
        return DisplayScale.FromRelative(g.minScaleRel, g.curScaleRel, g.maxScaleRel);
    }

    /// SET_DPI_SCALE with a value relative to the recommended scale. Returns the Win32 error (0 = ok).
    public static int SetDpiScaleRelative(DisplayNative.LUID adapterId, uint sourceId, int scaleRel)
    {
        var s = new DisplayNative.DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
        {
            header = new()
            {
                type = unchecked((uint)DisplayNative.DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE),
                size = (uint)Marshal.SizeOf<DisplayNative.DISPLAYCONFIG_SOURCE_DPI_SCALE_SET>(), adapterId = adapterId, id = sourceId,
            },
            scaleRel = scaleRel,
        };
        return DisplayNative.DisplayConfigSetDeviceInfo(ref s);
    }

    /// Effective DPI of the monitor showing the centre of <paramref name="bounds"/> as a percent (96 dpi = 100), or 0.
    /// Exact for this per-monitor-v2 aware process.
    public static int EffectiveScalePercent(Rectangle bounds)
    {
        try
        {
            var h = DisplayNative.MonitorFromPoint(new DisplayNative.POINT { X = bounds.X + bounds.Width / 2, Y = bounds.Y + bounds.Height / 2 },
                DisplayNative.MONITOR_DEFAULTTONULL);
            if (h == IntPtr.Zero || DisplayNative.GetDpiForMonitor(h, 0, out var dx, out _) != 0) return 0;
            return (int)Math.Round(dx * 100.0 / 96.0);
        }
        catch { return 0; }
    }

    public static int ExtendTopology() =>
        DisplayNative.SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, DisplayNative.SDC_TOPOLOGY_EXTEND | DisplayNative.SDC_APPLY);
}
