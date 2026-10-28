using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

class BiliMemoryUninstaller
{
    static void Log(string message)
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "bili-memory-logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "uninstaller.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch { }
    }

    [STAThread]
    static int Main()
    {
        try
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, "uninstall.ps1");
            Log("start dir=" + dir);

            if (!File.Exists(script))
            {
                Log("missing " + script);
                UiNotice.Show("B\u5370\u8c61 - \u5378\u8f7d", "uninstall.ps1 not found next to this exe.", NoticeKind.Error);
                return 1;
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = true;
            Process.Start(psi);
            Log("launched " + script);
            return 0;
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex.ToString());
            UiNotice.Show("B\u5370\u8c61 - \u5378\u8f7d", ex.Message, NoticeKind.Error);
            return 1;
        }
    }
}
