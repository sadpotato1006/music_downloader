using Microsoft.Win32;
using System;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace QingTingInstaller
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new InstallerForm());
        }
    }

    internal sealed class InstallerForm : Form
    {
        private const string AppId = "QingTing";
        private const string AppName = "\u9752\u542c";
        private const string Version = "1.2.5";
        private const string Publisher = "Pobb";

        private readonly Panel content;
        private readonly Button backButton;
        private readonly Button nextButton;
        private readonly Button cancelButton;

        private int page;
        private string installDir;
        private bool createDesktopShortcut = true;
        private bool createStartMenuShortcut = true;
        private bool runAfterInstall = true;
        private string installedExe;

        public InstallerForm()
        {
            installDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                "QingTing");

            Text = "青听安装向导";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ClientSize = new Size(620, 420);
            Font = new Font("Microsoft YaHei UI", 9f);

            Panel header = new Panel();
            header.Location = new Point(0, 0);
            header.Size = new Size(620, 76);
            header.BackColor = Color.FromArgb(232, 246, 238);
            Controls.Add(header);

            header.Controls.Add(NewLabel("青听安装向导", 24, 16, 420, 30, 16f, true));
            header.Controls.Add(NewLabel("Windows 版音乐搜索、播放与下载工具", 24, 45, 420, 20, 9f, false));

            content = new Panel();
            content.Location = new Point(24, 96);
            content.Size = new Size(572, 238);
            Controls.Add(content);

            backButton = NewButton("上一步", 320, 360);
            nextButton = NewButton("下一步", 412, 360);
            cancelButton = NewButton("取消", 504, 360);
            Controls.Add(backButton);
            Controls.Add(nextButton);
            Controls.Add(cancelButton);

            AcceptButton = nextButton;
            CancelButton = cancelButton;

            backButton.Click += delegate { GoBack(); };
            nextButton.Click += delegate { GoNext(); };
            cancelButton.Click += delegate { ConfirmCancel(); };

            ShowPage();
        }

        private static Label NewLabel(string text, int x, int y, int width, int height, float fontSize, bool bold)
        {
            Label label = new Label();
            label.Text = text;
            label.Location = new Point(x, y);
            label.Size = new Size(width, height);
            label.Font = new Font("Microsoft YaHei UI", fontSize, bold ? FontStyle.Bold : FontStyle.Regular);
            return label;
        }

        private static Button NewButton(string text, int x, int y)
        {
            Button button = new Button();
            button.Text = text;
            button.Location = new Point(x, y);
            button.Size = new Size(82, 32);
            return button;
        }

        private void ShowPage()
        {
            content.Controls.Clear();
            backButton.Enabled = page > 0 && page < 4;
            cancelButton.Enabled = page < 4;
            nextButton.Enabled = true;
            nextButton.Text = "下一步";

            if (page == 0)
            {
                content.Controls.Add(NewLabel("欢迎使用青听安装向导", 0, 0, 540, 34, 14f, true));
                content.Controls.Add(NewLabel("此向导会把青听安装到你的电脑，并按需创建桌面和开始菜单快捷方式。", 0, 48, 540, 44, 10f, false));
                content.Controls.Add(NewLabel("点击“下一步”继续。", 0, 112, 540, 24, 10f, false));
            }
            else if (page == 1)
            {
                content.Controls.Add(NewLabel("选择安装位置", 0, 0, 540, 30, 14f, true));
                content.Controls.Add(NewLabel("青听将安装到下面的文件夹。", 0, 42, 540, 24, 10f, false));

                TextBox pathBox = new TextBox();
                pathBox.Location = new Point(0, 82);
                pathBox.Size = new Size(442, 28);
                pathBox.Text = installDir;
                pathBox.TextChanged += delegate { installDir = pathBox.Text; };
                content.Controls.Add(pathBox);

                Button browseButton = new Button();
                browseButton.Text = "浏览...";
                browseButton.Location = new Point(456, 80);
                browseButton.Size = new Size(96, 30);
                browseButton.Click += delegate
                {
                    using (FolderBrowserDialog dialog = new FolderBrowserDialog())
                    {
                        dialog.Description = "选择青听的安装位置";
                        dialog.SelectedPath = Directory.Exists(pathBox.Text) ? pathBox.Text : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                        if (dialog.ShowDialog(this) == DialogResult.OK)
                        {
                            pathBox.Text = Path.Combine(dialog.SelectedPath, "QingTing");
                        }
                    }
                };
                content.Controls.Add(browseButton);
            }
            else if (page == 2)
            {
                content.Controls.Add(NewLabel("选择附加任务", 0, 0, 540, 30, 14f, true));

                CheckBox desktop = new CheckBox();
                desktop.Text = "创建桌面快捷方式";
                desktop.Location = new Point(0, 52);
                desktop.Size = new Size(320, 28);
                desktop.Checked = createDesktopShortcut;
                desktop.CheckedChanged += delegate { createDesktopShortcut = desktop.Checked; };
                content.Controls.Add(desktop);

                CheckBox startMenu = new CheckBox();
                startMenu.Text = "创建开始菜单快捷方式";
                startMenu.Location = new Point(0, 88);
                startMenu.Size = new Size(320, 28);
                startMenu.Checked = createStartMenuShortcut;
                startMenu.CheckedChanged += delegate { createStartMenuShortcut = startMenu.Checked; };
                content.Controls.Add(startMenu);
            }
            else if (page == 3)
            {
                content.Controls.Add(NewLabel("准备安装", 0, 0, 540, 30, 14f, true));
                string summary =
                    "安装位置：\r\n" + installDir +
                    "\r\n\r\n桌面快捷方式：" + BoolText(createDesktopShortcut) +
                    "\r\n开始菜单快捷方式：" + BoolText(createStartMenuShortcut);
                content.Controls.Add(NewLabel(summary, 0, 48, 540, 120, 10f, false));
                nextButton.Text = "安装";
            }
            else if (page == 4)
            {
                backButton.Enabled = false;
                cancelButton.Enabled = false;
                nextButton.Enabled = false;

                content.Controls.Add(NewLabel("正在安装青听", 0, 0, 540, 30, 14f, true));
                Label status = NewLabel("正在开始...", 0, 56, 540, 26, 10f, false);
                content.Controls.Add(status);

                ProgressBar progress = new ProgressBar();
                progress.Location = new Point(0, 96);
                progress.Size = new Size(552, 24);
                progress.Minimum = 0;
                progress.Maximum = 100;
                content.Controls.Add(progress);

                BeginInvoke(new Action(delegate
                {
                    try
                    {
                        InstallApp(status, progress);
                        page = 5;
                        ShowPage();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(this, ex.Message, "青听安装向导", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        page = 3;
                        ShowPage();
                    }
                }));
            }
            else if (page == 5)
            {
                backButton.Enabled = false;
                cancelButton.Enabled = false;
                nextButton.Enabled = true;
                nextButton.Text = "完成";

                content.Controls.Add(NewLabel("正在完成青听安装向导", 0, 0, 540, 30, 14f, true));
                content.Controls.Add(NewLabel("青听已成功安装。", 0, 50, 540, 28, 10f, false));

                CheckBox runBox = new CheckBox();
                runBox.Text = "立即启动青听";
                runBox.Location = new Point(0, 92);
                runBox.Size = new Size(320, 28);
                runBox.Checked = runAfterInstall;
                runBox.CheckedChanged += delegate { runAfterInstall = runBox.Checked; };
                content.Controls.Add(runBox);
            }
        }

        private void GoNext()
        {
            if (page == 5)
            {
                if (runAfterInstall && !string.IsNullOrEmpty(installedExe) && File.Exists(installedExe))
                {
                    System.Diagnostics.Process.Start(installedExe);
                }
                Close();
                return;
            }

            if (page == 1 && string.IsNullOrWhiteSpace(installDir))
            {
                MessageBox.Show(this, "请选择安装位置。", "青听安装向导", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            page++;
            ShowPage();
        }

        private void GoBack()
        {
            if (page > 0)
            {
                page--;
                ShowPage();
            }
        }

        private void ConfirmCancel()
        {
            DialogResult result = MessageBox.Show(this, "确定退出青听安装向导？", "青听安装向导", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (result == DialogResult.Yes)
            {
                Close();
            }
        }

        private void InstallApp(Label status, ProgressBar progress)
        {
            SetProgress(status, progress, "正在准备安装目录...", 10);

            if (Directory.Exists(installDir))
            {
                Directory.Delete(installDir, true);
            }
            Directory.CreateDirectory(installDir);

            SetProgress(status, progress, "正在解压应用文件...", 35);
            string tempZip = Path.Combine(Path.GetTempPath(), "QingTingPayload-" + Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("QingTingPayload.zip"))
                {
                    if (input == null)
                    {
                        throw new InvalidOperationException("安装包内缺少应用文件。");
                    }
                    using (FileStream output = File.Create(tempZip))
                    {
                        input.CopyTo(output);
                    }
                }

                ZipFile.ExtractToDirectory(tempZip, installDir);
            }
            finally
            {
                if (File.Exists(tempZip))
                {
                    File.Delete(tempZip);
                }
            }

            installedExe = Path.Combine(installDir, "qingting.exe");
            if (!File.Exists(installedExe))
            {
                throw new FileNotFoundException("解压后未找到 qingting.exe。", installedExe);
            }

            SetProgress(status, progress, "正在创建快捷方式...", 65);
            if (createDesktopShortcut)
            {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                CreateShortcut(Path.Combine(desktop, AppName + ".lnk"), installedExe, installDir, "青听音乐下载器");
            }

            string uninstallBat = WriteUninstaller();
            if (createStartMenuShortcut)
            {
                string startMenu = Environment.GetFolderPath(Environment.SpecialFolder.StartMenu);
                string folder = Path.Combine(startMenu, "Programs", AppName);
                Directory.CreateDirectory(folder);
                CreateShortcut(Path.Combine(folder, AppName + ".lnk"), installedExe, installDir, "青听音乐下载器");
                CreateShortcut(Path.Combine(folder, "卸载青听.lnk"), uninstallBat, installDir, "卸载青听");
            }

            SetProgress(status, progress, "正在注册卸载程序...", 85);
            RegisterUninstallEntry(uninstallBat);

            SetProgress(status, progress, "安装完成。", 100);
        }

        private static string BoolText(bool value)
        {
            return value ? "是" : "否";
        }

        private static void SetProgress(Label status, ProgressBar progress, string text, int value)
        {
            status.Text = text;
            progress.Value = Math.Max(progress.Minimum, Math.Min(progress.Maximum, value));
            Application.DoEvents();
        }

        private static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory, string description)
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                return;
            }

            dynamic shell = Activator.CreateInstance(shellType);
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            shortcut.TargetPath = targetPath;
            shortcut.WorkingDirectory = workingDirectory;
            shortcut.IconLocation = targetPath + ",0";
            shortcut.Description = description;
            shortcut.Save();
        }

        private string WriteUninstaller()
        {
            string uninstallPs1 = Path.Combine(installDir, "uninstall-qingting.ps1");
            string uninstallBat = Path.Combine(installDir, "uninstall-qingting.bat");

            string script =
                "param([switch]$Quiet)\r\n" +
                "$ErrorActionPreference = 'SilentlyContinue'\r\n" +
                "$AppName = \"$([char]0x9752)$([char]0x542C)\"\r\n" +
                "$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path\r\n" +
                "$DesktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) \"$AppName.lnk\"\r\n" +
                "$StartMenuDir = Join-Path $env:APPDATA \"Microsoft\\Windows\\Start Menu\\Programs\\$AppName\"\r\n" +
                "$UninstallKey = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\QingTing'\r\n" +
                "Remove-Item -LiteralPath $DesktopShortcut -Force\r\n" +
                "Remove-Item -LiteralPath $StartMenuDir -Recurse -Force\r\n" +
                "Remove-Item -LiteralPath $UninstallKey -Recurse -Force\r\n" +
                "if (-not $Quiet) {\r\n" +
                "  Add-Type -AssemblyName System.Windows.Forms\r\n" +
                "  [System.Windows.Forms.MessageBox]::Show(\"$AppName 已卸载。\", '青听卸载', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null\r\n" +
                "}\r\n" +
                "$escaped = $InstallDir.Replace('\"', '\\\"')\r\n" +
                "Start-Process -FilePath 'cmd.exe' -ArgumentList \"/c ping 127.0.0.1 -n 2 >nul & rmdir /s /q `\"$escaped`\"\" -WindowStyle Hidden\r\n";

            File.WriteAllText(uninstallPs1, script, new UTF8Encoding(true));
            File.WriteAllText(
                uninstallBat,
                "@echo off\r\nsetlocal\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%~dp0uninstall-qingting.ps1\" %*\r\n",
                Encoding.ASCII);
            return uninstallBat;
        }

        private void RegisterUninstallEntry(string uninstallBat)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + AppId))
            {
                if (key == null)
                {
                    return;
                }

                key.SetValue("DisplayName", AppName, RegistryValueKind.String);
                key.SetValue("DisplayVersion", Version, RegistryValueKind.String);
                key.SetValue("Publisher", Publisher, RegistryValueKind.String);
                key.SetValue("InstallLocation", installDir, RegistryValueKind.String);
                key.SetValue("DisplayIcon", installedExe + ",0", RegistryValueKind.String);
                key.SetValue("UninstallString", "\"" + uninstallBat + "\"", RegistryValueKind.String);
                key.SetValue("QuietUninstallString", "\"" + uninstallBat + "\" /quiet", RegistryValueKind.String);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                key.SetValue("EstimatedSize", GetDirectorySizeKb(installDir), RegistryValueKind.DWord);
            }
        }

        private static int GetDirectorySizeKb(string path)
        {
            long bytes = 0;
            foreach (string file in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
            {
                try
                {
                    bytes += new FileInfo(file).Length;
                }
                catch
                {
                }
            }

            return (int)Math.Max(1, bytes / 1024);
        }
    }
}
