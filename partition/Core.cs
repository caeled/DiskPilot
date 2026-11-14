using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DiskPilot;

public sealed record Partition(int Number, string Path, long Offset, long Size, string FileSystem, string Type, string[] Mounts);
public sealed record Disk(string Id, string Identity, string Model, long Size, string Table, string Bus,
    bool ReadOnly, string[] Blocks, Partition[] Partitions)
{
    public string Fingerprint => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        JsonSerializer.Serialize(new { Id, Identity, Model, Size }))));
    [System.Text.Json.Serialization.JsonIgnore]
    public string Snapshot => JsonSerializer.Serialize(this);
}
public sealed record Request(string Action, string DiskId, string Fingerprint, int Partition, long StartMiB, long SizeMiB, string FileSystem, bool Apply);
public sealed record Command(string File, string[] Args)
{
    public override string ToString() => File + " " + string.Join(" ", Args.Select(a => JsonSerializer.Serialize(a)));
}
public interface IBackend
{
    List<Disk> Discover();
    bool IsAdmin();
    Command Plan(Disk disk, Request request);
    void Execute(Disk disk, Request request, Command command);
}
public static class Safety
{
    public const long MiB = 1024 * 1024;
    public static bool IsDataType(string type) => type.Trim('{', '}').ToLowerInvariant() is
        "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" or "0fc63daf-8483-4772-8e79-3d69d8477de4";
    public static void Require(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
    public static void Validate(Disk disk, Request r)
    {
        Require(disk.Id == r.DiskId && disk.Fingerprint == r.Fingerprint, "Disk fingerprint does not match. Run list again.");
        Require(!string.IsNullOrWhiteSpace(disk.Identity.Trim('|', ' ')), "No reliable device identity; writes refused.");
        Require(!disk.ReadOnly && disk.Blocks.Length == 0, "Disk is protected: " + string.Join("; ", disk.Blocks));
        Require(disk.Partitions.All(p => p.Mounts.Length == 0), "Unmount every partition on this disk first.");
        if (r.Action == "init")
        {
            Require(disk.Table is "" or "raw", "Initialization only supports uninitialized disks.");
            Require(disk.Partitions.Length == 0, "Initialization requires an empty disk.");
            return;
        }
        Require(disk.Table == "gpt", "Only GPT disks can be modified. MBR is discovery-only.");
        if (r.Action == "create")
        {
            Require(r.StartMiB >= 1 && r.SizeMiB >= 1, "Start and size must be positive whole MiB.");
            long start = checked(r.StartMiB * MiB), end = checked(start + r.SizeMiB * MiB);
            Require(end <= disk.Size - MiB, "Leave at least 1 MiB at the end for GPT metadata.");
            Require(disk.Partitions.All(p => end <= p.Offset || start >= checked(p.Offset + p.Size)), "Requested region overlaps an existing partition.");
        }
        else
        {
            Require(r.Action is "delete" or "format", "Unknown operation.");
            Require(r.Partition > 0 && disk.Partitions.Count(p => p.Number == r.Partition) == 1, "Partition does not exist on selected disk.");
            Require(IsDataType(disk.Partitions.Single(p => p.Number == r.Partition).Type), "Only ordinary data partitions may be deleted or formatted.");
        }
    }
    public static void Unchanged(Disk before, Disk after) => Require(before.Snapshot == after.Snapshot,
        "Device identity, layout or usage changed during confirmation. Aborting; inspect again.");
}
public static class Runner
{
    public static string Run(Command command)
    {
        var info = new ProcessStartInfo(command.File) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var arg in command.Args) info.ArgumentList.Add(arg);
        info.Environment["LC_ALL"] = "C";
        using var p = Process.Start(info) ?? throw new IOException("Could not start " + command.File);
        // Native tools must fail rather than wait for a hidden terminal prompt in the GUI.
        p.StandardInput.Close();
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        // Do not kill a filesystem operation halfway through on an arbitrary timeout.
        p.WaitForExit(); Task.WaitAll(stdout, stderr);
        if (p.ExitCode != 0) throw new IOException($"{Path.GetFileName(command.File)} failed ({p.ExitCode}): {stderr.Result} {stdout.Result}");
        if (!string.IsNullOrWhiteSpace(stderr.Result)) Console.Error.WriteLine(stderr.Result.Trim());
        return stdout.Result;
    }
}
