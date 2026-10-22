// R.E.A.L. Mod Manager - NVIDIA-Treiberprofile (NvAPI DRS), C# 5.
// Wird nur in einem eigenen PowerShell-Prozess geladen (NvidiaTool.ps1), damit ein Treiberproblem
// niemals den Manager selbst beendet. Erfasst und setzt nur die V-Sync-Einstellung einzelner Spiele
// bzw. entfernt das Spiel wieder aus dem Profil, in das Vdesync es eingetragen hat.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace RVM
{
    public class NvAppState
    {
        public string Exe { get; set; }
        public bool Found { get; set; }
        public string Profile { get; set; }
        public bool ProfilePredefined { get; set; }
        public int ProfileApps { get; set; }
        public bool VsyncPresent { get; set; }
        public int VsyncLocation { get; set; }
        public bool VsyncPredefined { get; set; }
        public uint VsyncValue { get; set; }
        public string Error { get; set; }
    }

    public static class NvDrs
    {
        public const uint VSYNC_ID = 0x00A879CF;
        const int OK = 0;
        const int SETTING_SIZE = 12320, PROFILE_SIZE = 4116, APP_SIZE = 12296, USTR = 4096;

        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr QueryInterface(uint id);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D0();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DCreate(out IntPtr h);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSession(IntPtr h);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DFindApp(IntPtr h, IntPtr appName, out IntPtr hProfile, IntPtr app);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DGetSetting(IntPtr h, IntPtr hProfile, uint id, IntPtr setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSetSetting(IntPtr h, IntPtr hProfile, IntPtr setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DProfileId(IntPtr h, IntPtr hProfile, uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DDeleteApp(IntPtr h, IntPtr hProfile, IntPtr appName);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DProfileInfo(IntPtr h, IntPtr hProfile, IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DProfile(IntPtr h, IntPtr hProfile);

        static T Fn<T>(uint id) where T : class
        {
            IntPtr p = QueryInterface(id);
            if (p == IntPtr.Zero) throw new Exception("NvAPI function not available: 0x" + id.ToString("X8"));
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        static IntPtr Alloc(int size, uint versionNumber)
        {
            IntPtr p = Marshal.AllocHGlobal(size);
            byte[] zero = new byte[size];
            Marshal.Copy(zero, 0, p, size);
            if (versionNumber > 0) Marshal.WriteInt32(p, 0, (int)((uint)size | (versionNumber << 16)));
            return p;
        }

        static IntPtr UStr(string s)
        {
            IntPtr p = Alloc(USTR, 0);
            byte[] b = Encoding.Unicode.GetBytes(s ?? "");
            Marshal.Copy(b, 0, p, Math.Min(b.Length, USTR - 2));
            return p;
        }

        static string ReadUStr(IntPtr p, int offset)
        {
            byte[] b = new byte[USTR];
            Marshal.Copy(new IntPtr(p.ToInt64() + offset), b, 0, USTR);
            string s = Encoding.Unicode.GetString(b);
            int z = s.IndexOf('\0');
            return z >= 0 ? s.Substring(0, z) : s;
        }

        static IntPtr Open()
        {
            int r = Fn<D0>(0x0150E828)();
            if (r != OK) throw new Exception("NvAPI_Initialize: " + r);
            IntPtr h;
            r = Fn<DCreate>(0x0694D52E)(out h);
            if (r != OK) throw new Exception("NvAPI_DRS_CreateSession: " + r);
            r = Fn<DSession>(0x375DBD6B)(h);
            if (r != OK) { Fn<DSession>(0xDAD9CFF8)(h); throw new Exception("NvAPI_DRS_LoadSettings: " + r); }
            return h;
        }

        static void Close(IntPtr h) { try { Fn<DSession>(0xDAD9CFF8)(h); } catch { } }

        static int FindApp(IntPtr h, string exe, out IntPtr hProfile)
        {
            IntPtr name = UStr(exe), app = Alloc(APP_SIZE, 1);
            try { return Fn<DFindApp>(0xEEE566B2)(h, name, out hProfile, app); }
            finally { Marshal.FreeHGlobal(name); Marshal.FreeHGlobal(app); }
        }

        static void ReadProfile(IntPtr h, IntPtr hProfile, NvAppState s)
        {
            IntPtr prof = Alloc(PROFILE_SIZE, 1);
            try
            {
                int r = Fn<DProfileInfo>(0x61CD6FD6)(h, hProfile, prof);
                if (r != OK) { s.Error = "GetProfileInfo: " + r; return; }
                s.Profile = ReadUStr(prof, 4);
                s.ProfilePredefined = Marshal.ReadInt32(prof, 4104) != 0;
                s.ProfileApps = Marshal.ReadInt32(prof, 4108);
            }
            finally { Marshal.FreeHGlobal(prof); }
        }

        public static List<NvAppState> Capture(string[] exes)
        {
            List<NvAppState> list = new List<NvAppState>();
            IntPtr h = Open();
            try
            {
                foreach (string exe in exes)
                {
                    NvAppState s = new NvAppState(); s.Exe = exe;
                    list.Add(s);
                    IntPtr hp;
                    int r = FindApp(h, exe, out hp);
                    if (r != OK) { s.Found = false; continue; }
                    s.Found = true;
                    ReadProfile(h, hp, s);
                    IntPtr set = Alloc(SETTING_SIZE, 1);
                    try
                    {
                        r = Fn<DGetSetting>(0x73BF8338)(h, hp, VSYNC_ID, set);
                        if (r == OK)
                        {
                            s.VsyncPresent = true;
                            s.VsyncLocation = Marshal.ReadInt32(set, 4108);
                            s.VsyncPredefined = Marshal.ReadInt32(set, 4112) != 0;
                            s.VsyncValue = (uint)Marshal.ReadInt32(set, 8220);
                        }
                    }
                    finally { Marshal.FreeHGlobal(set); }
                }
            }
            finally { Close(h); }
            return list;
        }

        // Stellt den Zustand "before" fuer jede App wieder her. "after" = Zustand direkt nach der Installation.
        public static List<string> Restore(NvAppState[] before, NvAppState[] after)
        {
            List<string> log = new List<string>();
            IntPtr h = Open();
            bool changed = false;
            try
            {
                for (int i = 0; i < before.Length; i++)
                {
                    NvAppState b = before[i];
                    NvAppState a = (after != null && i < after.Length) ? after[i] : null;
                    IntPtr hp;
                    int r = FindApp(h, b.Exe, out hp);
                    if (!b.Found)
                    {
                        if (r != OK) { log.Add("OK  " + b.Exe + ": not in any NVIDIA profile (nothing to do)"); continue; }
                        NvAppState now = new NvAppState(); ReadProfile(h, hp, now);
                        if (a != null && a.Found && !string.Equals(now.Profile, a.Profile, StringComparison.OrdinalIgnoreCase))
                        {
                            log.Add("WARN " + b.Exe + ": is now in profile '" + now.Profile + "' - left untouched");
                            continue;
                        }
                        IntPtr name = UStr(b.Exe);
                        try { r = Fn<DDeleteApp>(0x2C694BC6)(h, hp, name); }
                        finally { Marshal.FreeHGlobal(name); }
                        if (r != OK) { log.Add("ERR " + b.Exe + ": DeleteApplication " + r); continue; }
                        changed = true;
                        log.Add("OK  " + b.Exe + " removed from NVIDIA profile '" + now.Profile + "' removed");
                        NvAppState left = new NvAppState(); ReadProfile(h, hp, left);
                        if (left.Error == null && left.ProfileApps == 0 && !left.ProfilePredefined)
                        {
                            r = Fn<DProfile>(0x17093206)(h, hp);
                            log.Add(r == OK ? "OK  empty profile '" + left.Profile + "' removed" : "WARN profile '" + left.Profile + "' not removed: " + r);
                        }
                        continue;
                    }
                    if (r != OK) { log.Add("WARN " + b.Exe + ": no longer found in NVIDIA profiles (" + r + ")"); continue; }
                    if (b.VsyncPresent && b.VsyncLocation == 0 && !b.VsyncPredefined)
                    {
                        IntPtr set = Alloc(SETTING_SIZE, 1);
                        try
                        {
                            Marshal.WriteInt32(set, 4100, (int)VSYNC_ID);
                            Marshal.WriteInt32(set, 4104, 0);              // NVDRS_DWORD_TYPE
                            Marshal.WriteInt32(set, 8220, (int)b.VsyncValue);
                            r = Fn<DSetSetting>(0x577DD202)(h, hp, set);
                        }
                        finally { Marshal.FreeHGlobal(set); }
                        log.Add(r == OK ? "OK  " + b.Exe + ": V-Sync set back to previous value" : "ERR " + b.Exe + ": SetSetting " + r);
                    }
                    else if (b.VsyncPresent && b.VsyncLocation == 0 && b.VsyncPredefined)
                    {
                        r = Fn<DProfileId>(0x53F0381E)(h, hp, VSYNC_ID);
                        log.Add(r == OK ? "OK  " + b.Exe + ": V-Sync reset to profile default" : "ERR " + b.Exe + ": RestoreProfileDefaultSetting " + r);
                    }
                    else
                    {
                        r = Fn<DProfileId>(0xE4A26362)(h, hp, VSYNC_ID);
                        log.Add((r == OK || r == -160) ? "OK  " + b.Exe + ": V-Sync override of the mod removed" : "ERR " + b.Exe + ": DeleteProfileSetting " + r);
                    }
                    changed = true;
                }
                if (changed)
                {
                    int r2 = Fn<DSession>(0xFCBC7E14)(h);
                    log.Add(r2 == OK ? "OK  NVIDIA settings saved" : "ERR NvAPI_DRS_SaveSettings: " + r2);
                }
            }
            finally { Close(h); }
            return log;
        }
    }
}
