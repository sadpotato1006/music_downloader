using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using QingTingInstaller;

internal static class UpdateEngineTests
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    private static string root, fixture;
    private static int passed;
    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static void Test(string name, Action action) { action(); passed++; Console.WriteLine("PASS " + name); }
    private static string Target(string name) {
        string target = Path.Combine(root, name);
        Directory.CreateDirectory(Path.Combine(target, "data"));
        File.Copy(fixture, Path.Combine(target, "qingting.exe"));
        File.WriteAllText(Path.Combine(target, "flutter_windows.dll"), "old-engine");
        File.WriteAllText(Path.Combine(target, "data", "app.so"), "old-app");
        Directory.CreateDirectory(Path.Combine(target, "music"));
        File.WriteAllText(Path.Combine(target, "music", "song.mp3"), "personal music");
        return target;
    }
    private static MemoryStream Payload(bool badPath = false) {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true)) {
            zip.CreateEntryFromFile(fixture, "qingting.exe");
            foreach (var name in new[] { "flutter_windows.dll", "data/app.so", "new.dll" }) {
                using (var writer = new StreamWriter(zip.CreateEntry(name).Open())) writer.Write("new-app");
            }
            if (badPath) using (var writer = new StreamWriter(zip.CreateEntry("../escape.txt").Open())) writer.Write("invalid");
        }
        stream.Position = 0;
        return stream;
    }
    private static void Extract(InstallTransaction transaction) { using (var payload = Payload()) transaction.Extract(payload); }
    private static void Wait(Func<bool> predicate, string message) {
        var watch = Stopwatch.StartNew();
        while (!predicate()) { if (watch.Elapsed > TimeSpan.FromSeconds(25)) throw new Exception(message); Thread.Sleep(25); }
    }
    private static void StopFixtures(string target) {
        foreach (var process in InstallTransaction.RunningApplication(target)) using (process) {
            if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); }
        }
    }
    private static void Runner(string name, bool abort, bool failStartup) {
        string target = Target(name);
        if (failStartup) File.WriteAllText(Path.Combine(target, "fail-startup"), "test");
        string session = Path.Combine(root, "session-" + name);
        Directory.CreateDirectory(session);
        using (var parent = Process.Start(new ProcessStartInfo(Path.Combine(target, "qingting.exe"), "--parent") {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = target
        })) {
            Wait(() => File.Exists(Path.Combine(target, "parent.ready")), "parent did not initialize");
            var request = new UpdateRequest { Session = session, Token = new string('a', 64),
                InstallDir = target, Version = BuildVersion.FullVersion, ParentPid = parent.Id };
            Exception error = null;
            var operation = Task.Run(() => {
                try { UpdateRunner.Run(request, text => {}, () => Payload(), TimeSpan.FromSeconds(3)); }
                catch (Exception caught) { error = caught; }
            });
            try {
                Wait(() => request.HasSignal("ready") || operation.IsCompleted, "helper did not prepare");
                Assert(request.HasSignal("ready"), "helper failed to prepare: " + error);
                Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "old-app", "old files touched before commit");
                if (abort) request.Signal("abort", request.Token);
                else { request.Signal("commit", request.Token); File.WriteAllText(Path.Combine(target, "parent.stop"), "stop"); }
                Assert(operation.Wait(25000), "helper timeout");
                if (abort) {
                    Assert(!parent.HasExited, "cancellation killed the parent");
                    Assert(error != null && !File.Exists(Path.Combine(target, "new.dll")), "cancellation replaced files");
                } else if (failStartup) {
                    Assert(error != null && File.Exists(Path.Combine(session, "error.txt")), "startup failure was not reported");
                    Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "old-app", "old app not restored");
                    Wait(() => File.Exists(Path.Combine(target, "fixture.pid")), "old app not restarted");
                } else {
                    Assert(error == null, "upgrade failed: " + error);
                    Assert(request.HasSignal("complete"), "completion acknowledgement missing");
                    Wait(() => File.Exists(Path.Combine(target, "fixture.pid")), "new app did not initialize");
                    Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "new-app", "new app missing");
                    Assert(Directory.GetDirectories(root, name + ".previous-*").Length == 0, "backup was not cleaned after startup");
                }
                Assert(File.ReadAllText(Path.Combine(target, "music", "song.mp3")) == "personal music", "personal file changed");
            } finally {
                request.Signal("abort", request.Token);
                if (!parent.HasExited) { File.WriteAllText(Path.Combine(target, "parent.stop"), "stop"); parent.WaitForExit(5000); }
                operation.Wait(5000);
                StopFixtures(target);
            }
        }
    }
    private static int Main(string[] args) {
        try {
            if (args[0] == "--crash") {
                fixture = args[2];
                var transaction = new InstallTransaction(args[1], BuildVersion.FullVersion);
                Extract(transaction); transaction.Apply(); Environment.Exit(17); return 17;
            }
            root = Path.GetFullPath(args[0]); fixture = Path.GetFullPath(args[1]);
            Directory.CreateDirectory(root);
            Test("legacy custom installation is recognized", () => Assert(InstallTransaction.IsApplication(Target("legacy")), "legacy detection failed"));
            Test("unrelated directory is rejected without changes", () => {
                string directory = Path.Combine(root, "unrelated"); Directory.CreateDirectory(directory);
                File.WriteAllText(Path.Combine(directory, "keep.txt"), "keep");
                bool rejected = false; try { InstallTransaction.ValidateTarget(directory); } catch (InvalidOperationException) { rejected = true; }
                Assert(rejected && File.ReadAllText(Path.Combine(directory, "keep.txt")) == "keep", "unsafe target accepted");
            });
            Test("payload traversal is rejected", () => {
                using (var transaction = new InstallTransaction(Target("traversal"), BuildVersion.FullVersion)) {
                    bool rejected = false;
                    try { using (var payload = Payload(true)) transaction.Extract(payload); } catch (InvalidDataException) { rejected = true; }
                    Assert(rejected && !File.Exists(Path.Combine(root, "escape.txt")), "zip traversal accepted");
                }
            });
            Test("successful replacement preserves personal files and removes obsolete managed files", () => {
                string target = Target("commit");
                File.WriteAllText(Path.Combine(target, "obsolete.dll"), "old");
                File.WriteAllText(Path.Combine(target, InstallTransaction.Manifest), "[\"obsolete.dll\"]");
                using (var transaction = new InstallTransaction(target, BuildVersion.FullVersion)) {
                    Extract(transaction); transaction.Apply();
                    Assert(File.ReadAllText(Path.Combine(target, "music", "song.mp3")) == "personal music", "music lost");
                    Assert(!File.Exists(Path.Combine(target, "obsolete.dll")), "obsolete file retained");
                    Assert(Directory.Exists(transaction.Backup), "backup missing before startup");
                    transaction.Commit(); Assert(!Directory.Exists(transaction.Backup), "committed backup remains");
                }
            });
            Test("replacement waits for a transient directory lock", () => {
                string target = Target("transient-lock");
                using (var transaction = new InstallTransaction(target, BuildVersion.FullVersion)) {
                    Extract(transaction);
                    IntPtr handle = CreateFile(target, 1, 3, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
                    Assert(handle != new IntPtr(-1), "could not open directory lock fixture");
                    var release = Task.Run(() => { Thread.Sleep(250); CloseHandle(handle); });
                    transaction.Apply(); release.Wait(); transaction.Commit();
                    Assert(File.Exists(Path.Combine(target, "new.dll")), "replacement did not finish after lock release");
                }
            });
            Test("uncommitted transaction restores old program", () => {
                string target = Target("rollback");
                using (var transaction = new InstallTransaction(target, BuildVersion.FullVersion)) { Extract(transaction); transaction.Apply(); }
                Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "old-app", "rollback failed");
                Assert(!File.Exists(Path.Combine(target, "new.dll")), "new file remained");
            });
            Test("interrupted process recovers from persistent journal", () => {
                string target = Target("crash");
                using (var process = Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,
                    "--crash \"" + target + "\" \"" + fixture + "\"") { UseShellExecute = false, CreateNoWindow = true })) {
                    Assert(process.WaitForExit(10000) && process.ExitCode == 17, "crash fixture failed");
                }
                Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "new-app", "fixture did not replace app");
                using (var transaction = new InstallTransaction(target, BuildVersion.FullVersion)) {
                    Assert(File.ReadAllText(Path.Combine(target, "data", "app.so")) == "old-app", "journal did not recover old app");
                }
            });
            Test("helper handshake and startup acknowledgement commit", () => Runner("success", false, false));
            Test("cancellation leaves original process and files intact", () => Runner("cancel", true, false));
            Test("new process failure rolls back and restarts old app", () => Runner("failure", false, true));
            Console.WriteLine(passed + " Windows updater integration tests passed.");
            return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
