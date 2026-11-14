using System.Text;
using System.Text.Json;

namespace DiskPilot;
public sealed class WindowsBackend : IBackend
{
    static string Script
    {
        get { using var s = typeof(WindowsBackend).Assembly.GetManifestResourceStream("DiskPilot.windows.ps1")!; using var r = new StreamReader(s); return r.ReadToEnd(); }
    }
    static Command PowerShell(string script) => new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))]);
    public List<Disk> Discover() => JsonSerializer.Deserialize<List<Disk>>(Runner.Run(PowerShell(Script + "\nConvertTo-Json -InputObject @(Get-Inventory) -Depth 8 -Compress")), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new IOException("No inventory returned.");
    public bool IsAdmin() => Runner.Run(PowerShell("([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)")).Trim() == "True";
    public static string Describe(Request r) => r.Action switch {
        "init" => "Initialize-Disk -PartitionStyle GPT",
        "create" => $"New-Partition -Offset {r.StartMiB * Safety.MiB} -Size {r.SizeMiB * Safety.MiB}",
        "delete" => $"Remove-Partition -PartitionNumber {r.Partition}",
        _ => $"Format-Volume -FileSystem {r.FileSystem} (selected partition only)"
    };
    public Command Plan(Disk disk, Request r)
    {
        Safety.Require(r.Action != "format" || new[] { "ntfs", "exfat", "fat32" }.Contains(r.FileSystem), "Windows supports ntfs, exfat, fat32.");
        // Base64 JSON avoids interpolating disk metadata or user strings as PowerShell code.
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { Disk = disk, Request = r })));
        return PowerShell(Script + "\nInvoke-Change '" + payload + "'");
    }
    public void Execute(Disk disk, Request request, Command command) => Console.WriteLine(Runner.Run(command));
}
