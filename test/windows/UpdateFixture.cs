using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

[assembly: AssemblyProduct("青听")]
internal static class UpdateFixture
{
    [STAThread]
    private static void Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        if (args.Length == 1 && args[0] == "--parent") {
            File.WriteAllText(Path.Combine(root, "parent.ready"), "ready");
            while (!File.Exists(Path.Combine(root, "parent.stop"))) Thread.Sleep(20);
            return;
        }
        string session = Environment.GetEnvironmentVariable("QINGTING_UPDATE_SESSION");
        if (!string.IsNullOrEmpty(session)) {
            if (File.Exists(Path.Combine(root, "fail-startup"))) return;
            File.WriteAllText(Path.Combine(session, "started"), Environment.GetEnvironmentVariable("QINGTING_UPDATE_TOKEN"));
        }
        File.WriteAllText(Path.Combine(root, "fixture.pid"), Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(TimeSpan.FromMinutes(5));
    }
}
