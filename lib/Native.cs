// R.E.A.L. Mod Manager - native helpers (C# 5 compatible, compiled at runtime via Add-Type)
// Snapshots for registry and file system, diff, and registry restore.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
using Microsoft.Win32;

namespace RVM
{
    public class DiffEntry
    {
        public static string TxtAdded = "Neu", TxtRemoved = "Entfernt", TxtChanged = "Geaendert", TxtKey = "[Key]", TxtDefault = "(Default)";
        public string Key { get; set; }
        public string Change { get; set; }   // Added | Removed | Changed
        public string Before { get; set; }
        public string After { get; set; }

        public bool IsValue { get { return Key != null && Key.IndexOf('\0') >= 0; } }
        public string KeyPath
        {
            get
            {
                if (Key == null) return null;
                int i = Key.IndexOf('\0');
                return i < 0 ? Key : Key.Substring(0, i);
            }
        }
        public string ValueName
        {
            get
            {
                if (Key == null) return null;
                int i = Key.IndexOf('\0');
                return i < 0 ? null : Key.Substring(i + 1);
            }
        }
        public string ValueDisplay
        {
            get
            {
                if (!IsValue) return TxtKey;
                string n = ValueName;
                return string.IsNullOrEmpty(n) ? TxtDefault : n;
            }
        }
        public string ChangeDisplay
        {
            get
            {
                if (Change == "Added") return TxtAdded;
                if (Change == "Removed") return TxtRemoved;
                return TxtChanged;
            }
        }
        public string BeforeDisplay { get { return Short(Before); } }
        public string AfterDisplay { get { return Short(After); } }

        private static string Short(string s)
        {
            if (s == null) return "";
            s = s.Replace("\0", " | ");
            if (s.Length > 200) s = s.Substring(0, 200) + "...";
            return s;
        }
    }

    public class SnapData
    {
        public Dictionary<string, string> Meta = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string> Entries = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public List<string> Errors = new List<string>();
        public int Count { get { return Entries.Count; } }
    }

