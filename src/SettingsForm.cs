using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class SettingsForm : Form
{
    string root;
    Dictionary<string, object> cfg;
    ComboBox cbStartup;
    ComboBox cbHistory;
    ComboBox cbFavorites;
    ComboBox cbFollows;
    ComboBox cbBackup;
    ComboBox cbBackupCold;
    ComboBox cbLang;
    ComboBox cbLog;
    ComboBox cbSound;
    Label status;
    TextBox output;

    public SettingsForm()
    {
        root = AppDomain.CurrentDomain.BaseDirectory;
        Text = "B印象 - 功能与设置";
        // 10 pt instead of 9: at 100% scaling the old size was noticeably
        // smaller than every other window on the desktop.
        Font = new System.Drawing.Font("Microsoft YaHei UI", 10F);
        MinimumSize = new System.Drawing.Size(720, 520);
        // A 1366x768 laptop at 125% has only 1092x614 of usable space, and a
        // 1024x600 netbook even less, so never open taller/wider than the screen.
        System.Drawing.Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int wantW = Math.Min(900, wa.Width - 40);
        int wantH = Math.Min(680, wa.Height - 40);
        Width = Math.Max(wantW, MinimumSize.Width);
        Height = Math.Max(wantH, MinimumSize.Height);
        StartPosition = FormStartPosition.CenterScreen;

        TabControl tabs = new TabControl();
        tabs.Dock = DockStyle.Fill;
        tabs.TabPages.Add(CommonPage());
        tabs.TabPages.Add(SettingsPage());
        tabs.TabPages.Add(DiagPage());
        Controls.Add(tabs);

        LoadConfig();
    }

    ProcessStartInfo Psi(string script, string extra)
    {
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = ps;
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(root, script) + "\"";
        if (!string.IsNullOrEmpty(extra)) psi.Arguments += " " + extra;
        psi.WorkingDirectory = root;
        return psi;
    }

    void SetStatus(string text)
    {
        if (status != null) status.Text = text;
    }

    void Error(string text)
    {
        UiNotice.Show("B印象", text, NoticeKind.Warn);
    }

    void RunTask(string mode)
    {
        if (!File.Exists(Path.Combine(root, "run-task.ps1"))) { Error("缺少 run-task.ps1，请重新解压或恢复隔离文件。"); return; }
        try
        {
            ProcessStartInfo psi = Psi("run-task.ps1", "-Mode " + mode);
            psi.UseShellExecute = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
            SetStatus("已启动：" + mode + "（进度看托盘）");
        }
        catch (Exception ex) { Error("无法启动任务：" + ex.Message); }
    }

    // Report/share/backup used to be launched with UseShellExecute and the
    // output thrown away: when the script failed (missing template, bad data)
    // the button simply did nothing. Capture the output and report it.
    void RunHidden(string script, string extra)
    {
        if (!File.Exists(Path.Combine(root, script))) { Error("缺少 " + script + "，请重新解压或恢复隔离文件。"); return; }
        try
        {
            ProcessStartInfo psi = Psi(script, extra);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            // The child sets its console encoding to UTF-8; reading with the
            // default ANSI decoder turned Chinese error text into mojibake.
            psi.StandardOutputEncoding = System.Text.Encoding.UTF8;
            psi.StandardErrorEncoding = System.Text.Encoding.UTF8;
            Process p = new Process();
            p.StartInfo = psi;
            p.EnableRaisingEvents = true;
            SetStatus("正在执行 " + script + " …（生成卡片可能要十几秒）");
            p.Exited += delegate
            {
                string so = ""; string se = "";
                try { so = p.StandardOutput.ReadToEnd(); se = p.StandardError.ReadToEnd(); } catch { }
                int code = -1;
                try { code = p.ExitCode; } catch { }
                string text = (so + Environment.NewLine + se).Trim();
                p.Dispose();
                try
                {
                    BeginInvoke((Action)delegate
                    {
                        string tail = Tail(text, 8);
                        if (code == 0)
                        {
                            SetStatus(script + " 完成");
                            UiNotice.Show("B印象", script + " 已完成。" + (tail.Length > 0 ? Environment.NewLine + Environment.NewLine + tail : ""), NoticeKind.Info);
                        }
                        else
                        {
                            SetStatus(script + " 失败，退出码 " + code);
                            UiNotice.Show("B印象", script + " 失败（退出码 " + code + "）" + Environment.NewLine + Environment.NewLine + (tail.Length > 0 ? tail : "没有输出，检查数据目录与日志。"), NoticeKind.Error);
                        }
                    });
                }
                catch { }
            };
            p.Start();
        }
        catch (Exception ex) { Error("无法启动 " + script + "：" + ex.Message); }
    }

    string Tail(string text, int lines)
    {
        if (string.IsNullOrEmpty(text)) return "";
        string[] all = text.Replace("\r\n", "\n").Split('\n');
        int start = Math.Max(0, all.Length - lines);
        string[] part = new string[all.Length - start];
        Array.Copy(all, start, part, 0, part.Length);
        return string.Join(Environment.NewLine, part);
    }

    void RunCapture(string script, string extra)
    {
        if (!File.Exists(Path.Combine(root, script))) { Error("缺少 " + script + "，请重新解压或恢复隔离文件。"); return; }
        try
        {
            ProcessStartInfo psi = Psi(script, extra);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = System.Text.Encoding.UTF8;
            psi.StandardErrorEncoding = System.Text.Encoding.UTF8;
            using (Process p = Process.Start(psi))
            {
                string so = p.StandardOutput.ReadToEnd();
                string se = p.StandardError.ReadToEnd();
                p.WaitForExit();
                output.Text = (so + Environment.NewLine + se).Trim();
                SetStatus(script + " 退出码 " + p.ExitCode);
            }
        }
        catch (Exception ex) { Error("运行 " + script + " 失败：" + ex.Message); }
    }

    Button Btn(string text, EventHandler click)
    {
        Button b = new Button();
        b.Text = text;
        b.AutoSize = true;
        b.Padding = new Padding(12, 6, 12, 6);
        b.Margin = new Padding(5);
        b.Click += click;
        return b;
    }

    TabPage CommonPage()
    {
        TabPage page = new TabPage("常用功能");
        page.AutoScroll = true;
        FlowLayoutPanel top = new FlowLayoutPanel();
        top.Dock = DockStyle.Top;
        top.Height = 150;
        top.Padding = new Padding(8);
        top.WrapContents = true;

        top.Controls.Add(Btn("采集观看记录", delegate { RunTask("history"); }));
        top.Controls.Add(Btn("刷新收藏夹", delegate {
            if (UiNotice.Ask(this, "B印象", "收藏全量可能约 20 分钟，继续？"))
                RunTask("fav");
        }));
        top.Controls.Add(Btn("刷新关注分组", delegate { RunTask("follow"); }));
        top.Controls.Add(Btn("生成统计报告", delegate { RunHidden("report.ps1", ""); }));
        top.Controls.Add(Btn("生成分享卡片", delegate { RunHidden("share.ps1", ""); }));
        top.Controls.Add(Btn("完整备份", delegate { RunTask("backup"); }));
        top.Controls.Add(Btn("纯文本冷备份", delegate { RunTask("cold"); }));
        top.Controls.Add(Btn("打开归档目录", delegate {
            if (cfg != null && cfg.ContainsKey("DataRoot")) Process.Start("explorer.exe", (string)cfg["DataRoot"]);
        }));

        status = new Label();
        status.Dock = DockStyle.Bottom;
        status.Height = 34;
        status.Text = "就绪";
        status.Padding = new Padding(8, 6, 8, 0);

        page.Controls.Add(status);
        page.Controls.Add(top);
        return page;
    }

    TabPage SettingsPage()
    {
        TabPage page = new TabPage("计划与设置");
        page.AutoScroll = true;

        TableLayoutPanel t = new TableLayoutPanel();
        t.Dock = DockStyle.Top;
        t.ColumnCount = 2;
        t.RowCount = 10;
        t.AutoSize = true;
        t.Padding = new Padding(12);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 280));

        cbStartup = Combo(new string[] { "不自动启动", "开机启动托盘" });
        cbHistory = Combo(new string[] { "计划任务", "手动" });
        cbFavorites = Combo(new string[] { "计划任务", "手动" });
        cbFollows = Combo(new string[] { "计划任务", "手动" });
        cbBackup = Combo(new string[] { "计划任务", "手动" });
        cbBackupCold = Combo(new string[] { "计划任务", "手动" });
        cbLang = Combo(new string[] { "zh-CN", "en-US" });
        cbLog = Combo(new string[] { "普通", "详细（排障）" });
        cbSound = Combo(new string[] { "柔和（默认）", "Windows 系统音", "关闭" });

        AddRow(t, 0, "开机托盘", cbStartup);
        AddRow(t, 1, "观看记录", cbHistory);
        AddRow(t, 2, "收藏巡检", cbFavorites);
        AddRow(t, 3, "关注分组", cbFollows);
        AddRow(t, 4, "完整备份", cbBackup);
        AddRow(t, 5, "冷备份", cbBackupCold);
        AddRow(t, 6, "界面语言", cbLang);
        AddRow(t, 7, "日志级别", cbLog);
        AddRow(t, 8, "提示音", cbSound);

        FlowLayoutPanel actions = new FlowLayoutPanel();
        actions.Dock = DockStyle.Top;
        actions.Height = 64;
        actions.Padding = new Padding(12, 4, 12, 4);
        actions.Controls.Add(Btn("保存设置", delegate { SaveSettings(); }));
        actions.Controls.Add(Btn("试听提示音", delegate {
            string m = cbSound.SelectedIndex == 1 ? "system" : (cbSound.SelectedIndex == 2 ? "off" : "soft");
            if (m == "off") { SetStatus("提示音已关闭，试听不会出声。"); return; }
            SetStatus(m == "system" ? "试听：Windows 系统音" : "试听：柔和提示音（低频）");
            UiNotice.Preview(m);
        }));
        actions.Controls.Add(Btn("应用计划任务", delegate { RunCapture("register-task.ps1", ""); }));
        actions.Controls.Add(Btn("打开 config.json", delegate {
            string f = Path.Combine(root, "config.json");
            if (File.Exists(f)) Process.Start("notepad.exe", f); else Error("config.json 不存在，请先安装。");
        }));

        Label note = new Label();
        note.Dock = DockStyle.Bottom;
        note.Height = 58;
        note.Padding = new Padding(12, 6, 12, 0);
        note.ForeColor = System.Drawing.Color.DimGray;
        note.Text = "改完先“保存设置”，再“应用计划任务”。数据目录与备份目录请直接编辑 config.json。";

        page.Controls.Add(note);
        page.Controls.Add(actions);
        page.Controls.Add(t);
        return page;
    }

    TabPage DiagPage()
    {
        TabPage page = new TabPage("诊断与帮助");
        page.AutoScroll = true;
        FlowLayoutPanel top = new FlowLayoutPanel();
        top.Dock = DockStyle.Top;
        top.Height = 76;
        top.Padding = new Padding(8);
        top.WrapContents = true;

        top.Controls.Add(Btn("自检（不读数据）", delegate { RunCapture("selftest.ps1", "-SkipData"); }));
        top.Controls.Add(Btn("文件完整性校验", delegate { RunCapture("verify-files.ps1", ""); }));
        top.Controls.Add(Btn("打开日志文件夹", delegate {
            if (cfg != null && cfg.ContainsKey("DataRoot")) {
                string dir = Path.Combine((string)cfg["DataRoot"], "日志");
                if (Directory.Exists(dir)) Process.Start("explorer.exe", dir);
                else Error("日志目录还不存在。");
            }
        }));
        top.Controls.Add(Btn("打开帮助", delegate {
            string f = Path.Combine(root, "docs", "能力说明.md");
            if (File.Exists(f)) Process.Start("notepad.exe", f); else Error("帮助文档缺失。");
        }));
        top.Controls.Add(Btn("检查更新", delegate { RunCapture("check-update.ps1", ""); }));

        output = new TextBox();
        output.Dock = DockStyle.Fill;
        output.Multiline = true;
        output.ScrollBars = ScrollBars.Both;
        output.ReadOnly = true;
        output.Font = new System.Drawing.Font("Consolas", 9F);
        output.BackColor = System.Drawing.Color.White;

        page.Controls.Add(output);
        page.Controls.Add(top);
        return page;
    }

    ComboBox Combo(string[] items)
    {
        ComboBox c = new ComboBox();
        c.DropDownStyle = ComboBoxStyle.DropDownList;
        c.Width = 260;
        c.Items.AddRange(items);
        c.SelectedIndex = 0;
        return c;
    }

    void AddRow(TableLayoutPanel t, int row, string label, Control control)
    {
        Label l = new Label();
        l.Text = label;
        l.TextAlign = System.Drawing.ContentAlignment.MiddleLeft;
        l.AutoSize = true;
        // taller rows: the label and the combo were touching each other
        l.Margin = new Padding(0, 9, 12, 9);
        control.Margin = new Padding(0, 7, 0, 7);
        t.Controls.Add(l, 0, row);
        t.Controls.Add(control, 1, row);
    }

    void LoadConfig()
    {
        string file = Path.Combine(root, "config.json");
        if (!File.Exists(file)) { SetStatus("尚未安装，请先关闭窗口并双击 B印象.exe 安装。"); return; }
        try
        {
            var ser = new JavaScriptSerializer();
            cfg = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(file, Encoding.UTF8));
            Dictionary<string, object> auto = null;
            if (cfg.ContainsKey("Automation")) auto = cfg["Automation"] as Dictionary<string, object>;
            if (auto != null)
            {
                cbStartup.SelectedIndex = Str(auto, "Startup") == "tray" ? 1 : 0;
                cbHistory.SelectedIndex = Str(auto, "History") == "manual" ? 1 : 0;
                cbFavorites.SelectedIndex = Str(auto, "Favorites") == "manual" ? 1 : 0;
                cbFollows.SelectedIndex = Str(auto, "Follows") == "manual" ? 1 : 0;
                cbBackup.SelectedIndex = Str(auto, "Backup") == "manual" ? 1 : 0;
                cbBackupCold.SelectedIndex = Str(auto, "BackupCold") == "manual" ? 1 : 0;
            }
            string lang = Str(cfg, "UiLanguage");
            cbLang.SelectedIndex = lang == "en-US" ? 1 : 0;
            cbLog.SelectedIndex = Str(cfg, "LogLevel") == "debug" ? 1 : 0;
            string snd = Str(cfg, "Sound");
            cbSound.SelectedIndex = snd == "system" ? 1 : (snd == "off" ? 2 : 0);
            SetStatus("已加载配置：" + (string)cfg["DataRoot"]);
        }
        catch (Exception ex) { Error("读取配置失败：" + ex.Message); }
    }

    string Str(Dictionary<string, object> d, string key)
    {
        if (d != null && d.ContainsKey(key) && d[key] != null) return d[key].ToString();
        return "";
    }

    void SaveSettings()
    {
        if (cfg == null) { Error("没有可保存的配置。"); return; }
        try
        {
            var auto = new Dictionary<string, object>();
            auto["Startup"] = cbStartup.SelectedIndex == 1 ? "tray" : "none";
            auto["History"] = cbHistory.SelectedIndex == 1 ? "manual" : "scheduled";
            auto["Favorites"] = cbFavorites.SelectedIndex == 1 ? "manual" : "scheduled";
            auto["Follows"] = cbFollows.SelectedIndex == 1 ? "manual" : "scheduled";
            auto["Backup"] = cbBackup.SelectedIndex == 1 ? "manual" : "scheduled";
            auto["BackupCold"] = cbBackupCold.SelectedIndex == 1 ? "manual" : "scheduled";
            cfg["Automation"] = auto;
            cfg["UiLanguage"] = cbLang.SelectedIndex == 1 ? "en-US" : "zh-CN";
            cfg["LogLevel"] = cbLog.SelectedIndex == 1 ? "debug" : "normal";
            cfg["Sound"] = cbSound.SelectedIndex == 1 ? "system" : (cbSound.SelectedIndex == 2 ? "off" : "soft");

            var ser = new JavaScriptSerializer();
            File.WriteAllText(Path.Combine(root, "config.json"), ser.Serialize(cfg), new UTF8Encoding(false));
            SetStatus("设置已保存。点“应用计划任务”生效。");
            UiNotice.Show("B印象", "设置已保存。\r\n\r\n提示音立即生效；计划任务需点“应用计划任务”；界面语言与日志级别重启托盘后生效。", NoticeKind.Info);
        }
        catch (Exception ex) { Error("保存失败：" + ex.Message); }
    }
}
