using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class BiliMemoryLauncher
{
    static string Root;
    static string LogFile;

    static void Log(string message)
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "bili-memory-logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "launcher.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch { }
    }

    [STAThread]
    static void Main()
    {
        Root = AppDomain.CurrentDomain.BaseDirectory;
        LogFile = Path.Combine(Path.GetTempPath(), "bili-memory-logs", "launcher.log");
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        bool settings = false;
        foreach (string a in Environment.GetCommandLineArgs())
        {
            if (a == "-settings" || a == "--settings") settings = true;
        }

        Log("start dir=" + Root + " settings=" + settings);
        List<string> bad = VerifyFiles();
        if (bad.Count > 0)
        {
            bool sumsStale = File.Exists(Path.Combine(Root, "SHA256SUMS.txt"));
            string msg = "检测到文件缺失或被修改。常见原因有三个：\r\n\r\n"
                + "  1. 杀毒软件把脚本隔离了（火绒/Defender 都可能）\r\n"
                + "  2. 手动替换了个别脚本，但没有一起换掉 SHA256SUMS.txt\r\n"
                + "  3. 用编辑器改过脚本（保存后哈希就变了）\r\n\r\n"
                + "不一致的文件：\r\n";
            for (int i = 0; i < bad.Count && i < 8; i++) msg += "  " + bad[i] + "\r\n";
            if (bad.Count > 8) msg += "  ... 共 " + bad.Count + " 个\r\n";
            if (sumsStale)
            {
                msg += "\r\n最省事的做法：重新解压发布包，只保留你的 config.json 与数据目录。";
            }
            else
            {
                msg += "\r\nSHA256SUMS.txt 不见了：请重新解压完整的发布包。";
            }
            UiNotice.Show("B印象 - 完整性检查", msg, NoticeKind.Warn);
            Log("integrity issues: " + string.Join("; ", bad.ToArray()));
            if (!File.Exists(Path.Combine(Root, "tray.ps1")) || !File.Exists(Path.Combine(Root, "setup.ps1")))
            {
                return;
            }
        }

        if (settings)
        {
            Application.Run(new SettingsForm());
        }
        else if (!File.Exists(Path.Combine(Root, "config.json")))
        {
            Application.Run(new SetupForm());
        }
        else
        {
            StartTray();
        }
    }

    static List<string> VerifyFiles()
    {
        var bad = new List<string>();
        string sums = Path.Combine(Root, "SHA256SUMS.txt");
        if (!File.Exists(sums)) return bad;
        foreach (string raw in File.ReadAllLines(sums, Encoding.UTF8))
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            int sp = line.IndexOf("  ");
            if (sp < 0) continue;
            string expected = line.Substring(0, sp).Trim().ToLowerInvariant();
            string rel = line.Substring(sp + 2).Trim();
            string path = Path.Combine(Root, rel.Replace('/', '\\'));
            if (!File.Exists(path)) { bad.Add("缺失: " + rel); continue; }
            string actual = Hash(path);
            if (actual != expected) bad.Add("已修改: " + rel);
        }
        return bad;
    }

    static string Hash(string path)
    {
        using (var sha = SHA256.Create())
        using (var fs = File.OpenRead(path))
        {
            byte[] hash = sha.ComputeHash(fs);
            var sb = new StringBuilder();
            foreach (byte b in hash) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }

    static void StartTray()
    {
        try
        {
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(Root, "tray.ps1");
            if (!File.Exists(script)) { Log("missing tray.ps1"); return; }
            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
            psi.WorkingDirectory = Root;
            psi.UseShellExecute = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
            Log("launched tray.ps1");
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex);
            UiNotice.Show("B印象", ex.Message, NoticeKind.Error);
        }
    }

    class SetupForm : Form
    {
        TextBox txtData;
        TextBox txtBackup;
        CheckBox chkTray;
        ComboBox cboLang;

        public SetupForm()
        {
            Text = "B印象 - 首次安装";
            Width = 560;
            Height = 300;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new System.Drawing.Font("Microsoft YaHei UI", 9F);

            Label title = new Label();
            title.Text = "B印象 首次安装";
            title.Font = new System.Drawing.Font("Microsoft YaHei UI", 14F, System.Drawing.FontStyle.Bold);
            title.SetBounds(20, 15, 500, 32);
            Controls.Add(title);

            Label tip = new Label();
            tip.Text = "选择数据保存位置。数据只保存在本机，不会上传。";
            tip.SetBounds(22, 50, 500, 22);
            Controls.Add(tip);

            Label l1 = new Label(); l1.Text = "数据目录"; l1.SetBounds(22, 88, 70, 22); Controls.Add(l1);
            txtData = new TextBox(); txtData.SetBounds(95, 85, 370, 24); Controls.Add(txtData);
            Button b1 = new Button(); b1.Text = "浏览..."; b1.SetBounds(472, 84, 60, 26);
            b1.Click += delegate { Browse(txtData); }; Controls.Add(b1);

            Label l2 = new Label(); l2.Text = "备份目录"; l2.SetBounds(22, 124, 70, 22); Controls.Add(l2);
            txtBackup = new TextBox(); txtBackup.SetBounds(95, 121, 370, 24); Controls.Add(txtBackup);
            Button b2 = new Button(); b2.Text = "浏览..."; b2.SetBounds(472, 120, 60, 26);
            b2.Click += delegate { Browse(txtBackup); }; Controls.Add(b2);

            chkTray = new CheckBox(); chkTray.Text = "开机自动启动托盘"; chkTray.SetBounds(95, 158, 220, 24); Controls.Add(chkTray);

            Label l3 = new Label(); l3.Text = "界面语言"; l3.SetBounds(330, 158, 70, 22); Controls.Add(l3);
            cboLang = new ComboBox(); cboLang.DropDownStyle = ComboBoxStyle.DropDownList;
            cboLang.Items.Add("zh-CN"); cboLang.Items.Add("en-US"); cboLang.SelectedIndex = 0;
            cboLang.SetBounds(405, 156, 125, 24); Controls.Add(cboLang);

            Label note = new Label();
            note.Text = "安装后请右键托盘图标扫码登录。需要 Edge 或 Chrome。";
            note.ForeColor = System.Drawing.Color.DimGray;
            note.SetBounds(22, 192, 500, 22);
            Controls.Add(note);

            Button ok = new Button(); ok.Text = "开始安装"; ok.SetBounds(330, 225, 100, 30);
            ok.Click += delegate { Install(); }; Controls.Add(ok);
            Button cancel = new Button(); cancel.Text = "退出"; cancel.SetBounds(440, 225, 80, 30);
            cancel.Click += delegate { Close(); }; Controls.Add(cancel);

            string d = "D:\\bili-archive";
            if (!Directory.Exists("D:\\")) d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "bili-archive");
            txtData.Text = d;
            txtBackup.Text = Path.Combine(Path.GetPathRoot(d), "bili-backup");
        }

        void Browse(TextBox box)
        {
            using (var dlg = new FolderBrowserDialog())
            {
                if (Directory.Exists(box.Text)) dlg.SelectedPath = box.Text;
                if (dlg.ShowDialog(this) == DialogResult.OK) box.Text = dlg.SelectedPath;
            }
        }

        void Install()
        {
            try
            {
                string data = txtData.Text.Trim();
                string backup = txtBackup.Text.Trim();
                if (data.Length == 0 || backup.Length == 0) { UiNotice.Show("B印象", "请填写数据目录和备份目录。", NoticeKind.Warn); return; }
                string fullData = Path.GetFullPath(data).TrimEnd('\\');
                string fullBackup = Path.GetFullPath(backup).TrimEnd('\\');
                if (fullData.Length <= 3 || fullBackup.Length <= 3)
                {
                    UiNotice.Show("B印象", "不能直接使用磁盘根目录，请选一个子目录。", NoticeKind.Warn);
                    return;
                }
                Directory.CreateDirectory(fullData);
                Directory.CreateDirectory(fullBackup);

                string example = Path.Combine(Root, "config.example.json");
                var ser = new JavaScriptSerializer();
                var cfg = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(example, Encoding.UTF8));
                cfg["DataRoot"] = fullData;
                cfg["ColdBackup"] = fullBackup;
                cfg["BackupTargets"] = new object[] {
                    new Dictionary<string, object> { { "Path", fullBackup }, { "Kind", "primary" } }
                };
                if (cfg.ContainsKey("Automation") && cfg["Automation"] is Dictionary<string, object>)
                {
                    ((Dictionary<string, object>)cfg["Automation"])["Startup"] = chkTray.Checked ? "tray" : "none";
                }
                cfg["UiLanguage"] = cboLang.SelectedItem.ToString();
                cfg["LogLevel"] = "normal";

                if (cfg.ContainsKey("Dirs") && cfg["Dirs"] is Dictionary<string, object>)
                {
                    foreach (var kv in (Dictionary<string, object>)cfg["Dirs"])
                    {
                        if (kv.Value is string) Directory.CreateDirectory(Path.Combine(fullData, (string)kv.Value));
                    }
                }

                File.WriteAllText(Path.Combine(Root, "config.json"), ser.Serialize(cfg), new UTF8Encoding(false));
                StartTray();
                UiNotice.Show("B印象", "安装完成。数据目录：\r\n" + fullData + "\r\n\r\n请右键托盘图标扫码登录。", NoticeKind.Info);
                Close();
            }
            catch (Exception ex)
            {
                Log("setup ERROR " + ex);
                UiNotice.Show("B印象", "安装失败：" + ex.Message, NoticeKind.Error);
            }
        }
    }
}