    public static class Esc
    {
        public static string Encode(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char c in s)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\0': sb.Append("\\0"); break;
                    default: sb.Append(c); break;
                }
            }
            return sb.ToString();
        }

        public static string Decode(string s)
        {
            if (s == null) return null;
            StringBuilder sb = new StringBuilder(s.Length);
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '\\' && i + 1 < s.Length)
                {
                    char n = s[++i];
                    switch (n)
                    {
                        case 't': sb.Append('\t'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case '0': sb.Append('\0'); break;
                        default: sb.Append(n); break;
                    }
                }
                else sb.Append(c);
            }
            return sb.ToString();
        }

        public static string EncodeNullable(string s) { return s == null ? "-" : "+" + Encode(s); }
        public static string DecodeNullable(string s)
        {
            if (string.IsNullOrEmpty(s) || s[0] == '-') return null;
            return Decode(s.Substring(1));
        }
    }

    public static class SnapIO
    {
        private const string Magic = "RVMSNAP\t1";
        private const string DiffMagic = "RVMDIFF\t1";

        private static StreamWriter OpenWriter(string path)
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
            GZipStream gz = new GZipStream(fs, CompressionMode.Compress);
            return new StreamWriter(gz, new UTF8Encoding(false));
        }

        private static StreamReader OpenReader(string path)
        {
            FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            GZipStream gz = new GZipStream(fs, CompressionMode.Decompress);
            return new StreamReader(gz, new UTF8Encoding(false));
        }

        public static void Save(string path, SnapData d)
        {
            using (StreamWriter w = OpenWriter(path))
            {
                w.Write(Magic); w.Write('\n');
                foreach (KeyValuePair<string, string> kv in d.Meta)
                {
                    w.Write("M\t"); w.Write(Esc.Encode(kv.Key)); w.Write('\t'); w.Write(Esc.Encode(kv.Value)); w.Write('\n');
                }
                foreach (KeyValuePair<string, string> kv in d.Entries)
                {
                    w.Write("E\t"); w.Write(Esc.Encode(kv.Key)); w.Write('\t'); w.Write(Esc.Encode(kv.Value)); w.Write('\n');
                }
            }
        }

        public static SnapData Load(string path)
        {
            SnapData d = new SnapData();
            using (StreamReader r = OpenReader(path))
            {
                string first = r.ReadLine();
                if (first != Magic) throw new InvalidDataException("Not a valid snapshot file: " + path);
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    if (line.Length < 2) continue;
                    string[] p = line.Split('\t');
                    if (p.Length < 3) continue;
                    if (p[0] == "M") d.Meta[Esc.Decode(p[1])] = Esc.Decode(p[2]);
                    else if (p[0] == "E") d.Entries[Esc.Decode(p[1])] = Esc.Decode(p[2]);
                }
            }
            return d;
        }

        public static Dictionary<string, string> LoadMeta(string path)
        {
            Dictionary<string, string> meta = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (StreamReader r = OpenReader(path))
            {
                string first = r.ReadLine();
                if (first != Magic) throw new InvalidDataException("Not a valid snapshot file: " + path);
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    if (!line.StartsWith("M\t")) break;
                    string[] p = line.Split('\t');
                    if (p.Length >= 3) meta[Esc.Decode(p[1])] = Esc.Decode(p[2]);
                }
            }
            return meta;
        }

        public static void SaveDiffs(string path, List<DiffEntry> diffs)
        {
            using (StreamWriter w = OpenWriter(path))
            {
                w.Write(DiffMagic); w.Write('\n');
                foreach (DiffEntry e in diffs)
                {
                    w.Write("D\t"); w.Write(e.Change); w.Write('\t'); w.Write(Esc.Encode(e.Key)); w.Write('\t');
                    w.Write(Esc.EncodeNullable(e.Before)); w.Write('\t'); w.Write(Esc.EncodeNullable(e.After)); w.Write('\n');
                }
            }
        }

        public static List<DiffEntry> LoadDiffs(string path)
        {
            List<DiffEntry> list = new List<DiffEntry>();
            using (StreamReader r = OpenReader(path))
            {
                string first = r.ReadLine();
                if (first != DiffMagic) throw new InvalidDataException("Not a valid diff file: " + path);
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    string[] p = line.Split('\t');
                    if (p.Length < 5 || p[0] != "D") continue;
                    DiffEntry e = new DiffEntry();
                    e.Change = p[1];
                    e.Key = Esc.Decode(p[2]);
                    e.Before = Esc.DecodeNullable(p[3]);
                    e.After = Esc.DecodeNullable(p[4]);
                    list.Add(e);
                }
            }
            return list;
        }
    }

    public static class Differ
    {
        public static List<DiffEntry> Compare(Dictionary<string, string> before, Dictionary<string, string> after)
        {
            List<DiffEntry> list = new List<DiffEntry>();
            foreach (KeyValuePair<string, string> kv in before)
            {
                string av;
                if (!after.TryGetValue(kv.Key, out av))
                {
                    DiffEntry e = new DiffEntry(); e.Key = kv.Key; e.Change = "Removed"; e.Before = kv.Value; e.After = null; list.Add(e);
                }
                else if (!string.Equals(av, kv.Value, StringComparison.Ordinal))
                {
                    DiffEntry e = new DiffEntry(); e.Key = kv.Key; e.Change = "Changed"; e.Before = kv.Value; e.After = av; list.Add(e);
                }
            }
            foreach (KeyValuePair<string, string> kv in after)
            {
                if (!before.ContainsKey(kv.Key))
                {
                    DiffEntry e = new DiffEntry(); e.Key = kv.Key; e.Change = "Added"; e.Before = null; e.After = kv.Value; list.Add(e);
                }
            }
            list.Sort(delegate (DiffEntry a, DiffEntry b) { return StringComparer.OrdinalIgnoreCase.Compare(a.Key, b.Key); });
            return list;
        }
    }

    public static class FileCapture
    {
        // Entry value: "F|size|mtimeUtcTicks" for files, "D" for directories. Keys are paths relative to root.
        public static SnapData Capture(string root, bool recursive, int maxDepth)
        {
            SnapData d = new SnapData();
            d.Meta["Type"] = "Files";
            d.Meta["Root"] = root;
            d.Meta["Recursive"] = recursive ? "1" : "0";
            d.Meta["Created"] = DateTime.Now.ToString("s");
            if (!Directory.Exists(root)) { d.Meta["Exists"] = "0"; return d; }
            d.Meta["Exists"] = "1";
            Walk(d, root, root, recursive, 0, maxDepth);
            return d;
        }

        private static string Rel(string root, string full)
        {
            string r = full.Substring(root.Length);
            return r.TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static void Walk(SnapData d, string root, string dir, bool recursive, int depth, int maxDepth)
        {
            string[] files;
            try { files = Directory.GetFiles(dir); }
            catch (Exception ex) { d.Errors.Add(dir + ": " + ex.Message); return; }
            foreach (string f in files)
            {
                try
                {
                    FileInfo fi = new FileInfo(f);
                    d.Entries[Rel(root, f)] = "F|" + fi.Length.ToString() + "|" + fi.LastWriteTimeUtc.Ticks.ToString();
                }
                catch (Exception ex) { d.Errors.Add(f + ": " + ex.Message); }
            }
            if (!recursive) return;
            if (maxDepth > 0 && depth >= maxDepth) return;
            string[] dirs;
            try { dirs = Directory.GetDirectories(dir); }
            catch (Exception ex) { d.Errors.Add(dir + ": " + ex.Message); return; }
            foreach (string sub in dirs)
            {
                try
                {
                    DirectoryInfo di = new DirectoryInfo(sub);
                    if ((di.Attributes & FileAttributes.ReparsePoint) != 0) { d.Entries[Rel(root, sub)] = "L"; continue; }
                }
                catch (Exception ex) { d.Errors.Add(sub + ": " + ex.Message); continue; }
                d.Entries[Rel(root, sub)] = "D";
                Walk(d, root, sub, recursive, depth + 1, maxDepth);
            }
        }
    }

    public static class RegCapture
    {
        public static RegistryKey OpenBase(string hive)
        {
            string h = hive.ToUpperInvariant();
            RegistryHive rh;
            if (h == "HKCU" || h == "HKEY_CURRENT_USER") rh = RegistryHive.CurrentUser;
            else if (h == "HKLM" || h == "HKEY_LOCAL_MACHINE") rh = RegistryHive.LocalMachine;
            else if (h == "HKCR" || h == "HKEY_CLASSES_ROOT") rh = RegistryHive.ClassesRoot;
            else if (h == "HKU" || h == "HKEY_USERS") rh = RegistryHive.Users;
            else throw new ArgumentException("Unknown registry hive: " + hive);
            return RegistryKey.OpenBaseKey(rh, RegistryView.Registry64);
        }

        public static string NormalizeHive(string path)
        {
            if (path == null) return null;
            int i = path.IndexOf('\\');
            string hive = i < 0 ? path : path.Substring(0, i);
            string rest = i < 0 ? "" : path.Substring(i);
            string h = hive.ToUpperInvariant();
            if (h == "HKEY_CURRENT_USER") hive = "HKCU";
            else if (h == "HKEY_LOCAL_MACHINE") hive = "HKLM";
            else if (h == "HKEY_CLASSES_ROOT") hive = "HKCR";
            else if (h == "HKEY_USERS") hive = "HKU";
            else hive = h;
            return hive + rest;
        }

        private static void SplitPath(string path, out string hive, out string sub)
        {
            path = NormalizeHive(path);
            int i = path.IndexOf('\\');
            if (i < 0) { hive = path; sub = ""; }
            else { hive = path.Substring(0, i); sub = path.Substring(i + 1); }
        }

        public static string EncodeValue(RegistryValueKind kind, object v)
        {
            string data;
            switch (kind)
            {
                case RegistryValueKind.String:
                case RegistryValueKind.ExpandString:
                    data = v == null ? "" : v.ToString(); break;
                case RegistryValueKind.DWord:
                    data = v == null ? "0" : unchecked((uint)Convert.ToInt32(v)).ToString(); break;
                case RegistryValueKind.QWord:
                    data = v == null ? "0" : unchecked((ulong)Convert.ToInt64(v)).ToString(); break;
                case RegistryValueKind.MultiString:
                    data = v == null ? "" : string.Join("\0", (string[])v); break;
                default:
                    byte[] b = v as byte[];
                    data = b == null ? "" : BitConverter.ToString(b).Replace("-", ""); break;
            }
            return kind.ToString() + ":" + data;
        }

        public static bool DecodeValue(string enc, out RegistryValueKind kind, out object value)
        {
            kind = RegistryValueKind.Unknown; value = null;
            if (enc == null) return false;
            int i = enc.IndexOf(':');
            if (i < 0) return false;
            string k = enc.Substring(0, i);
            string data = enc.Substring(i + 1);
            try { kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), k); }
            catch { return false; }
            switch (kind)
            {
                case RegistryValueKind.String:
                case RegistryValueKind.ExpandString:
                    value = data; return true;
                case RegistryValueKind.DWord:
                    value = unchecked((int)uint.Parse(data)); return true;
                case RegistryValueKind.QWord:
                    value = unchecked((long)ulong.Parse(data)); return true;
                case RegistryValueKind.MultiString:
                    value = data.Length == 0 ? new string[0] : data.Split('\0'); return true;
                case RegistryValueKind.Binary:
                case RegistryValueKind.None:
                    byte[] b = new byte[data.Length / 2];
                    for (int j = 0; j < b.Length; j++) b[j] = Convert.ToByte(data.Substring(j * 2, 2), 16);
                    value = b; return true;
                default:
                    return false; // Unknown kinds cannot be written back via .NET
            }
        }

        public static SnapData Capture(string[] roots)
        {
            SnapData d = new SnapData();
            d.Meta["Type"] = "Registry";
            d.Meta["Roots"] = string.Join("|", roots);
            d.Meta["Created"] = DateTime.Now.ToString("s");
            d.Meta["Machine"] = Environment.MachineName;
            d.Meta["User"] = Environment.UserName;
            foreach (string root0 in roots)
            {
                string root = NormalizeHive(root0);
                string hive, sub;
                SplitPath(root, out hive, out sub);
                RegistryKey bk = null;
                try
                {
                    bk = OpenBase(hive);
                    RegistryKey k = sub.Length == 0 ? bk : bk.OpenSubKey(sub, false);
                    if (k == null) { d.Meta["Missing:" + root] = "1"; continue; }
                    Walk(d, k, root);
                    if (k != bk) k.Close();
                }
                catch (Exception ex) { d.Errors.Add(root + ": " + ex.Message); }
                finally { if (bk != null) bk.Close(); }
            }
            return d;
        }

        private static void Walk(SnapData d, RegistryKey k, string path)
        {
            d.Entries[path] = "K";
            string[] names;
            try { names = k.GetValueNames(); }
            catch (Exception ex) { d.Errors.Add(path + ": " + ex.Message); names = new string[0]; }
            foreach (string n in names)
            {
                try
                {
                    RegistryValueKind kind = k.GetValueKind(n);
                    object v = k.GetValue(n, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    d.Entries[path + "\0" + n] = EncodeValue(kind, v);
                }
                catch (Exception ex) { d.Errors.Add(path + "\\" + n + ": " + ex.Message); }
            }
            string[] subs;
            try { subs = k.GetSubKeyNames(); }
            catch (Exception ex) { d.Errors.Add(path + ": " + ex.Message); return; }
            foreach (string s in subs)
            {
                RegistryKey sk = null;
                try
                {
                    sk = k.OpenSubKey(s, false);
                    if (sk == null) continue;
                    Walk(d, sk, path + "\\" + s);
                }
                catch (Exception ex) { d.Errors.Add(path + "\\" + s + ": " + ex.Message); }
                finally { if (sk != null) sk.Close(); }
            }
        }

        private static int Depth(string p) { int n = 0; foreach (char c in p) if (c == '\\') n++; return n; }

        // Reverts the given diffs (computed as before -> after) so that the registry matches "before" again.
        public static List<string> Restore(List<DiffEntry> diffs)
        {
            List<string> log = new List<string>();
            List<DiffEntry> keysToCreate = new List<DiffEntry>();
            List<DiffEntry> keysToDelete = new List<DiffEntry>();
            List<DiffEntry> values = new List<DiffEntry>();
            foreach (DiffEntry e in diffs)
            {
                if (e.IsValue) values.Add(e);
                else if (e.Change == "Removed") keysToCreate.Add(e);
                else if (e.Change == "Added") keysToDelete.Add(e);
            }
            keysToCreate.Sort(delegate (DiffEntry a, DiffEntry b) { return Depth(a.Key).CompareTo(Depth(b.Key)); });
            keysToDelete.Sort(delegate (DiffEntry a, DiffEntry b) { return Depth(b.Key).CompareTo(Depth(a.Key)); });

            foreach (DiffEntry e in keysToCreate)
            {
                try
                {
                    string hive, sub; SplitPath(e.Key, out hive, out sub);
                    using (RegistryKey bk = OpenBase(hive)) using (RegistryKey k = bk.CreateSubKey(sub)) { }
                    log.Add("OK  registry key restored: " + e.Key);
                }
                catch (Exception ex) { log.Add("ERR registry key " + e.Key + ": " + ex.Message); }
            }
            foreach (DiffEntry e in values)
            {
                string hive, sub; SplitPath(e.KeyPath, out hive, out sub);
                string name = e.ValueName;
                try
                {
                    using (RegistryKey bk = OpenBase(hive))
                    {
                        if (e.Change == "Added")
                        {
                            using (RegistryKey k = bk.OpenSubKey(sub, true))
                            {
                                if (k != null) k.DeleteValue(name, false);
                            }
                            log.Add("OK  registry value removed: " + e.KeyPath + " -> " + name);
                        }
                        else
                        {
                            RegistryValueKind kind; object val;
                            if (!DecodeValue(e.Before, out kind, out val))
                            {
                                log.Add("ERR registry value type cannot be restored: " + e.KeyPath + " -> " + name);
                                continue;
                            }
                            using (RegistryKey k = bk.CreateSubKey(sub))
                            {
                                k.SetValue(name, val, kind);
                            }
                            log.Add("OK  registry value restored: " + e.KeyPath + " -> " + name);
                        }
                    }
                }
                catch (Exception ex) { log.Add("ERR registry value " + e.KeyPath + " -> " + name + ": " + ex.Message); }
            }
            foreach (DiffEntry e in keysToDelete)
            {
                try
                {
                    string hive, sub; SplitPath(e.Key, out hive, out sub);
                    if (sub.Length == 0) { log.Add("ERR hive root is never deleted: " + e.Key); continue; }
                    using (RegistryKey bk = OpenBase(hive)) { bk.DeleteSubKeyTree(sub, false); }
                    log.Add("OK  registry key removed: " + e.Key);
                }
                catch (Exception ex) { log.Add("ERR registry key " + e.Key + ": " + ex.Message); }
            }
            return log;
        }

        public static bool KeyExists(string path)
        {
            string hive, sub; SplitPath(path, out hive, out sub);
            using (RegistryKey bk = OpenBase(hive))
            {
                if (sub.Length == 0) return true;
                using (RegistryKey k = bk.OpenSubKey(sub, false)) { return k != null; }
            }
        }

        public static string[] GetValueNames(string path)
        {
            string hive, sub; SplitPath(path, out hive, out sub);
            using (RegistryKey bk = OpenBase(hive))
            using (RegistryKey k = sub.Length == 0 ? null : bk.OpenSubKey(sub, false))
            {
                if (k == null) return new string[0];
                return k.GetValueNames();
            }
        }

        public static void DeleteValue(string path, string name)
        {
            string hive, sub; SplitPath(path, out hive, out sub);
            using (RegistryKey bk = OpenBase(hive))
            using (RegistryKey k = bk.OpenSubKey(sub, true))
            {
                if (k != null) k.DeleteValue(name, false);
            }
        }
    }

    public static class DirSearch
    {
        // Sucht unterhalb von root nach Ordnern, die eine der Dateien (Muster, * und ? erlaubt) enthalten.
        // Liefert alle Treffer-Ordner in Breitensuche-Reihenfolge (flachste zuerst).
        public static List<string> FindDirsWithFiles(string root, int maxDepth, int maxDirs, string[] skipNames, string[] patterns)
        {
            List<string> hits = new List<string>();
            if (!Directory.Exists(root)) return hits;
            Dictionary<string, bool> skip = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (string sn in skipNames) skip[sn] = true;
            Dictionary<string, bool> exact = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            List<System.Text.RegularExpressions.Regex> wild = new List<System.Text.RegularExpressions.Regex>();
            foreach (string p in patterns)
            {
                if (p.IndexOf('*') >= 0 || p.IndexOf('?') >= 0)
                {
                    string rx = "^" + System.Text.RegularExpressions.Regex.Escape(p).Replace("\\*", ".*").Replace("\\?", ".") + "$";
                    wild.Add(new System.Text.RegularExpressions.Regex(rx, System.Text.RegularExpressions.RegexOptions.IgnoreCase));
                }
                else exact[p] = true;
            }
            Queue<KeyValuePair<string, int>> q = new Queue<KeyValuePair<string, int>>();
            q.Enqueue(new KeyValuePair<string, int>(root, 0));
            int visited = 0;
            while (q.Count > 0 && visited < maxDirs)
            {
                KeyValuePair<string, int> it = q.Dequeue();
                visited++;
                bool hit = false;
                try
                {
                    foreach (string f in Directory.GetFiles(it.Key))
                    {
                        string n = Path.GetFileName(f);
                        if (exact.ContainsKey(n)) { hit = true; break; }
                        foreach (System.Text.RegularExpressions.Regex r in wild) { if (r.IsMatch(n)) { hit = true; break; } }
                        if (hit) break;
                    }
                }
                catch { continue; }
                if (hit) hits.Add(it.Key);   // weitersuchen: z.B. Hogwarts hat einen Launcher im Hauptordner, die echte EXE liegt tiefer
                if (it.Value >= maxDepth) continue;
                string[] subs;
                try { subs = Directory.GetDirectories(it.Key); } catch { continue; }
                foreach (string sd in subs)
                {
                    string leaf = Path.GetFileName(sd);
                    if (skip.ContainsKey(leaf) || leaf.StartsWith("$") || leaf.StartsWith(".")) continue;
                    try { if ((File.GetAttributes(sd) & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; }
                    q.Enqueue(new KeyValuePair<string, int>(sd, it.Value + 1));
                }
            }
            return hits;
        }
    }
}
