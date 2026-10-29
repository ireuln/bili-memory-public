using System;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;

// One palette for every window in this app.
//
// Follows the Windows light/dark setting (Personalize\AppsUseLightTheme) and
// repaints in place when the user flips it, because a window that keeps its
// old colours until restart looks broken next to the rest of the desktop.
//
// Controls opt in by putting a role name in Tag; ApplyTo() walks the tree and
// colours each one. Layout code therefore never mentions a colour.
public static class Theme
{
    public static bool Dark = Detect();

    public static Color Ink;
    public static Color Muted;
    public static Color Faint;
    public static Color Line;
    public static Color WindowBg;
    public static Color CardBg;
    public static Color Accent;
    public static Color AccentHover;
    public static Color Green;
    public static Color Amber;
    public static Color Slate;
    public static Color Red;
    public static Color LogBg;
    public static Color NavSelBg;

    static Theme()
    {
        Apply(Dark);
    }

    public static bool Detect()
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            {
                if (k != null)
                {
                    object v = k.GetValue("AppsUseLightTheme");
                    if (v is int) return (int)v == 0;
                }
            }
        }
        catch { }
        return false;
    }

    public static void Apply(bool dark)
    {
        Dark = dark;
        if (dark)
        {
            Ink = Color.FromArgb(230, 237, 243);
            Muted = Color.FromArgb(139, 148, 158);
            Faint = Color.FromArgb(110, 118, 129);
            Line = Color.FromArgb(48, 54, 61);
            WindowBg = Color.FromArgb(13, 17, 23);
            CardBg = Color.FromArgb(22, 27, 34);
            Accent = Color.FromArgb(68, 147, 248);
            AccentHover = Color.FromArgb(88, 166, 255);
            Green = Color.FromArgb(63, 185, 80);
            Amber = Color.FromArgb(210, 153, 34);
            Slate = Color.FromArgb(110, 118, 129);
            Red = Color.FromArgb(248, 81, 73);
            LogBg = Color.FromArgb(13, 17, 23);
            NavSelBg = Color.FromArgb(33, 38, 45);
        }
        else
        {
            Ink = Color.FromArgb(31, 35, 40);
            Muted = Color.FromArgb(110, 118, 129);
            Faint = Color.FromArgb(140, 146, 158);
            Line = Color.FromArgb(225, 228, 234);
            WindowBg = Color.White;
            CardBg = Color.FromArgb(252, 252, 253);
            Accent = Color.FromArgb(47, 111, 235);
            AccentHover = Color.FromArgb(30, 90, 210);
            Green = Color.FromArgb(21, 115, 71);
            Amber = Color.FromArgb(154, 103, 0);
            Slate = Color.FromArgb(140, 146, 158);
            Red = Color.FromArgb(179, 38, 30);
            LogBg = Color.FromArgb(250, 251, 252);
            NavSelBg = Color.FromArgb(240, 243, 248);
        }
    }

    // Re-read the OS setting and repaint everything under root.
    public static void Refresh(Control root)
    {
        Apply(Detect());
        if (root != null) ApplyTo(root);
        Form f = root as Form;
        if (f != null) ApplyTitleBar(f);
    }

    public static void ApplyTo(Control parent)
    {
        foreach (Control c in parent.Controls)
        {
            string role = c.Tag as string;
            Style(c, role);
            if (c.HasChildren) ApplyTo(c);
        }
    }

    public static void Style(Control c, string role)
    {
        switch (role)
        {
            case "win":
                c.BackColor = WindowBg; c.ForeColor = Ink; break;
            case "panel":
                c.BackColor = CardBg; c.ForeColor = Ink; break;
            case "card":
                c.BackColor = CardBg; c.ForeColor = Ink; break;
            case "title":
                c.ForeColor = Ink; break;
            case "sub":
                c.ForeColor = Muted; break;
            case "section":
                c.ForeColor = Ink; break;
            case "note":
            case "hint":
            case "muted":
                c.ForeColor = Muted; break;
            case "rownames":
            case "rowname":
                c.ForeColor = Ink; break;
            case "rowdesc":
                c.ForeColor = Muted; break;
            case "ink":
                c.ForeColor = Ink; c.BackColor = WindowBg; break;
            case "rule":
                c.BackColor = Line; break;
            case "green":
                c.BackColor = Green; break;
            case "amber":
                c.BackColor = Amber; break;
            case "slate":
                c.BackColor = Slate; break;
            case "nav":
                c.BackColor = WindowBg; c.ForeColor = Muted; break;
            case "navsel":
                c.BackColor = NavSelBg; c.ForeColor = Ink; break;
            case "primary":
                c.BackColor = Accent; c.ForeColor = Color.White;
                break;
            case "secondary":
                Button b = c as Button;
                if (b != null)
                {
                    b.BackColor = c.Parent != null && c.Parent.Tag as string == "panel" ? CardBg : WindowBg;
                    b.ForeColor = Ink;
                    b.FlatAppearance.BorderColor = Line;
                }
                break;
            case "log":
                c.BackColor = LogBg; c.ForeColor = Ink;
                break;
            case "input":
                c.BackColor = Dark ? Color.FromArgb(13, 17, 23) : Color.White;
                c.ForeColor = Ink;
                ComboBox cb = c as ComboBox;
                if (cb != null) cb.FlatStyle = Dark ? FlatStyle.Flat : FlatStyle.Standard;
                break;
        }
    }

    public static void ApplyTitleBar(Form f)
    {
        try
        {
            int dark = Dark ? 1 : 0;
            Native.DwmSetWindowAttribute(f.Handle, 20, ref dark, sizeof(int));
        }
        catch { }
    }
}

static class Native
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
