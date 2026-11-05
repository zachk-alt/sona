using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

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

/// What each tray menu item does. The App wires these to its dispatcher; the self-test passes no-ops.
internal sealed record TrayMenuActions(Action Settings, Action CopyLast, Action ReviewSpelling, Action ReviewLast, Action Cancel, Action About, Action Quit);

/// The tray menu, built in one place so the self-test checks the menu users see. Like the Mac menu it follows
/// the system theme, and a left click opens it too.
internal static class TrayMenu
{
    internal const string AboutTitle = "About Sona";

    internal static Forms.ContextMenuStrip Build(TrayMenuActions actions)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => actions.Settings());
        menu.Items.Add("Copy last dictation", null, (_, _) => actions.CopyLast());
        menu.Items.Add("Review dictionary suggestion…", null, (_, _) => actions.ReviewSpelling());
        menu.Items.Add("Review last dictation…", null, (_, _) => actions.ReviewLast());
        menu.Items.Add("Cancel recording or processing", null, (_, _) => actions.Cancel());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(AboutTitle, null, (_, _) => actions.About());
        menu.Items.Add("Quit Sona", null, (_, _) => actions.Quit());
        return menu;
    }

    /// The taskbar's theme (SystemUsesLightTheme), which the shell's own tray menus follow. Light when unreadable.
    internal static bool TaskbarIsLight()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is not int value || value != 0;
        }
        catch { return true; }
    }

    /// Dark colors on a dark taskbar; otherwise, and in High Contrast, the stock system-color menu.
    internal static void ApplyTheme(Forms.ContextMenuStrip menu, bool light)
    {
        if (light || SystemParameters.HighContrast)
        {
            menu.RenderMode = Forms.ToolStripRenderMode.ManagerRenderMode;
            menu.ResetForeColor();
        }
        else
        {
            menu.Renderer = new Forms.ToolStripProfessionalRenderer(new DarkColors());
            menu.ForeColor = System.Drawing.Color.White;
        }
    }

    /// Applies the taskbar theme now and again whenever a Windows setting changes, until disposed.
    internal static IDisposable FollowTheme(Forms.ContextMenuStrip menu)
    {
        // SystemEvents raises this on the thread that subscribed, here the UI thread.
        UserPreferenceChangedEventHandler changed = (_, _) => { if (!menu.IsDisposed) ApplyTheme(menu, TaskbarIsLight()); };
        ApplyTheme(menu, TaskbarIsLight());
        SystemEvents.UserPreferenceChanged += changed;
        return new Disposer(() => SystemEvents.UserPreferenceChanged -= changed);
    }

    // NotifyIcon opens its menu only on a right click. Its private ShowContextMenu sets the foreground first, which
    // lets the menu close normally when the user clicks elsewhere, so a left click goes through it as well.
    internal static readonly MethodInfo? ShowContextMenu =
        typeof(Forms.NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic, Type.EmptyTypes);

    /// A left click opens the same menu as a right click, as a click on the Mac menu bar icon does.
    /// MouseClick skips the clicks of a double click, so a double click still opens Settings.
    internal static void OpenOnLeftClick(Forms.NotifyIcon tray) => tray.MouseClick += (_, e) =>
    {
        if (e.Button != Forms.MouseButtons.Left || tray.ContextMenuStrip is not { } menu) return;
        try
        {
            if (ShowContextMenu != null) { ShowContextMenu.Invoke(tray, null); return; }
        }
        catch (TargetInvocationException) { }
        menu.Show(Forms.Cursor.Position);
    };

    internal sealed class DarkColors : Forms.ProfessionalColorTable
    {
        private static readonly System.Drawing.Color Fill = System.Drawing.Color.FromArgb(43, 43, 43),
            Hover = System.Drawing.Color.FromArgb(61, 61, 61), Line = System.Drawing.Color.FromArgb(80, 80, 80);
        public DarkColors() { UseSystemColors = false; }
        public override System.Drawing.Color ToolStripDropDownBackground => Fill;
        public override System.Drawing.Color ImageMarginGradientBegin => Fill;
        public override System.Drawing.Color ImageMarginGradientMiddle => Fill;
        public override System.Drawing.Color ImageMarginGradientEnd => Fill;
        public override System.Drawing.Color MenuBorder => Line;
        public override System.Drawing.Color MenuItemBorder => Hover;
        public override System.Drawing.Color MenuItemSelected => Hover;
        public override System.Drawing.Color MenuItemSelectedGradientBegin => Hover;
        public override System.Drawing.Color MenuItemSelectedGradientEnd => Hover;
        public override System.Drawing.Color MenuItemPressedGradientBegin => Hover;
        public override System.Drawing.Color MenuItemPressedGradientMiddle => Hover;
        public override System.Drawing.Color MenuItemPressedGradientEnd => Hover;
        public override System.Drawing.Color SeparatorDark => Line;
        public override System.Drawing.Color SeparatorLight => Fill;
    }
}

/// A second launch asks the running Sona to open Settings, as reopening the Mac app pops its menu. Windows 11
/// can hide the tray icon in the overflow, so launching Sona again from Start is the way back in.
internal static class ReopenSignal
{
    internal const string Name = "Local\\Sona.Dictation.Open";

    /// Runs open on this (UI) thread each time a later launch signals, until disposed. A registered wait holds
    /// no thread, and no dictation waits on it.
    internal static IDisposable Listen(string name, Action open)
    {
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        var dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
        var registration = ThreadPool.RegisterWaitForSingleObject(signal, (_, _) => dispatcher.BeginInvoke(open), null, Timeout.Infinite, false);
        return new Disposer(() => { registration.Unregister(null); signal.Dispose(); });
    }

    /// Signals the running Sona. False when none is listening yet.
    internal static bool Send(string name)
    {
        if (!EventWaitHandle.TryOpenExisting(name, out var signal)) return false;
        using (signal)
        {
            // This launch holds the user's foreground right; pass it on so Settings can come to the front.
            AllowSetForegroundWindow(-1);
            return signal.Set();
        }
    }

    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int processId);
}

internal sealed class Disposer(Action dispose) : IDisposable
{
    private Action? pending = dispose;
    public void Dispose() => Interlocked.Exchange(ref pending, null)?.Invoke();
}
