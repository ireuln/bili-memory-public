using System;
using System.Drawing;
using System.IO;
using System.Media;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

public enum NoticeKind { Info, Warn, Error, Ask }

/// <summary>
/// Dialogs for the GUI wrappers.
///
/// Windows plays a system chime for every MessageBox icon and offers no
/// per-application volume, so the only way to make a warning quieter is to
/// drop the icon (the icon is what triggers the chime) and play our own short
/// wav instead. config.json -> "Sound":
///   soft   (default) our wav, no system chime
///   system          stock MessageBox exactly as before
///   off             no sound at all
///</summary>
public static class UiNotice
{
    // Deliberately NOT cached: the settings window rewrites config.json and the
    // very next dialog in the same process has to honour the new value.
    // (A cached field made "switch to Windows sounds" look like a no-op.)
    public static string Mode
    {
        get
        {
            string mode = "soft";
            try
            {
                string cfg = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
                if (File.Exists(cfg))
                {
                    string text = File.ReadAllText(cfg, Encoding.UTF8);
                    Match m = Regex.Match(text, "\"Sound\"\\s*:\\s*\"(soft|system|off)\"", RegexOptions.IgnoreCase);
                    if (m.Success) mode = m.Groups[1].Value.ToLowerInvariant();
                }
            }
            catch { }
            return mode;
        }
    }

    // Preview what the dropdown currently says, not what was saved earlier.
    public static void Preview(string mode)
    {
        if (mode == "system") { System.Media.SystemSounds.Asterisk.Play(); return; }
        if (mode == "off") return;
        PlaySoft();
    }

    public static Icon IconFor(NoticeKind kind)
    {
        switch (kind)
        {
            case NoticeKind.Warn: return SystemIcons.Warning;
            case NoticeKind.Error: return SystemIcons.Error;
            case NoticeKind.Ask: return SystemIcons.Question;
            default: return SystemIcons.Information;
        }
    }

    static MessageBoxIcon MsgIconFor(NoticeKind kind)
    {
        switch (kind)
        {
            case NoticeKind.Warn: return MessageBoxIcon.Warning;
            case NoticeKind.Error: return MessageBoxIcon.Error;
            case NoticeKind.Ask: return MessageBoxIcon.Question;
            default: return MessageBoxIcon.Information;
        }
    }

    static string Prefix(NoticeKind kind)
    {
        switch (kind)
        {
            case NoticeKind.Warn: return "注意：";
            case NoticeKind.Error: return "错误：";
            case NoticeKind.Ask: return "确认：";
            default: return "";
        }
    }

    // SoundPlayer.Play() is asynchronous: disposing the player right after the
    // call tears it down before a single sample reaches the device (that is why
    // the first build was silent). Keep one instance alive for the process.
    static SoundPlayer player;

    public static void PlaySoft()
    {
        try
        {
            if (player == null)
            {
                string wav = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, Path.Combine("assets", "chime-soft.wav"));
                if (!File.Exists(wav)) return;
                player = new SoundPlayer(wav);
                player.Load();
            }
            player.Play();
        }
        catch { }
    }

    public static void Show(string title, string text, NoticeKind kind)
    {
        Show(null, title, text, kind);
    }

    public static void Show(IWin32Window owner, string title, string text, NoticeKind kind)
    {
        if (Mode == "system")
        {
            MessageBox.Show(owner, text, title, MessageBoxButtons.OK, MsgIconFor(kind));
            return;
        }
        if (Mode == "soft") PlaySoft();
        using (NoticeDialog d = new NoticeDialog(Prefix(kind) + title, text, kind, false, true))
        {
            if (owner == null) d.ShowDialog(); else d.ShowDialog(owner);
        }
    }

    public static bool Ask(IWin32Window owner, string title, string text)
    {
        if (Mode == "system")
        {
            return MessageBox.Show(owner, text, title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
        }
        if (Mode == "soft") PlaySoft();
        using (NoticeDialog d = new NoticeDialog(Prefix(NoticeKind.Ask) + title, text, NoticeKind.Ask, true, false))
        {
            return (owner == null ? d.ShowDialog() : d.ShowDialog(owner)) == DialogResult.OK;
        }
    }
}
