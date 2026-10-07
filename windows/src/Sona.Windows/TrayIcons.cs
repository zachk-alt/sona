using System.Runtime.InteropServices;
using System.Windows;

namespace Sona.Windows;

internal static class TrayIcons
{
    // Reuse the existing production blue mark without recoloring or redrawing it.
    internal static System.Drawing.Icon Active()
    {
        using var resource = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/MenuIconRecording.png"))!.Stream;
        using var bitmap = new System.Drawing.Bitmap(resource);
        nint handle = bitmap.GetHicon();
        try
        {
            using var icon = System.Drawing.Icon.FromHandle(handle);
            return (System.Drawing.Icon)icon.Clone();
        }
        finally { DestroyIcon(handle); }
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint handle);
}
