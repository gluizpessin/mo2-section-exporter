using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        string path = Path.Combine(Path.GetTempPath(), "MO2-Exporter-" + Guid.NewGuid().ToString("N") + ".ps1");
        try
        {
            using (Stream script = Assembly.GetExecutingAssembly().GetManifestResourceStream("ExporterScript"))
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write))
                script.CopyTo(output);
            string executable = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo(executable, "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + path + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.EnvironmentVariables["MO2_EXPORTER_EXE_PATH"] = Assembly.GetExecutingAssembly().Location;
            using (Process exporter = Process.Start(start))
            {
                exporter.WaitForExit();
                if (exporter.ExitCode != 0)
                    MessageBox.Show("The exporter closed with error code " + exporter.ExitCode + ".", "MO2 Section Exporter");
                return exporter.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "MO2 Section Exporter");
            return 1;
        }
        finally
        {
            try { File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}