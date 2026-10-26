using Microsoft.Win32;
using System;
using System.Drawing;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("QingTing Setup")]
[assembly: AssemblyProduct("QingTing")]
[assembly: AssemblyCompany("Pobb")]

namespace QingTingInstaller
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 2 && args[0] == "--update") {
                Application.Run(new UpdateForm(args[1]));
            } else if (args.Length == 0) {
                Application.Run(new InstallerForm());
            } else {
                MessageBox.Show("安装参数无效。", "青听安装向导");
                Environment.ExitCode = 1;
            }
        }
    }

    internal sealed class InstallerForm : Form
    {
        private const string AppId = "QingTing";
        private const string AppName = "\u9752\u542c";
        private const string Version = BuildVersion.ReleaseVersion;
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
        private InstallTransaction pendingInstallation;
        private bool finishing;
        private bool replacingInstallation;
        private string previousRegistryVersion;

        public InstallerForm()
        {
            installDir = DefaultInstallDirectory();
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (finishing || page == 4) args.Cancel = true; };
            FormClosed += delegate {
                if (pendingInstallation != null) {
                    // A user may finish without launching. Retain the previous files.
                    pendingInstallation.Commit(false);
                    pendingInstallation.Dispose();
                    pendingInstallation = null;
                }
            };

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
            if (page == 5) {
                FinishInstallation();
                return;
            }

            if (page == 1)
            {
                try
                {
                    installDir = ValidateInstallDirectory(installDir);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "青听安装向导", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
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
            installDir = ValidateInstallDirectory(installDir);
            SetProgress(status, progress, "正在等待青听保存数据并退出...", 5);
            InstallTransaction.CloseForManualInstall(installDir);
            var transaction = new InstallTransaction(installDir, BuildVersion.FullVersion);
            try {
                replacingInstallation = InstallTransaction.IsApplication(installDir);
                SetProgress(status, progress, "正在准备新版文件...", 20);
                using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("QingTingPayload.zip")) {
                    transaction.Extract(payload);
                }
                SetProgress(status, progress, "正在保留个人文件并替换程序...", 45);
                transaction.Apply();
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing")) {
                    previousRegistryVersion = key == null ? null : key.GetValue("DisplayVersion") as string;
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
                pendingInstallation = transaction;
            } catch {
                transaction.Dispose();
                throw;
            }
        }

        private void FinishInstallation()
        {
            Process launched = null;
            finishing = true;
            nextButton.Enabled = false;
            try {
                if (runAfterInstall && pendingInstallation != null) {
                    nextButton.Text = "正在启动...";
                    var request = UpdateRequest.CreateManual(installDir);
                    launched = UpdateRunner.Launch(installDir, request);
                    var timer = Stopwatch.StartNew();
                    while (!request.HasSignal("started")) {
                        if (launched.HasExited || timer.Elapsed > TimeSpan.FromMinutes(2))
                            throw new InvalidOperationException("青听未能正常启动，请查看诊断日志后重试。");
                        Application.DoEvents();
                        System.Threading.Thread.Sleep(100);
                    }
                    pendingInstallation.Commit();
                } else if (pendingInstallation != null) {
                    pendingInstallation.Commit(false);
                }
            } catch (Exception error) {
                if (launched != null && !launched.HasExited) { launched.Kill(); launched.WaitForExit(10000); }
                if (pendingInstallation != null) {
                    if (replacingInstallation) pendingInstallation.Rollback();
                    // A fresh installation has no previous program to restore.
                    // Keep it installed so its recovery screen can be reopened.
                    else pendingInstallation.Commit(false);
                }
                if (replacingInstallation && previousRegistryVersion != null) {
                    using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing", true)) {
                        if (key != null) key.SetValue("DisplayVersion", previousRegistryVersion);
                    }
                }
                if (replacingInstallation && File.Exists(Path.Combine(installDir, "qingting.exe"))) {
                    try { UpdateRunner.Launch(installDir, null); } catch { }
                }
                MessageBox.Show(this, error.Message, "青听安装向导", MessageBoxButtons.OK, MessageBoxIcon.Information);
            } finally {
                if (launched != null) launched.Dispose();
                if (pendingInstallation != null) { pendingInstallation.Dispose(); pendingInstallation = null; }
                finishing = false;
            }
            Close();
        }

        private static string DefaultInstallDirectory()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing")) {
                var location = key == null ? null : key.GetValue("InstallLocation") as string;
                try { if (!string.IsNullOrEmpty(location) && InstallTransaction.IsApplication(location)) return InstallTransaction.ValidateTarget(location); }
                catch { }
            }
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                "QingTing");
        }

        private static string ValidateInstallDirectory(string path)
        {
            return InstallTransaction.ValidateTarget(path);
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
