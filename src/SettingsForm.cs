using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Main settings window.
//
// Reference points for the layout (kept deliberately close to what people
// already know): Windows 11 Settings for the left navigation + grouped cards,
// Fluent 2 for the 8px spacing grid and the 12/14/20 type ramp, and GitHub
// Primer for the dark palette. Colours come from Theme; every control only
// carries a role in Tag, so light/dark is one recursive pass.
class SettingsForm : Form
{
    const int HeaderH = 78;
    const int NavW = 190;
    const int BarH = 62;

    readonly string root;
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
    CheckBox chkDesktop;

    Label status;
    TextBox output;
    Panel content;
    Panel[] pages;
    Button[] navs;

    public SettingsForm()
    {
        root = AppDomain.CurrentDomain.BaseDirectory;
        Text = "B印象 - 功能与设置";
        Font = new Font("Microsoft YaHei UI", 10F);
        MinimumSize = new Size(820, 580);
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Width = Math.Max(Math.Min(940, wa.Width - 40), MinimumSize.Width);
        Height = Math.Max(Math.Min(760, wa.Height - 40), MinimumSize.Height);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.WindowBg;

        BuildHeader();
        BuildNav();
        BuildPages();
        BuildBar();

        ShowPage(0);
        Theme.ApplyTo(this);
        Theme.ApplyTitleBar(this);
        LoadConfig();
    }

