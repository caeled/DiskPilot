using System.Text.Json;

namespace DiskPilot;
public sealed class LinuxBackend(Func<string, string>? toolResolver = null) : IBackend
{
    const string Basic = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7";
    const string LinuxData = "0fc63daf-8483-4772-8e79-3d69d8477de4";
    string Tool(string name) => toolResolver?.Invoke(name) ?? new[] { "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/" }
        .Select(p => p + name).FirstOrDefault(File.Exists) ?? throw new IOException("Install missing native utility: " + name);
    string Run(string tool, params string[] args) => Runner.Run(new(Tool(tool), args));
    public bool IsAdmin() => Run("id", "-u").Trim() == "0";
    static string S(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.ToString().Trim() : "";
    static long N(JsonElement e, string key) => long.TryParse(S(e, key), out var n) ? n : throw new IOException("Missing numeric lsblk field: " + key);
    static IEnumerable<JsonElement> Tree(JsonElement e)
    {
        yield return e;
        if (e.TryGetProperty("children", out var kids)) foreach (var child in kids.EnumerateArray()) foreach (var n in Tree(child)) yield return n;
    }
    static string[] Mounts(JsonElement e) => e.GetProperty("mountpoints").EnumerateArray()
        .Where(v => v.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(v.GetString())).Select(v => v.GetString()!).Order().ToArray();
    public List<Disk> Discover()
    {
        Run("udevadm", "settle", "--timeout=10");
        using var doc = JsonDocument.Parse(Run("lsblk", "--json", "--bytes", "--tree", "--output",
            "NAME,KNAME,PATH,TYPE,SIZE,RO,MODEL,SERIAL,WWN,TRAN,PTTYPE,PARTTYPE,START,FSTYPE,MOUNTPOINTS,MAJ:MIN"));
        var roots = doc.RootElement.GetProperty("blockdevices").EnumerateArray().ToArray();
        var all = roots.SelectMany(Tree).ToArray();
        var rootDevice = Run("findmnt", "--noheadings", "--output", "MAJ:MIN", "--target", "/").Trim();
        bool rootKnown = all.Any(n => S(n, "maj:min") == rootDevice);
        bool hostNamespace = new FileInfo("/proc/self/ns/mnt").LinkTarget == new FileInfo("/proc/1/ns/mnt").LinkTarget;
        var result = new List<Disk>();
        foreach (var d in roots.Where(n => S(n, "type") == "disk"))
        {
            var nodes = Tree(d).ToArray(); var blocks = new List<string>();
            if (!rootKnown || !hostNamespace) blocks.Add("Cannot establish host root disk (container/live overlay/namespace); writes disabled");
            if (nodes.Any(n => S(n, "maj:min") == rootDevice)) blocks.Add("Root/system disk");
            if (nodes.Any(n => Mounts(n).Length > 0)) blocks.Add("Mounted filesystem or active swap");
            if (nodes.Skip(1).Any(n => S(n, "type") != "part")) blocks.Add("Stacked storage (LVM/RAID/crypt/multipath)");
            foreach (var n in nodes)
            {
                var sys = "/sys/class/block/" + S(n, "kname");
                if (!Directory.Exists(sys + "/holders") || Directory.EnumerateFileSystemEntries(sys + "/holders").Any()) blocks.Add("Device has holders or unavailable sysfs");
                var fs = S(n, "fstype").ToLowerInvariant();
                if (fs != "" && fs is not ("ext4" or "ext3" or "ext2" or "ntfs" or "exfat" or "vfat")) blocks.Add("Unsupported or special filesystem: " + fs);
            }
            var parts = nodes.Where(n => S(n, "type") == "part").Select(n => {
                var num = int.Parse(File.ReadAllText("/sys/class/block/" + S(n, "kname") + "/partition").Trim());
                // Linux sysfs start and lsblk START use fixed 512-byte sectors, including 4Kn disks.
                return new Partition(num, S(n, "path"), checked(N(n, "start") * 512), N(n, "size"), S(n, "fstype"), S(n, "parttype").ToLowerInvariant(), Mounts(n));
            }).OrderBy(p => p.Number).ToArray();
            if (parts.Any(p => p.Type != Basic && p.Type != LinuxData && p.Type != "e3c9e316-0b5c-4db8-817d-f92df00215ae")) blocks.Add("Special/boot/unknown partition type");
            if (S(d, "pttype") == "gpt")
            {
                // Read-only inspection catches legacy_boot/hidden flags on otherwise ordinary data GUIDs.
                var layout = Run("parted", "--machine", "--script", S(d, "path"), "unit", "B", "print");
                foreach (var line in layout.Split('\n').Where(l => System.Text.RegularExpressions.Regex.IsMatch(l, @"^\d+:")))
                {
                    var flags = line.TrimEnd('\r', ';').Split(':')[^1].Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                    if (flags.Any(f => f is not ("msftdata" or "msftres"))) blocks.Add("Protected/unsupported partition flags");
                }
            }
            var sequence = "/sys/class/block/" + S(d, "kname") + "/diskseq";
            var identity = S(d, "serial") + "|" + S(d, "wwn");
            if (File.Exists(sequence)) identity += "|diskseq=" + File.ReadAllText(sequence).Trim();
            else if (identity == "|") identity = "";
            if (S(d, "fstype") != "") blocks.Add("Whole-disk filesystem/signature; initialization refused");
            Safety.Require(S(d, "ro") is "true" or "false" or "1" or "0", "Unknown read-only state from lsblk.");
            result.Add(new(S(d, "path"), identity, S(d, "model"), N(d, "size"), S(d, "pttype"), S(d, "tran"), S(d, "ro") is "true" or "1", blocks.Distinct().Order().ToArray(), parts));
        }
        return result.OrderBy(d => d.Id).ToList();
    }
    public Command Plan(Disk disk, Request r)
    {
        if (r.Action == "init")
        {
            // Probe only. Never wipe a detected filesystem or old table automatically.
            using var signatures = JsonDocument.Parse(Run("wipefs", "--json", disk.Id));
            Safety.Require(signatures.RootElement.GetProperty("signatures").GetArrayLength() == 0, "Existing signatures found; initialization refused.");
            return new(Tool("parted"), ["--script", "--align", "optimal", disk.Id, "mklabel", "gpt"]);
        }
        if (r.Action == "create") return new(Tool("parted"), ["--script", "--align", "optimal", disk.Id, "unit", "B", "mkpart", "data", "ext4", checked(r.StartMiB * Safety.MiB) + "B", checked((r.StartMiB + r.SizeMiB) * Safety.MiB - 1) + "B"]);
        if (r.Action == "delete") return new(Tool("parted"), ["--script", disk.Id, "rm", r.Partition.ToString()]);
        var path = disk.Partitions.Single(p => p.Number == r.Partition).Path;
        return r.FileSystem switch {
            // One -F permits confirmed reformatting without an interactive prompt. Never use -F twice (mounted-device override).
            "ext4" => new(Tool("mkfs.ext4"), ["-F", path]),
            "exfat" => new(Tool("mkfs.exfat"), [path]),
            "fat32" => new(Tool("mkfs.fat"), ["-F", "32", path]),
            "ntfs" => new(Tool("mkfs.ntfs"), ["--quick", path]),
            _ => throw new ArgumentException("Unsupported Linux filesystem.")
        };
    }
    public void Execute(Disk disk, Request r, Command command)
    {
        // Repeat signature checks after the user confirmation as well.
        var freshPlan = Plan(disk, r);
        Safety.Require(command.File == freshPlan.File && command.Args.SequenceEqual(freshPlan.Args), "Native plan changed.");
        Console.WriteLine(Runner.Run(freshPlan));
        Run("udevadm", "settle", "--timeout=10");
    }
}
