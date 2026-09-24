// Fake tf.exe for the skill evals. It behaves like a TFVC *server workspace* client with no server:
// tracked files stay read-only until "checkout", new files are invisible until "add", and "checkin"
// makes everything read-only again. State lives next to the exe (the sandbox's tools\ folder):
//   tracked.txt   paths (relative to the sandbox root = parent of this folder) under source control
//   added.txt     pending adds
//   tf-calls.log  every invocation, one line each, exactly as received
// Build with Build-FakeTf.ps1 (uses the csc.exe that ships with .NET Framework 4.x on every Windows).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

static class FakeTf
{
    static string Dir  { get { return AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\'); } }
    static string Root { get { return Path.GetFullPath(Path.Combine(Dir, "..")); } }
    static string StateFile(string name) { return Path.Combine(Dir, name); }
    static List<string> ReadList(string name)
    {
        var f = StateFile(name);
        return File.Exists(f) ? File.ReadAllLines(f).Select(l => l.Trim()).Where(l => l != "").ToList() : new List<string>();
    }
    static void WriteList(string name, IEnumerable<string> items) { File.WriteAllLines(StateFile(name), items.ToArray()); }
    static string Full(string p) { return Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, p)); }
    static string Rel(string p)
    {
        var full = Full(p);
        return full.StartsWith(Root, StringComparison.OrdinalIgnoreCase) ? full.Substring(Root.Length).TrimStart('\\') : full;
    }
    static string Abs(string rel) { return Path.IsPathRooted(rel) ? rel : Path.Combine(Root, rel); }
    static bool Same(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
    static bool IsReadOnly(string abs) { return File.Exists(abs) && (File.GetAttributes(abs) & FileAttributes.ReadOnly) != 0; }
    static void SetReadOnly(string abs, bool ro)
    {
        if (!File.Exists(abs)) return;
        var a = File.GetAttributes(abs);
        File.SetAttributes(abs, ro ? (a | FileAttributes.ReadOnly) : (a & ~FileAttributes.ReadOnly));
    }
    static string Pad(string s) { return s.PadRight(26); }

    static int Main(string[] args)
    {
        File.AppendAllText(StateFile("tf-calls.log"), string.Join(" ", args) + Environment.NewLine);
        if (args.Length == 0 || Same(args[0], "help") || Same(args[0], "/?"))
        {
            Console.WriteLine("Microsoft (R) TF - Team Foundation Version Control Tool, Version 15.0 (eval fake)");
            Console.WriteLine("Commands: status checkout edit add checkin get undo workspaces shelve unshelve");
            return 0;
        }
        var verb  = args[0].ToLowerInvariant();
        var opts  = args.Skip(1).Where(a => a.StartsWith("/") || a.StartsWith("-")).ToList();
        var items = args.Skip(1).Where(a => !(a.StartsWith("/") || a.StartsWith("-"))).ToList();
        var tracked = ReadList("tracked.txt");
        var added   = ReadList("added.txt");

        switch (verb)
        {
            case "status":
            {
                var rows = new List<string>();
                foreach (var t in tracked) if (File.Exists(Abs(t)) && !IsReadOnly(Abs(t))) rows.Add(Pad(Path.GetFileName(t)) + "edit     " + Abs(t));
                foreach (var a in added) rows.Add(Pad(Path.GetFileName(a)) + "add      " + Abs(a));
                if (rows.Count == 0) { Console.WriteLine("There are no pending changes."); return 0; }
                Console.WriteLine(Pad("File name") + "Change   Local path");
                Console.WriteLine(new string('-', 26) + " -------- ----------");
                foreach (var r in rows) Console.WriteLine(r);
                Console.WriteLine();
                Console.WriteLine(rows.Count + " change(s)");
                return 0;
            }
            case "checkout":
            case "edit":
            {
                if (items.Count == 0) { Console.Error.WriteLine("An argument is required."); return 1; }
                foreach (var it in items)
                {
                    var rel = Rel(it);
                    var hit = tracked.FirstOrDefault(t => Same(t, rel));
                    if (hit == null)
                    {
                        Console.Error.WriteLine("The item " + Full(it) + " could not be found in your workspace, or you do not have permission to access it.");
                        return 1;
                    }
                    SetReadOnly(Abs(hit), false);
                    Console.WriteLine(Path.GetFileName(hit));
                }
                return 0;
            }
            case "add":
            {
                if (items.Count == 0) { Console.Error.WriteLine("An argument is required."); return 1; }
                foreach (var it in items)
                {
                    var rel = Rel(it);
                    if (!File.Exists(Abs(rel))) { Console.Error.WriteLine("The item " + it + " could not be found."); return 1; }
                    if (!added.Any(a => Same(a, rel)) && !tracked.Any(t => Same(t, rel))) added.Add(rel);
                    Console.WriteLine(Path.GetFileName(rel));
                }
                WriteList("added.txt", added);
                return 0;
            }
            case "checkin":
            {
                var comment = opts.FirstOrDefault(o => o.ToLowerInvariant().StartsWith("/comment:") || o.ToLowerInvariant().StartsWith("-comment:"));
                int n = 0;
                foreach (var t in tracked) if (File.Exists(Abs(t)) && !IsReadOnly(Abs(t))) { SetReadOnly(Abs(t), true); n++; }
                foreach (var a in added) { tracked.Add(a); SetReadOnly(Abs(a), true); n++; }
                WriteList("tracked.txt", tracked);
                WriteList("added.txt", new string[0]);
                if (n == 0) { Console.WriteLine("There are no remaining changes to check in."); return 0; }
                Console.WriteLine("Changeset #4711 checked in." + (comment != null ? "  Comment: " + comment.Substring(comment.IndexOf(':') + 1) : ""));
                return 0;
            }
            case "undo":
            {
                if (items.Count == 0) { Console.Error.WriteLine("An argument is required."); return 1; }
                foreach (var it in items)
                {
                    var rel = Rel(it);
                    if (tracked.Any(t => Same(t, rel))) { SetReadOnly(Abs(rel), true); Console.WriteLine("Undoing edit: " + Path.GetFileName(rel)); }
                    else if (added.RemoveAll(a => Same(a, rel)) > 0) Console.WriteLine("Undoing add: " + Path.GetFileName(rel));
                    else { Console.Error.WriteLine("No pending changes were found for " + it + "."); return 1; }
                }
                WriteList("added.txt", added);
                return 0;
            }
            case "get":
                Console.WriteLine("All files are up to date.");
                return 0;
            case "workspaces":
                Console.WriteLine("Collection: http://tfs2010:8080/tfs/DefaultCollection");
                Console.WriteLine("Workspace Owner  Computer Comment");
                Console.WriteLine("--------- ------ -------- ---------------------------");
                Console.WriteLine("LEGACY    gabi   DEVBOX   Location: Server");
                return 0;
            case "shelve":
                Console.WriteLine("Shelveset " + (items.FirstOrDefault() ?? "unnamed") + " created.");
                return 0;
            case "unshelve":
                Console.WriteLine("Unshelved " + (items.FirstOrDefault() ?? "unnamed") + ".");
                return 0;
            default:
                Console.Error.WriteLine("Unrecognized command '" + args[0] + "'.");
                return 100;
        }
    }
}
