using System.Globalization;
using System.Text.Json;

namespace DiskPilot;
public static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || args[0] is "help" or "--help") { Console.WriteLine(Help); return 0; }
            IBackend backend = OperatingSystem.IsWindows() ? new WindowsBackend() : OperatingSystem.IsLinux() ? new LinuxBackend() : throw new PlatformNotSupportedException();
            var action = args[0];
            var opts = Parse(args.Skip(1).ToArray());
            Safety.Require(new[] { "list", "show", "init", "create", "delete", "format" }.Contains(action), "Unknown command.");
            var allowed = action switch {
                "list" => new[] { "json" }, "show" => new[] { "disk", "json" },
                "create" => new[] { "disk", "fingerprint", "start-mib", "size-mib", "apply", "dry-run" },
                "format" => new[] { "disk", "fingerprint", "partition", "fs", "apply", "dry-run" },
                "delete" => new[] { "disk", "fingerprint", "partition", "apply", "dry-run" },
                _ => new[] { "disk", "fingerprint", "apply", "dry-run" }
            };
            Safety.Require(opts.Keys.All(allowed.Contains), "Unsupported option for this command.");
            string Need(string key) => opts.TryGetValue(key, out var v) ? v : throw new ArgumentException("Missing --" + key);
            long Number(string key) => long.Parse(Need(key), NumberStyles.None, CultureInfo.InvariantCulture);
            var disks = backend.Discover();
            if (action == "list") { Display(disks, opts.ContainsKey("json")); return 0; }
            var id = Need("disk");
            var disk = disks.SingleOrDefault(d => d.Id == id) ?? throw new ArgumentException("Disk not found. Use the exact ID from list.");
            if (action == "show") { Display([disk], opts.ContainsKey("json")); return 0; }
            Safety.Require(!(opts.ContainsKey("apply") && opts.ContainsKey("dry-run")), "--apply and --dry-run conflict.");
            var request = new Request(action, id, Need("fingerprint"), action is "delete" or "format" ? checked((int)Number("partition")) : 0,
                action == "create" ? Number("start-mib") : 0, action == "create" ? Number("size-mib") : 0,
                action == "format" ? Need("fs").ToLowerInvariant() : "", opts.ContainsKey("apply"));
            Safety.Validate(disk, request);
            var plan = backend.Plan(disk, request);
            Display([disk], false);
            Console.WriteLine($"Operation: {action}; partition: {request.Partition}; start/size MiB: {request.StartMiB}/{request.SizeMiB}; filesystem: {request.FileSystem}");
            Console.WriteLine("Native plan: " + (backend is WindowsBackend ? WindowsBackend.Describe(request) : plan));
            if (!request.Apply) { Console.WriteLine("DRY RUN: no changes made. Add --apply to request an interactive confirmation."); return 0; }
            Safety.Require(backend.IsAdmin(), "Run elevated as Administrator/root to apply changes.");
            Safety.Require(!Console.IsInputRedirected, "Applying requires an interactive terminal. Piped confirmation is refused.");
            var phrase = $"ERASE {disk.Id} {disk.Fingerprint} {action}";
            Console.WriteLine("This can permanently destroy data. Check model, size, serial/identity and partition above.");
            Console.WriteLine("Type exactly: " + phrase);
            Safety.Require(Console.ReadLine() == phrase, "Confirmation did not match; no changes made.");
            var current = backend.Discover().Single(d => d.Id == disk.Id);
            Safety.Unchanged(disk, current); Safety.Validate(current, request);
            try { backend.Execute(current, request, plan); }
            catch { Console.Error.WriteLine("Native operation failed. The disk may already have changed; inspect its layout before retrying. No automatic rollback is attempted."); throw; }
            Console.WriteLine("Native operation completed. Refreshed layout:");
            Display(backend.Discover().Where(d => d.Id == id).ToList(), false);
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine("ERROR: " + ex.Message); return 1; }
    }
    public static Dictionary<string, string> Parse(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Length; i++)
        {
            Safety.Require(args[i].StartsWith("--", StringComparison.Ordinal), "Expected --option.");
            var key = args[i][2..];
            var value = key is "apply" or "dry-run" or "json" ? "true" : ++i < args.Length ? args[i] : throw new ArgumentException("Missing option value.");
            Safety.Require(!value.StartsWith("--", StringComparison.Ordinal) && result.TryAdd(key, value), "Missing value or duplicate option.");
        }
        return result;
    }
    static void Display(List<Disk> disks, bool json)
    {
        if (json) { Console.WriteLine(JsonSerializer.Serialize(disks, new JsonSerializerOptions { WriteIndented = true })); return; }
        foreach (var d in disks)
        {
            // JSON quoting keeps untrusted device labels from injecting terminal control sequences.
            Console.WriteLine($"\nDisk {JsonSerializer.Serialize(d.Id)}  {d.Size / (double)Safety.MiB:F0} MiB  {JsonSerializer.Serialize(d.Model)}  {d.Bus}  {d.Table}");
            Console.WriteLine("Identity: " + JsonSerializer.Serialize(d.Identity));
            Console.WriteLine("Fingerprint: " + d.Fingerprint);
            Console.WriteLine("Protection: " + JsonSerializer.Serialize(d.Blocks) + (d.ReadOnly ? " READ-ONLY" : ""));
            foreach (var p in d.Partitions) Console.WriteLine($"  #{p.Number} offset={p.Offset} size={p.Size} bytes fs={JsonSerializer.Serialize(p.FileSystem)} type={JsonSerializer.Serialize(p.Type)} mounts={JsonSerializer.Serialize(p.Mounts)}");
        }
    }
    const string Help = """
DiskPilot — conservative native partition management (.NET 10)
  list [--json]
  show --disk ID [--json]
  init --disk ID --fingerprint HASH [--apply | --dry-run]
  create --disk ID --fingerprint HASH --start-mib N --size-mib N [--apply | --dry-run]
  delete --disk ID --fingerprint HASH --partition N [--apply | --dry-run]
  format --disk ID --fingerprint HASH --partition N --fs ext4|exfat|fat32|ntfs [--apply | --dry-run]
All changes default to dry-run. Windows supports ntfs/exfat/fat32; Linux also ext4.
init creates GPT on an uninitialized disk only. MBR layouts are read-only.
Writes require an unused non-system disk and interactive confirmation. See README.
""";
}
