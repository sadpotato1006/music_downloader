using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace QingTingInstaller
{
    internal sealed class UpdateRequest
    {
        internal string Session;
        internal string Token;
        internal string Version;
        internal string InstallDir;
        internal int ParentPid;

        internal static UpdateRequest Read(string path)
        {
            path = Path.GetFullPath(path);
            string session = Path.GetDirectoryName(path);
            string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (Path.GetFileName(path) != "request.json" ||
                (!InstallTransaction.IsWithin(roaming, session) && !InstallTransaction.IsWithin(local, session)) ||
                !Path.GetFileName(session).StartsWith("session-", StringComparison.Ordinal) ||
                Path.GetFileName(Path.GetDirectoryName(session)) != "updates")
                throw new InvalidOperationException("升级请求位置无效。");
            InstallTransaction.RejectLinks(path);
            if (new FileInfo(path).Length > 65536) throw new InvalidOperationException("升级请求过大。");
            var data = InstallTransaction.Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
            var request = new UpdateRequest {
                Session = session, Token = (string)data["token"], Version = (string)data["version"],
                InstallDir = InstallTransaction.ValidateTarget((string)data["installDir"]),
                ParentPid = Convert.ToInt32(data["parentPid"])
            };
            if (Convert.ToInt32(data["protocol"]) != 1 || request.Version != BuildVersion.FullVersion ||
                request.Token.Length != 64 || request.Token.Any(c => !Uri.IsHexDigit(c)) || request.ParentPid <= 0)
                throw new InvalidOperationException("升级请求版本不匹配。");
            return request;
        }

        internal void Signal(string name, string value)
        {
            string destination = Path.Combine(Session, name);
            string temporary = destination + ".tmp";
            File.WriteAllText(temporary, value, new UTF8Encoding(false));
            if (File.Exists(destination)) File.Delete(destination);
            File.Move(temporary, destination);
        }

        internal bool HasSignal(string name)
        {
            string path = Path.Combine(Session, name);
            return File.Exists(path) && File.ReadAllText(path) == Token;
        }

        internal static UpdateRequest CreateManual(string directory)
        {
            string session = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "QingTing", "updates", "session-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(session);
            byte[] bytes = new byte[32];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
            var request = new UpdateRequest { Session = session, InstallDir = directory, Version = BuildVersion.FullVersion,
                Token = BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant() };
            File.WriteAllText(Path.Combine(session, "request.json"), InstallTransaction.Json.Serialize(new Dictionary<string, object> {
                {"protocol", 1}, {"token", request.Token}, {"version", request.Version}, {"installDir", directory}, {"parentPid", 0}
            }), new UTF8Encoding(false));
            return request;
        }
    }

    /// The backup stays intact until the new process acknowledges successful
    /// bootstrap. Files not owned by either app manifest are preserved, including
    /// music kept inside a custom installation directory.
    internal sealed class InstallTransaction : IDisposable
    {
        internal static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
        internal const string Marker = ".qingting-installation";
        internal const string Manifest = ".qingting-files.json";
        internal readonly string Target;
        internal readonly string Staging;
        internal readonly string Backup;
        internal readonly string Journal;
        private readonly string version;
        private readonly Mutex gate;
        private bool oldMoved;
        private bool newMoved;
        private bool completed;

        internal InstallTransaction(string target, string fullVersion)
        {
            Target = ValidateTarget(target);
            version = fullVersion;
            string digest;
            using (var hash = SHA256.Create()) digest = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Target.ToLowerInvariant()))).Replace("-", "");
            gate = new Mutex(false, "Local\\QingTingUpdate-" + digest);
            bool acquired;
            try { acquired = gate.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) { gate.Dispose(); throw new InvalidOperationException("另一个青听安装或升级正在进行。"); }
            Staging = Target + ".installing-" + Guid.NewGuid().ToString("N");
            Backup = Target + ".previous-" + Guid.NewGuid().ToString("N");
            Journal = Target + ".update-state.json";
            try {
                RecoverInterrupted(Target);
                Directory.CreateDirectory(Path.GetDirectoryName(Target));
                Directory.CreateDirectory(Staging);
            } catch { gate.ReleaseMutex(); gate.Dispose(); throw; }
        }

        internal static bool SamePath(string left, string right)
        {
            return string.Equals(Path.GetFullPath(left).TrimEnd('\\', '/'), Path.GetFullPath(right).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
        }

        internal static bool IsWithin(string parent, string child)
        {
            return !string.IsNullOrEmpty(parent) && Path.GetFullPath(child).StartsWith(
                Path.GetFullPath(parent).TrimEnd('\\', '/') + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }

        internal static void RejectLinks(string path)
        {
            for (string current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current)) {
                if ((File.Exists(current) || Directory.Exists(current)) &&
                    (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("升级目录包含链接，请选择普通的青听安装目录。");
            }
        }

        internal static string ValidateTarget(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new InvalidOperationException("安装目录无效。");
            string target = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)).TrimEnd('\\', '/');
            if (target.StartsWith(@"\\", StringComparison.Ordinal) || SamePath(target, Path.GetPathRoot(target)))
                throw new InvalidOperationException("请选择本地磁盘上专用于青听的子目录。");
            foreach (var folder in new[] { Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.DesktopDirectory,
                Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData,
                Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.Windows }) {
                string protectedPath = Environment.GetFolderPath(folder);
                if (!string.IsNullOrEmpty(protectedPath) && SamePath(target, protectedPath)) throw new InvalidOperationException("不能替换用户或系统目录。");
            }
            if (SamePath(target, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads")))
                throw new InvalidOperationException("不能替换下载目录，请选择青听的子目录。");
            RejectLinks(target);
            string updateCache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QingTing", "updates");
            if (SamePath(target, updateCache) || IsWithin(target, updateCache) || IsWithin(updateCache, target))
                throw new InvalidOperationException("安装目录不能与青听更新缓存重叠。");
            if (Directory.Exists(target) && Directory.GetFileSystemEntries(target).Length != 0 && !IsApplication(target))
                throw new InvalidOperationException("此目录不是青听的安装目录，请选择已安装的青听或一个空目录。");
            return target;
        }

        internal static bool IsApplication(string path)
        {
            string executable = Path.Combine(path, "qingting.exe");
            if (!File.Exists(executable) || !File.Exists(Path.Combine(path, "flutter_windows.dll")) || !Directory.Exists(Path.Combine(path, "data"))) return false;
            string marker = Path.Combine(path, Marker);
            if (File.Exists(marker) && File.ReadAllText(marker).StartsWith("QingTing|", StringComparison.Ordinal)) return true;
            // Recognize older custom-directory installations without deleting them.
            var info = FileVersionInfo.GetVersionInfo(executable);
            return info.ProductName == "青听" && info.OriginalFilename == "qingting.exe";
        }

        private static IEnumerable<string> Files(string directory)
        {
            RejectLinks(directory);
            foreach (string file in Directory.GetFiles(directory)) { RejectLinks(file); yield return file; }
            foreach (string child in Directory.GetDirectories(directory)) {
                foreach (string file in Files(child)) yield return file;
            }
        }

        private static string Relative(string root, string file) { return file.Substring(root.TrimEnd('\\').Length + 1).Replace('\\', '/'); }

        internal void Extract(Stream payload)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var archive = new ZipArchive(payload, ZipArchiveMode.Read, true)) {
                foreach (var entry in archive.Entries) {
                    string destination = Path.GetFullPath(Path.Combine(Staging, entry.FullName.Replace('/', '\\')));
                    if (!IsWithin(Staging, destination) || entry.FullName.Contains(":")) throw new InvalidDataException("安装包包含无效路径。");
                    if (string.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(destination); continue; }
                    if (!names.Add(Relative(Staging, destination))) throw new InvalidDataException("安装包包含重复文件。");
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    entry.ExtractToFile(destination, false);
                }
            }
            if (!File.Exists(Path.Combine(Staging, "qingting.exe")) || !File.Exists(Path.Combine(Staging, "flutter_windows.dll")) ||
                !File.Exists(Path.Combine(Staging, "data", "app.so"))) throw new InvalidDataException("安装包缺少必要的应用文件。");
            string stagedVersion = FileVersionInfo.GetVersionInfo(Path.Combine(Staging, "qingting.exe")).ProductVersion;
            if (stagedVersion != version) throw new InvalidDataException("安装包内的程序版本与发布版本不一致。");
            File.WriteAllText(Path.Combine(Staging, Marker), "QingTing|" + version, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(Staging, Manifest), Json.Serialize(names.OrderBy(n => n).ToArray()), new UTF8Encoding(false));
        }

        private void PreservePersonalFiles()
        {
            if (!Directory.Exists(Target)) return;
            var owned = new HashSet<string>(Json.Deserialize<string[]>(File.ReadAllText(Path.Combine(Staging, Manifest))), StringComparer.OrdinalIgnoreCase);
            string previousManifest = Path.Combine(Target, Manifest);
            if (File.Exists(previousManifest)) {
                if (new FileInfo(previousManifest).Length > 4 * 1024 * 1024) throw new InvalidDataException("旧版文件清单过大。");
                foreach (string relative in Json.Deserialize<string[]>(File.ReadAllText(previousManifest))) {
                    if (!IsWithin(Target, Path.Combine(Target, relative)) || relative.Contains(":")) throw new InvalidDataException("旧版文件清单无效。");
                    owned.Add(relative.Replace('\\', '/'));
                }
            }
            owned.Add(Marker); owned.Add(Manifest);
            foreach (string file in Files(Target)) {
                string relative = Relative(Target, file);
                if (owned.Contains(relative)) continue;
                string destination = Path.Combine(Staging, relative.Replace('/', '\\'));
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                File.Copy(file, destination, false);
            }
        }

        private void WriteJournal(string phase)
        {
            string temporary = Journal + ".tmp";
            File.WriteAllText(temporary, Json.Serialize(new Dictionary<string, string> {
                {"target", Target}, {"staging", Staging}, {"backup", Backup}, {"version", version}, {"phase", phase}
            }), new UTF8Encoding(false));
            if (File.Exists(Journal)) File.Replace(temporary, Journal, null); else File.Move(temporary, Journal);
        }

        internal void Apply()
        {
            if (!File.Exists(Path.Combine(Staging, Manifest))) throw new InvalidOperationException("尚未准备更新文件。");
            PreservePersonalFiles();
            WriteJournal("swapping");
            if (Directory.Exists(Target)) { MoveDirectory(Target, Backup); oldMoved = true; }
            try {
                MoveDirectory(Staging, Target); newMoved = true;
                WriteJournal("awaiting-startup");
            } catch { Rollback(); throw; }
        }

        internal void Commit(bool cleanBackup = true)
        {
            WriteJournal("committed");
            completed = true;
            // A failed cleanup must never roll back a healthy new application.
            if (cleanBackup) TryDelete(Backup);
            TryDelete(Staging);
            try { File.Delete(Journal); } catch { }
        }

        internal void Rollback()
        {
            if (completed) return;
            if (newMoved && Directory.Exists(Target)) {
                // Keep any newly created user files available even on rollback.
                MoveDirectory(Target, Target + ".failed-" + Guid.NewGuid().ToString("N"));
                newMoved = false;
            }
            if (oldMoved && Directory.Exists(Backup)) { MoveDirectory(Backup, Target); oldMoved = false; }
            if (!oldMoved && !newMoved) { try { File.Delete(Journal); } catch { } }
        }

        internal static void RecoverInterrupted(string target)
        {
            string journal = target + ".update-state.json";
            if (!File.Exists(journal)) return;
            RejectLinks(journal);
            if (new FileInfo(journal).Length > 65536) throw new InvalidDataException("升级恢复记录无效。");
            var state = Json.Deserialize<Dictionary<string, string>>(File.ReadAllText(journal));
            string backup = state["backup"];
            string staging = state["staging"];
            if (!SamePath(state["target"], target) || !GeneratedSibling(target, backup, ".previous-") || !GeneratedSibling(target, staging, ".installing-"))
                throw new InvalidDataException("升级恢复路径无效。");
            RejectLinks(backup); RejectLinks(staging);
            if (state["phase"] != "committed" && Directory.Exists(backup)) {
                if (IsRunning(target)) throw new InvalidOperationException("上次升级尚未完成，请退出青听后运行安装包恢复。");
                if (Directory.Exists(target)) MoveDirectory(target, target + ".failed-" + Guid.NewGuid().ToString("N"));
                MoveDirectory(backup, target);
            }
            if (state["phase"] == "committed") TryDelete(backup);
            TryDelete(staging);
            File.Delete(journal);
        }

        private static bool GeneratedSibling(string target, string path, string suffix)
        {
            string prefix = target + suffix;
            return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && path.Length == prefix.Length + 32 &&
                path.Substring(prefix.Length).All(Uri.IsHexDigit);
        }

        private static void MoveDirectory(string source, string destination)
        {
            // Windows can keep image/scan handles briefly after process exit.
            // Retry only sharing/access errors; keep the journal and backup if
            // the lock persists, rather than hiding a failed replacement.
            var timer = Stopwatch.StartNew();
            while (true) {
                try { Directory.Move(source, destination); return; }
                catch (IOException error) {
                    int code = error.HResult & 0xffff;
                    if ((code != 5 && code != 32 && code != 33) || timer.Elapsed > TimeSpan.FromSeconds(5)) throw;
                }
                catch (UnauthorizedAccessException) {
                    if (timer.Elapsed > TimeSpan.FromSeconds(5)) throw;
                }
                Thread.Sleep(50);
            }
        }

        private static void TryDelete(string path)
        {
            try { if (Directory.Exists(path)) { foreach (var file in Files(path)) { /* Validate every path before recursive removal. */ } Directory.Delete(path, true); } } catch { }
        }

        internal static List<Process> RunningApplication(string target)
        {
            var matches = new List<Process>();
            foreach (var process in Process.GetProcessesByName("qingting")) {
                try { if (SamePath(process.MainModule.FileName, Path.Combine(target, "qingting.exe"))) { matches.Add(process); continue; } }
                catch { }
                process.Dispose();
            }
            return matches;
        }

        internal static void CloseForManualInstall(string target)
        {
            foreach (var process in RunningApplication(target)) {
                using (process) {
                    EnumWindows(delegate(IntPtr window, IntPtr unused) {
                        uint owner; GetWindowThreadProcessId(window, out owner);
                        if (owner == process.Id) PostMessage(window, 0x0111, new IntPtr(40002), IntPtr.Zero);
                        return true;
                    }, IntPtr.Zero);
                    var timer = Stopwatch.StartNew();
                    while (!process.WaitForExit(100) && timer.Elapsed < TimeSpan.FromSeconds(60)) Application.DoEvents();
                    if (!process.HasExited) throw new InvalidOperationException("青听仍在保存数据，请从系统托盘退出青听后重试，无需删除安装目录。");
                }
            }
        }

        internal static bool IsRunning(string target)
        {
            var processes = RunningApplication(target);
            bool running = processes.Count > 0;
            foreach (var process in processes) process.Dispose();
            return running;
        }

        private delegate bool EnumWindowCallback(IntPtr window, IntPtr state);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, IntPtr state);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

        public void Dispose()
        {
            try { if (!completed) Rollback(); }
            finally { TryDelete(Staging); gate.ReleaseMutex(); gate.Dispose(); }
        }
    }

    internal static class UpdateRunner
    {
        internal static void Run(UpdateRequest request, Action<string> progress, Func<Stream> payload,
            TimeSpan? startupTimeout = null)
        {
            string oldRegistryVersion = null;
            bool registryChanged = false;
            Process launched = null;
            InstallTransaction transaction = null;
            bool parentExited = false;
            try {
                using (Process parent = Process.GetProcessById(request.ParentPid)) {
                    if (!InstallTransaction.SamePath(parent.MainModule.FileName, Path.Combine(request.InstallDir, "qingting.exe")))
                        throw new InvalidOperationException("发起升级的程序与安装位置不一致。");
                    transaction = new InstallTransaction(request.InstallDir, request.Version);
                    {
                        progress("正在准备新版文件…");
                        using (var stream = payload()) transaction.Extract(stream);
                        request.Signal("ready", request.Token);
                        progress("等待青听保存数据并退出…");
                        var timer = Stopwatch.StartNew();
                        while (!request.HasSignal("commit")) {
                            if (request.HasSignal("abort") || parent.HasExited || timer.Elapsed > TimeSpan.FromMinutes(10))
                                throw new InvalidOperationException("升级已取消，原版本未被替换。");
                            Thread.Sleep(100);
                        }
                        timer.Restart();
                        while (!parent.WaitForExit(100)) {
                            if (request.HasSignal("abort") || timer.Elapsed > TimeSpan.FromMinutes(2))
                                throw new InvalidOperationException("青听未能退出，原版本未被替换。");
                        }
                        parentExited = true;
                        if (request.HasSignal("abort")) throw new InvalidOperationException("升级已取消。");
                        if (InstallTransaction.IsRunning(request.InstallDir)) throw new InvalidOperationException("另一个青听进程仍在使用安装文件。");
                        progress("正在替换程序并保留个人文件…");
                        transaction.Apply();
                        progress("正在启动新版青听…");
                        launched = Launch(request.InstallDir, request);
                        timer.Restart();
                        while (!request.HasSignal("started")) {
                            if (launched.HasExited || timer.Elapsed > (startupTimeout ?? TimeSpan.FromMinutes(2)))
                                throw new InvalidOperationException("新版未能正常启动，请查看诊断日志后重试。");
                            Thread.Sleep(100);
                        }
                        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing", true)) {
                            if (key != null && key.GetValue("InstallLocation") is string &&
                                InstallTransaction.SamePath((string)key.GetValue("InstallLocation"), request.InstallDir)) {
                                oldRegistryVersion = key.GetValue("DisplayVersion") as string;
                                key.SetValue("DisplayVersion", BuildVersion.ReleaseVersion);
                                registryChanged = true;
                            }
                        }
                        transaction.Commit();
                        try { request.Signal("complete", request.Token); } catch { }
                    }
                }
            } catch (Exception error) {
                // Kill only the new process started by this updater. No process-name
                // termination and no forced shutdown of the user's old application.
                if (launched != null) { try { if (!launched.HasExited) { launched.Kill(); launched.WaitForExit(10000); } } catch { } }
                if (transaction != null) transaction.Rollback();
                if (registryChanged && oldRegistryVersion != null) {
                    using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing", true)) {
                        if (key != null) key.SetValue("DisplayVersion", oldRegistryVersion);
                    }
                }
                request.Signal("error.txt", error.Message);
                if (parentExited && File.Exists(Path.Combine(request.InstallDir, "qingting.exe"))) {
                    try { Launch(request.InstallDir, null); } catch { }
                }
                throw;
            } finally { if (transaction != null) transaction.Dispose(); if (launched != null) launched.Dispose(); }
        }

        internal static Process Launch(string directory, UpdateRequest request)
        {
            var start = new ProcessStartInfo(Path.Combine(directory, "qingting.exe")) {
                WorkingDirectory = directory, UseShellExecute = false
            };
            start.EnvironmentVariables.Remove("QINGTING_UPDATE_SESSION");
            start.EnvironmentVariables.Remove("QINGTING_UPDATE_TOKEN");
            if (request != null) {
                start.EnvironmentVariables["QINGTING_UPDATE_SESSION"] = request.Session;
                start.EnvironmentVariables["QINGTING_UPDATE_TOKEN"] = request.Token;
            }
            return Process.Start(start);
        }
    }

    internal sealed class UpdateForm : Form
    {
        private bool finished;
        internal UpdateForm(string requestPath)
        {
            Text = "青听升级"; StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
            ClientSize = new Size(440, 120); Font = new Font("Microsoft YaHei UI", 10f);
            var label = new Label { Text = "正在准备升级…", Left = 24, Top = 24, Width = 392, Height = 28 };
            Controls.Add(label);
            Controls.Add(new ProgressBar { Left = 24, Top = 64, Width = 392, Height = 18, Style = ProgressBarStyle.Marquee });
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (!finished) args.Cancel = true; };
            Shown += async delegate {
                try {
                    UpdateRequest request = UpdateRequest.Read(requestPath);
                    await Task.Run(() => UpdateRunner.Run(request,
                        text => BeginInvoke(new Action(() => label.Text = text)),
                        () => Assembly.GetExecutingAssembly().GetManifestResourceStream("QingTingPayload.zip")));
                } catch (Exception error) { MessageBox.Show(this, error.Message, "青听升级", MessageBoxButtons.OK, MessageBoxIcon.Information); }
                finally { finished = true; Close(); }
            };
        }
    }
}