    // ------------------------------------------------------------------ shell
    void BuildHeader()
    {
        Panel head = new Panel();
        head.Bounds = new Rectangle(0, 0, ClientSize.Width, HeaderH);
        head.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        head.Tag = "win";
        head.Paint += delegate(object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Theme.Line)) e.Graphics.DrawLine(p, 0, HeaderH - 1, head.Width, HeaderH - 1);
        };

        Label title = new Label();
        title.Text = "设置";
        title.Font = new Font("Microsoft YaHei UI", 15F, FontStyle.Bold);
        title.AutoSize = true;
        title.Location = new Point(24, 18);
        title.Tag = "title";
        head.Controls.Add(title);

        Label sub = new Label();
        sub.Text = "改完点右下角“保存设置”；计划任务改完还要再点“应用计划任务”。";
        sub.AutoSize = true;
        sub.Location = new Point(26, 50);
        sub.Tag = "sub";
        head.Controls.Add(sub);

        Controls.Add(head);
    }

    void BuildNav()
    {
        Panel nav = new Panel();
        nav.Bounds = new Rectangle(0, HeaderH, NavW, ClientSize.Height - HeaderH - BarH);
        nav.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Bottom;
        nav.Tag = "win";
        nav.Paint += delegate(object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Theme.Line)) e.Graphics.DrawLine(p, NavW - 1, 0, NavW - 1, nav.Height);
        };

        string[] names = { "常用功能", "计划与设置", "诊断与帮助", "AI 能做什么" };
        navs = new Button[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            int index = i;
            Button b = new Button();
            b.Text = names[i];
            b.TextAlign = ContentAlignment.MiddleLeft;
            b.Padding = new Padding(18, 0, 0, 0);
            b.Font = new Font("Microsoft YaHei UI", 10F);
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.Size = new Size(NavW - 24, 42);
            b.Location = new Point(12, 12 + i * 46);
            b.Cursor = Cursors.Hand;
            b.Click += delegate { ShowPage(index); };
            b.Tag = "nav";
            nav.Controls.Add(b);
            navs[i] = b;
        }

        Controls.Add(nav);
    }

    void BuildPages()
    {
        content = new Panel();
        content.Bounds = new Rectangle(NavW, HeaderH, ClientSize.Width - NavW, ClientSize.Height - HeaderH - BarH);
        content.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        content.Tag = "win";
        content.Padding = new Padding(20, 16, 20, 16);
        Controls.Add(content);

        pages = new Panel[4];
        pages[0] = CommonPage();
        pages[1] = SettingsPage();
        pages[2] = DiagPage();
        pages[3] = AiPage();
        foreach (Panel p in pages)
        {
            p.Dock = DockStyle.Fill;
            p.Visible = false;
            p.Tag = "win";
            content.Controls.Add(p);
        }
    }

    void BuildBar()
    {
        Panel bar = new Panel();
        bar.Bounds = new Rectangle(0, ClientSize.Height - BarH, ClientSize.Width, BarH);
        bar.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        bar.Tag = "panel";
        bar.Paint += delegate(object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Theme.Line)) e.Graphics.DrawLine(p, 0, 0, bar.Width, 0);
        };

        status = new Label();
        status.Text = "就绪";
        status.AutoSize = false;
        status.Height = 22;
        status.Width = 520;
        status.Location = new Point(24, 21);
        status.Tag = "muted";
        bar.Controls.Add(status);

        Button apply = Btn("应用计划任务", delegate { RunCapture("register-task.ps1", "-Yes"); }, false);
        apply.Size = new Size(132, 36);
        apply.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        apply.Location = new Point(bar.Width - 154 - 140, 13);
        bar.Controls.Add(apply);

        Button save = Btn("保存设置", delegate { SaveSettings(); }, true);
        save.Size = new Size(124, 36);
        save.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        save.Location = new Point(bar.Width - 148, 13);
        bar.Controls.Add(save);

        Controls.Add(bar);
    }

    void ShowPage(int index)
    {
        for (int i = 0; i < pages.Length; i++)
        {
            pages[i].Visible = i == index;
            navs[i].Tag = i == index ? "navsel" : "nav";
            navs[i].BackColor = i == index ? Theme.NavSelBg : Theme.WindowBg;
            navs[i].ForeColor = i == index ? Theme.Ink : Theme.Muted;
            navs[i].Font = new Font("Microsoft YaHei UI", 10F, i == index ? FontStyle.Bold : FontStyle.Regular);
        }
        pages[index].BringToFront();
    }

    // ------------------------------------------------------------------ cards
    Panel Card(Control parent, string title, string desc, int top, int height)
    {
        Panel card = new Panel();
        card.Left = 0;
        card.Top = top;
        card.Width = parent.ClientSize.Width - 40;
        card.Height = height;
        card.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        card.Tag = "card";
        card.Paint += delegate(object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Theme.Line))
            {
                Rectangle r = new Rectangle(0, 0, card.Width - 1, card.Height - 1);
                e.Graphics.DrawRectangle(p, r);
            }
        };

        Label t = new Label();
        t.Text = title;
        t.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
        t.AutoSize = true;
        t.Location = new Point(16, 12);
        t.Tag = "section";
        card.Controls.Add(t);

        Label d = new Label();
        d.Text = desc;
        d.AutoSize = false;
        d.Width = card.Width - 32;
        d.Height = 34;
        d.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        d.Location = new Point(16, 38);
        d.Tag = "note";
        card.Controls.Add(d);
        card.Resize += delegate { try { d.Width = card.Width - 32; } catch { } };

        parent.Controls.Add(card);
        return card;
    }

    // ------------------------------------------------------------------ pages
    Panel CommonPage()
    {
        Panel page = new Panel();
        page.AutoScroll = true;

        Panel act = Card(page, "采集与整理", "采集会写数据目录；收藏全量约 20 分钟，可以随时在托盘看进度。", 0, 168);
        FlowLayoutPanel row1 = Flow(act, 66);
        row1.Controls.Add(Btn("采集观看记录", delegate { RunTask("history"); }, false));
        row1.Controls.Add(Btn("刷新收藏夹", delegate {
            if (UiNotice.Ask(this, "B印象", "收藏全量可能约 20 分钟，继续？")) RunTask("fav");
        }, false));
        row1.Controls.Add(Btn("刷新关注分组", delegate { RunTask("follow"); }, false));
        row1.Controls.Add(Btn("打开归档目录", delegate {
            if (cfg != null && cfg.ContainsKey("DataRoot")) Process.Start("explorer.exe", (string)cfg["DataRoot"]);
        }, false));

        Panel gen = Card(page, "生成与备份", "报告和卡片是只读的；备份会写你配置的备份目录。", 180, 168);
        FlowLayoutPanel row2 = Flow(gen, 66);
        row2.Controls.Add(Btn("生成统计报告", delegate { RunHidden("report.ps1", ""); }, false));
        row2.Controls.Add(Btn("生成分享卡片", delegate { RunHidden("share.ps1", ""); }, false));
        row2.Controls.Add(Btn("完整备份", delegate { RunTask("backup"); }, false));
        row2.Controls.Add(Btn("纯文本冷备份", delegate { RunTask("cold"); }, false));

        Panel tips = Card(page, "提示", "这些操作都会弹窗报告结果；失败时把弹窗里的最后几行发给 AI 就能定位。", 360, 132);
        Label hint = new Label();
        hint.AutoSize = false;
        hint.Width = tips.Width - 32;
        hint.Height = 40;
        hint.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        hint.Location = new Point(16, 74);
        hint.Text = "托盘图标会显示“正在采集 / 上次失败”；窗口可以关掉，任务在后台继续。";
        hint.Tag = "hint";
        tips.Controls.Add(hint);
        tips.Resize += delegate { try { hint.Width = tips.Width - 32; } catch { } };

        return page;
    }

    Panel SettingsPage()
    {
        Panel page = new Panel();
        page.AutoScroll = true;

        Panel sched = Card(page, "自动化", "“计划任务”由 Windows 任务计划程序在后台跑；“手动”只在你在托盘或这里点的时候跑。", 0, 300);
        TableLayoutPanel t = new TableLayoutPanel();
        t.Left = 14;
        t.Top = 62;
        t.Width = 560;
        t.ColumnCount = 2;
        t.RowCount = 6;
        t.AutoSize = true;
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 240));

        cbStartup = Combo(new string[] { "不自动启动", "开机启动托盘" });
        cbHistory = Combo(new string[] { "计划任务", "手动" });
        cbFavorites = Combo(new string[] { "计划任务", "手动" });
        cbFollows = Combo(new string[] { "计划任务", "手动" });
        cbBackup = Combo(new string[] { "计划任务", "手动" });
        cbBackupCold = Combo(new string[] { "计划任务", "手动" });

        AddRow(t, 0, "开机托盘", cbStartup);
        AddRow(t, 1, "观看记录", cbHistory);
        AddRow(t, 2, "收藏巡检", cbFavorites);
        AddRow(t, 3, "关注分组", cbFollows);
        AddRow(t, 4, "完整备份", cbBackup);
        AddRow(t, 5, "冷备份", cbBackupCold);
        sched.Height = 300;
        sched.Controls.Add(t);

        Label schedNote = new Label();
        schedNote.AutoSize = false;
        schedNote.Left = 14;
        schedNote.Top = 268;
        schedNote.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        schedNote.Height = 24;
        schedNote.Text = "改完先“保存设置”，再点右下角“应用计划任务”，否则只是写进了配置文件。";
        schedNote.Tag = "hint";
        sched.Controls.Add(schedNote);

        Panel look = Card(page, "界面与提示", "提示音选“柔和”时用自带的短音，不触发系统提示音。", 312, 300);
        TableLayoutPanel t2 = new TableLayoutPanel();
        t2.Left = 14;
        t2.Top = 62;
        t2.Width = 560;
        t2.ColumnCount = 2;
        t2.RowCount = 3;
        t2.AutoSize = true;
        t2.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        t2.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 240));

        cbLang = Combo(new string[] { "zh-CN", "en-US" });
        cbLog = Combo(new string[] { "普通", "详细（排障）" });
        cbSound = Combo(new string[] { "柔和（默认）", "Windows 系统音", "关闭" });
        AddRow(t2, 0, "界面语言", cbLang);
        AddRow(t2, 1, "日志级别", cbLog);
        AddRow(t2, 2, "提示音", cbSound);
        look.Controls.Add(t2);

        chkDesktop = new CheckBox();
        chkDesktop.Text = "在桌面放“最新备份”快捷方式（关掉后不会再自动重建）";
        chkDesktop.Font = new Font("Microsoft YaHei UI", 9.5F);
        chkDesktop.AutoSize = true;
        chkDesktop.Location = new Point(16, 218);
        chkDesktop.Tag = "ink";
        look.Controls.Add(chkDesktop);

        Button preview = Btn("试听提示音", delegate {
            string m = cbSound.SelectedIndex == 1 ? "system" : (cbSound.SelectedIndex == 2 ? "off" : "soft");
            if (m == "off") { SetStatus("提示音已关闭，试听不会出声。"); return; }
            SetStatus(m == "system" ? "试听：Windows 系统音" : "试听：柔和提示音（低频）");
            UiNotice.Preview(m);
        }, false);
        preview.Location = new Point(12, 178);
        preview.Size = new Size(150, 34);
        look.Controls.Add(preview);

        Button open = Btn("打开 config.json", delegate {
            string f = Path.Combine(root, "config.json");
            if (File.Exists(f)) OpenInNotepad(f); else Error("config.json 不存在，请先安装。");
        }, false);
        open.Location = new Point(172, 178);
        open.Size = new Size(170, 34);
        look.Controls.Add(open);

        return page;
    }

    Panel DiagPage()
    {
        Panel page = new Panel();
        page.AutoScroll = true;

        Panel checks = Card(page, "检查与工具", "自检不读你的数据；完整性校验只比文件哈希；帮助与日志都在本地。", 0, 186);
        FlowLayoutPanel row = Flow(checks, 76);
        row.Controls.Add(Btn("自检（不读数据）", delegate { RunCapture("selftest.ps1", "-SkipData"); }, false));
        row.Controls.Add(Btn("文件完整性校验", delegate { RunCapture("verify-files.ps1", ""); }, false));
        row.Controls.Add(Btn("检查更新", delegate { RunCapture("check-update.ps1", ""); }, false));
        row.Controls.Add(Btn("打开帮助", delegate {
            string f = Path.Combine(root, "docs", "能力说明.md");
            if (File.Exists(f)) OpenInNotepad(f); else Error("帮助文档缺失。");
        }, false));
        row.Controls.Add(Btn("打开日志文件夹", delegate {
            if (cfg != null && cfg.ContainsKey("DataRoot")) {
                string dir = Path.Combine((string)cfg["DataRoot"], "日志");
                if (Directory.Exists(dir)) Process.Start("explorer.exe", dir);
                else Error("日志目录还不存在。");
            }
        }, false));

        Panel logs = Card(page, "输出", "最近一次检查的原始输出；长文本可以全选复制。", 198, 320);
        logs.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        output = new TextBox();
        output.Multiline = true;
        output.ScrollBars = ScrollBars.Both;
        output.ReadOnly = true;
        output.WordWrap = false;
        output.Font = new Font("Consolas", 9.5F);
        output.Left = 14;
        output.Top = 78;
        output.Width = logs.Width - 28;
        output.Height = logs.Height - 92;
        output.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        output.Tag = "log";
        logs.Controls.Add(output);
        page.Resize += delegate {
            try
            {
                logs.Height = Math.Max(160, page.ClientSize.Height - 210);
                output.Width = logs.Width - 28;
                output.Height = logs.Height - 92;
            }
            catch { }
        };

        return page;
    }

    FlowLayoutPanel Flow(Control parent, int top)
    {
        FlowLayoutPanel f = new FlowLayoutPanel();
        f.Left = 12;
        f.Top = top;
        f.Width = parent.Width - 24;
        f.Height = parent.Height - top - 10;
        f.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        f.WrapContents = true;
        parent.Controls.Add(f);
        return f;
    }

    // ---------------------------------------------------------------- AI 页
    // 只读一页说明：文字来自 docs\AI-能做什么.md，改文件即可更新，不用重新编译。
    // 这一页不执行任何命令，也不代替使用者去调用 AI。
    Panel AiPage()
    {
        Panel page = new Panel();
        page.AutoScroll = true;

        Panel card = Card(page, "AI 能做什么",
            "这一页只读，不会执行任何操作。写着“可以让 AI 代劳”的事，按你的需要复制给 AI。", 0, 430);

        TextBox box = new TextBox();
        box.Name = "aiHelpText";
        box.Multiline = true;
        box.ReadOnly = true;
        box.WordWrap = true;
        box.ScrollBars = ScrollBars.Vertical;
        box.BorderStyle = BorderStyle.FixedSingle;
        box.Left = 16;
        box.Top = 84;
        box.Width = card.Width - 32;
        box.Height = card.Height - 100;
        box.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        box.Font = new Font("Microsoft YaHei UI", 9.5F);
        box.Tag = "input";
        box.Text = LoadHelpText();
        card.Controls.Add(box);
        card.Resize += delegate { try { box.Width = card.Width - 32; } catch { } };

        return page;
    }

    string LoadHelpText()
    {
        try
        {
            string f = Path.Combine(root, "docs", "AI-能做什么.md");
            if (File.Exists(f))
            {
                string text = File.ReadAllText(f, Encoding.UTF8).Replace("\r\n", "\n");
                return text.Replace("\n", "\r\n");
            }
        }
        catch { }
        return "没有找到 docs\\AI-能做什么.md。\r\n\r\n这一页只显示那个文件的内容；把文件放回 docs 目录，再打开设置窗口就会出现。";
    }

    // --------------------------------------------------------------- controls
    Button Btn(string text, EventHandler click, bool primary)
    {
        Button b = new Button();
        b.Text = text;
        b.AutoSize = false;
        b.Size = new Size(172, 36);
        b.Margin = new Padding(0, 0, 10, 10);
        b.Font = new Font("Microsoft YaHei UI", 9.5F);
        b.FlatStyle = FlatStyle.Flat;
        b.Cursor = Cursors.Hand;
        b.Tag = primary ? "primary" : "secondary";
        b.Click += click;
        return b;
    }

    ComboBox Combo(string[] items)
    {
        ComboBox c = new ComboBox();
        c.DropDownStyle = ComboBoxStyle.DropDownList;
        c.Width = 220;
        c.Font = new Font("Microsoft YaHei UI", 9.5F);
        c.Tag = "input";
        c.Items.AddRange(items);
        c.SelectedIndex = 0;
        return c;
    }

    void AddRow(TableLayoutPanel t, int row, string label, Control control)
    {
        Label l = new Label();
        l.Text = label;
        l.TextAlign = ContentAlignment.MiddleLeft;
        l.AutoSize = true;
        l.Margin = new Padding(0, 9, 12, 9);
        l.Tag = "rowname";
        control.Margin = new Padding(0, 7, 0, 7);
        t.Controls.Add(l, 0, row);
        t.Controls.Add(control, 1, row);
    }

    void SetStatus(string text)
    {
        if (status != null) status.Text = text;
    }

    void Error(string text)
    {
        UiNotice.Show("B印象", text, NoticeKind.Warn);
    }

    // ---------------------------------------------------------------- actions
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
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
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
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            SetStatus("正在运行 " + script + " …");
            Application.DoEvents();
            using (Process p = Process.Start(psi))
            {
                string so = p.StandardOutput.ReadToEnd();
                string se = p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (output != null) output.Text = (so + Environment.NewLine + se).Trim();
                SetStatus(script + " 退出码 " + p.ExitCode);
            }
        }
        catch (Exception ex) { Error("运行 " + script + " 失败：" + ex.Message); }
    }

    static void OpenInNotepad(string path)
    {
        try
        {
            string name = Path.GetFileName(path);
            foreach (Process q in Process.GetProcessesByName("notepad"))
            {
                try
                {
                    string title = q.MainWindowTitle;
                    if (title != null && title.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0) return;
                }
                catch { }
            }
        }
        catch { }
        Process.Start("notepad.exe", path);
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

    // ----------------------------------------------------------------- config
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
            chkDesktop.Checked = !(cfg.ContainsKey("DesktopShortcut") && cfg["DesktopShortcut"] is bool && !(bool)cfg["DesktopShortcut"]);
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
            cfg["DesktopShortcut"] = chkDesktop.Checked;

            var ser = new JavaScriptSerializer();
            SetStatus("正在保存…");
            Application.DoEvents();
            File.WriteAllText(Path.Combine(root, "config.json"), ser.Serialize(cfg), new UTF8Encoding(false));
            SetStatus("设置已保存（提示音立即生效；计划任务需点“应用计划任务”；界面语言与日志级别重启托盘后生效）。");

            string baseTitle = this.Text;
            this.Text = baseTitle + "  —  已保存";
            Timer flash = new Timer();
            flash.Interval = 2000;
            flash.Tick += delegate { try { flash.Stop(); flash.Dispose(); this.Text = baseTitle; } catch { } };
            flash.Start();
        }
        catch (Exception ex) { Error("保存失败：" + ex.Message); }
    }

    // ------------------------------------------------------------- dark mode
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg == 0x001A)
        {
            try
            {
                string area = System.Runtime.InteropServices.Marshal.PtrToStringAuto(m.LParam);
                if (string.IsNullOrEmpty(area) || area == "ImmersiveColorSet")
                {
                    Theme.Refresh(this);
                    for (int i = 0; i < navs.Length; i++)
                        navs[i].Font = new Font("Microsoft YaHei UI", 10F, navs[i].Tag as string == "navsel" ? FontStyle.Bold : FontStyle.Regular);
                    Invalidate(true);
                }
            }
            catch { }
        }
    }
}
