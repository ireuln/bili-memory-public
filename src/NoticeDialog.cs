using System;
using System.Drawing;
using System.Windows.Forms;

/// <summary>
/// Replacement for MessageBox, for two reasons:
///   1. readability - the stock box is 9 pt with no breathing room, which is
///      noticeably smaller than the rest of this UI
///   2. control    - our own form does not fire the Windows chime that the
///      icon-triggered MessageBox does, so a quiet wav can be played instead
///</summary>
public class NoticeDialog : Form
{
    public NoticeDialog(string title, string text, NoticeKind kind, bool ask, bool defaultYes)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = SystemColors.Window;
        Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11F, FontStyle.Regular, GraphicsUnit.Point);

        int pad = 22;
        int iconSize = 32;
        int gap = 18;
        // Narrow screens (1024 px wide, or a laptop at 150%) must not get a
        // dialog wider than the desktop.
        int maxTextWidth = Math.Min(440, Math.Max(240, Screen.PrimaryScreen.WorkingArea.Width - 200));

        PictureBox icon = new PictureBox();
        icon.SizeMode = PictureBoxSizeMode.AutoSize;
        icon.Image = UiNotice.IconFor(kind).ToBitmap();
        icon.Location = new Point(pad, pad);
        Controls.Add(icon);

        Label body = new Label();
        body.AutoSize = false;
        // Must be set BEFORE measuring: an unparented Label still has the 9 pt
        // default, so measuring first produced a box too short for 11 pt text.
        body.Font = Font;
        body.Text = text;
        // Label.GetPreferredSize under-measures long CJK paragraphs (the first
        // build clipped the bottom third of the text), so measure explicitly.
        Size measured = TextRenderer.MeasureText(text, body.Font,
            new Size(maxTextWidth, int.MaxValue),
            TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl);
        body.Size = new Size(maxTextWidth, measured.Height + 6);
        body.Location = new Point(pad + iconSize + gap, pad + 2);
        Controls.Add(body);

        int contentRight = body.Right;
        int contentBottom = Math.Max(icon.Bottom, body.Bottom);

        Font buttonFont = new Font(Font.FontFamily, 10.5F, FontStyle.Regular, GraphicsUnit.Point);

        Button primary = new Button();
        primary.Text = ask ? "继续" : "确定";
        primary.Font = buttonFont;
        primary.Size = new Size(104, 36);
        primary.DialogResult = DialogResult.OK;
        Controls.Add(primary);

        Button secondary = null;
        if (ask)
        {
            secondary = new Button();
            secondary.Text = "取消";
            secondary.Font = buttonFont;
            secondary.Size = primary.Size;
            secondary.DialogResult = DialogResult.Cancel;
            Controls.Add(secondary);
        }

        int width = Math.Max(contentRight + pad, 380);
        int buttonsTop = contentBottom + pad;
        ClientSize = new Size(width, buttonsTop + primary.Height + pad);

        primary.Location = new Point(ClientSize.Width - pad - primary.Width, buttonsTop);
        if (secondary != null) secondary.Location = new Point(primary.Left - 10 - secondary.Width, buttonsTop);

        if (ask)
        {
            CancelButton = secondary;
            AcceptButton = defaultYes ? primary : secondary;
        }
        else
        {
            AcceptButton = primary;
            CancelButton = primary;
        }
    }
}
