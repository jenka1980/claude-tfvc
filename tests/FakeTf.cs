// tests/FakeTf.cs - fake tf.exe for tests/test-hook.ps1 and tests/test-relay.ps1.
// Logs every call next to the exe and reacts to a few control arguments:
//   /exit:N        exit with code N (default 0)          /sleep:N      sleep N seconds first
//   /stdout:TEXT   write TEXT + newline to stdout         /stderr:TEXT  write TEXT + newline to stderr
//   /ansi          write Sample + newline to stdout as raw bytes in the system ANSI code page (what tf.exe does)
//   /big           write 300 KB to stdout and 300 KB to stderr, interleaved (pipe-buffer deadlock check)
// Logs (UTF-8, no BOM):
//   tf-calls.log   one line per call: "<tag> " + arguments joined by one space; <tag> = content of <exe>.tag if present
//   tf-args.log    "--- call ---" then every argument on its own line
// Build: csc.exe /nologo /target:exe /out:<dir>\tf.exe tests\FakeTf.cs   (csc ships with .NET Framework 4.x)
using System;
using System.IO;
using System.Text;
using System.Threading;

static class FakeTf
{
    public const string Sample = "shalom-\u05E9\u05DC\u05D5\u05DD-privet-\u041F\u0440\u0438\u0432\u0435\u0442";

    static void Append(string path, string text)
    {
        for (int i = 0; ; i++)
        {
            try { File.AppendAllText(path, text, new UTF8Encoding(false)); return; }
            catch (IOException) { if (i >= 20) throw; Thread.Sleep(25); }
        }
    }

    static int Main(string[] args)
    {
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string dir = Path.GetDirectoryName(exe);
        string tag = File.Exists(exe + ".tag") ? File.ReadAllText(exe + ".tag").Trim() + " " : "";
        Append(Path.Combine(dir, "tf-calls.log"), tag + string.Join(" ", args) + Environment.NewLine);
        var sb = new StringBuilder("--- call ---" + Environment.NewLine);
        foreach (var a in args) sb.Append(a).Append(Environment.NewLine);
        Append(Path.Combine(dir, "tf-args.log"), sb.ToString());

        int exit = 0;
        foreach (var a in args)
        {
            if (a.StartsWith("/exit:", StringComparison.OrdinalIgnoreCase)) exit = int.Parse(a.Substring(6));
            else if (a.StartsWith("/sleep:", StringComparison.OrdinalIgnoreCase)) Thread.Sleep(int.Parse(a.Substring(7)) * 1000);
            else if (a.StartsWith("/stdout:", StringComparison.OrdinalIgnoreCase)) Console.Out.WriteLine(a.Substring(8));
            else if (a.StartsWith("/stderr:", StringComparison.OrdinalIgnoreCase)) Console.Error.WriteLine(a.Substring(8));
            else if (a.Equals("/ansi", StringComparison.OrdinalIgnoreCase))
            {
                byte[] bytes = Encoding.Default.GetBytes(Sample + Environment.NewLine);
                Stream o = Console.OpenStandardOutput(); o.Write(bytes, 0, bytes.Length); o.Flush();
            }
            else if (a.Equals("/big", StringComparison.OrdinalIgnoreCase))
            {
                string line = new string('x', 99) + Environment.NewLine;           // 101 bytes
                for (int i = 0; i < 3000; i++) { Console.Out.Write(line); Console.Error.Write(line); }
            }
        }
        return exit;
    }
}
