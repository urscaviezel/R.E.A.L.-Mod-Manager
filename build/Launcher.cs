// R.E.A.L. Mod Manager - Starter (EXE). Startet RealVRManager.ps1 aus dem eigenen Ordner mit Windows PowerShell 5.1.
// C# 5, wird von build\Build-Release.ps1 mit dem csc.exe des .NET Framework kompiliert. Lizenz: GPL-3.0-or-later
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class RealModManagerLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [STAThread]
    static int Main(string[] args)
    {
        string exe = Process.GetCurrentProcess().MainModule.FileName;
        string dir = Path.GetDirectoryName(exe);
        string script = Path.Combine(dir, "RealVRManager.ps1");
        if (!File.Exists(script))
        {
            MessageBoxW(IntPtr.Zero, "RealVRManager.ps1 not found next to the program.\nRealVRManager.ps1 wurde neben dem Programm nicht gefunden.\n\n" + dir, "R.E.A.L. Mod Manager", 0x10);
            return 1;
        }
        bool debug = false;
        foreach (string a in args) { string x = a.ToLowerInvariant(); if (x == "--debug" || x == "/debug" || x == "-debug") debug = true; }

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) ps = "powershell.exe";
        StringBuilder sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA ");
        sb.Append(debug ? "-NoExit " : "-WindowStyle Hidden ");
        sb.Append("-File \"").Append(script).Append("\"");
        if (debug) sb.Append(" -DebugConsole");

        ProcessStartInfo psi = new ProcessStartInfo(ps, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = !debug;
        psi.WorkingDirectory = dir;
        psi.EnvironmentVariables["RVM_LAUNCHER"] = exe;
        try { Process.Start(psi); }
        catch (Exception e)
        {
            MessageBoxW(IntPtr.Zero, "Start failed / Start fehlgeschlagen:\n\n" + e.Message, "R.E.A.L. Mod Manager", 0x10);
            return 2;
        }
        return 0;
    }
}
