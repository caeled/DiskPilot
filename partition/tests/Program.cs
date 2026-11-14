using DiskPilot;
using System.Text.Json;

var p = new Partition(1, "/dev/example1", Safety.MiB, 100 * Safety.MiB, "ext4", "0fc63daf-8483-4772-8e79-3d69d8477de4", []);
var disk = new Disk("/dev/example", "serial-123", "Fixture", 1024 * Safety.MiB, "gpt", "usb", false, [], [p]);
Request Req(string action = "create") => new(action, disk.Id, disk.Fingerprint, 1, 101, 100, "ext4", false);
int passed = 0;
void Pass(string name, Action test) { test(); passed++; Console.WriteLine("PASS " + name); }
void Refuse(string name, Action test) => Pass(name, () => { try { test(); } catch (Exception ex) when (ex is InvalidOperationException or OverflowException or ArgumentException) { return; } throw new Exception("Expected refusal: " + name); });
Pass("adjacent region accepted", () => Safety.Validate(disk, Req()));
Pass("delete existing partition accepted", () => Safety.Validate(disk, Req("delete")));
Pass("format existing partition accepted", () => Safety.Validate(disk, Req("format")));
Refuse("overlap", () => Safety.Validate(disk, Req() with { StartMiB = 100 }));
Refuse("GPT tail reserved", () => Safety.Validate(disk, Req() with { SizeMiB = 923 }));
Refuse("zero size", () => Safety.Validate(disk, Req() with { SizeMiB = 0 }));
Refuse("negative start", () => Safety.Validate(disk, Req() with { StartMiB = -1 }));
Refuse("arithmetic overflow", () => Safety.Validate(disk, Req() with { SizeMiB = long.MaxValue }));
Refuse("wrong fingerprint", () => Safety.Validate(disk, Req() with { Fingerprint = "WRONG" }));
Refuse("wrong disk", () => Safety.Validate(disk, Req() with { DiskId = "/dev/other" }));
Refuse("read-only disk", () => Safety.Validate(disk with { ReadOnly = true }, Req()));
Refuse("system disk", () => Safety.Validate(disk with { Blocks = ["system"] }, Req()));
Refuse("mounted sibling", () => Safety.Validate(disk with { Partitions = [p with { Mounts = ["/data"] }] }, Req()));
Refuse("MBR mutation", () => Safety.Validate(disk with { Table = "dos" }, Req()));
Refuse("unknown partition", () => Safety.Validate(disk, Req("delete") with { Partition = 2 }));
Refuse("initialize existing GPT", () => Safety.Validate(disk, Req("init")));
var raw = disk with { Table = "raw", Partitions = [] };
Pass("initialize RAW", () => Safety.Validate(raw, Req("init")));
Refuse("RAW with partitions", () => Safety.Validate(raw with { Partitions = [p] }, Req("init")));
Pass("stable snapshot", () => Safety.Unchanged(disk, JsonSerializer.Deserialize<Disk>(disk.Snapshot)!));
Refuse("replacement device", () => Safety.Unchanged(disk, disk with { Identity = "replacement" }));
Refuse("layout race", () => Safety.Unchanged(disk, disk with { Partitions = [] }));
Refuse("mount race", () => Safety.Unchanged(disk, disk with { Partitions = [p with { Mounts = ["/new"] }] }));
Refuse("duplicate options", () => DiskPilot.Program.Parse(["--disk", "1", "--disk", "2"]));
Refuse("missing option value", () => DiskPilot.Program.Parse(["--disk"]));
Refuse("flag as value", () => DiskPilot.Program.Parse(["--disk", "--apply"]));
Pass("explicit dry-run parsed", () => { if (!DiskPilot.Program.Parse(["--dry-run"]).ContainsKey("dry-run")) throw new Exception(); });
if (OperatingSystem.IsWindows()) {
    var win = new WindowsBackend();
    Refuse("Windows rejects ext4", () => win.Plan(disk, Req("format")));
    Pass("Windows accepts NTFS", () => win.Plan(disk, Req("format") with { FileSystem = "ntfs" }));
}
var linux = new LinuxBackend(name => "/native/" + name);
Pass("Linux exact byte boundaries", () => {
    var c = linux.Plan(disk, Req());
    if (c.File != "/native/parted" || c.Args[^2] != "105906176B" || c.Args[^1] != "210763775B") throw new Exception(c.ToString());
});
Pass("Linux delete targets disk and partition", () => {
    var c = linux.Plan(disk, Req("delete"));
    if (!c.Args.SequenceEqual(new[] { "--script", disk.Id, "rm", "1" })) throw new Exception();
});
foreach (var fs in new[] { "ext4", "exfat", "fat32", "ntfs" }) Pass("Linux format " + fs, () => {
    var c = linux.Plan(disk, Req("format") with { FileSystem = fs });
    if (c.Args[^1] != p.Path || c.Args.Count(a => a == "-F") > 1) throw new Exception();
});
Refuse("Linux rejects arbitrary formatter", () => linux.Plan(disk, Req("format") with { FileSystem = ";rm" }));
var anonymous = disk with { Identity = "|" };
Refuse("missing native identity", () => Safety.Validate(anonymous, Req() with { Fingerprint = anonymous.Fingerprint }));
Refuse("reserved partition cannot be formatted", () => Safety.Validate(disk with { Partitions = [p with { Type = "e3c9e316-0b5c-4db8-817d-f92df00215ae" }] }, Req("format")));
Refuse("EFI partition cannot be deleted", () => Safety.Validate(disk with { Partitions = [p with { Type = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" }] }, Req("delete")));
var fake = new FakeBackend(disk);
var session = new OperationSession(fake);
var preview = session.Preview(disk, Req());
Pass("GUI preview never executes", () => { if (fake.Executions != 0) throw new Exception(); });
Refuse("GUI requires exact confirmation", () => session.Apply(preview, "yes"));
fake.Admin = false;
Refuse("GUI requires elevated privileges", () => session.Apply(preview, preview.Confirmation));
fake.Admin = true; fake.Current = disk with { Identity = "new device" };
Refuse("GUI rejects device swap", () => session.Apply(preview, preview.Confirmation));
fake.Current = disk with { Partitions = [p with { Mounts = ["/new"] }] };
Refuse("GUI rejects newly mounted partition", () => session.Apply(preview, preview.Confirmation));
fake.Current = disk; fake.PlanVersion = "changed";
Refuse("GUI rejects changed plan", () => session.Apply(preview, preview.Confirmation));
fake.PlanVersion = "original";
Pass("GUI valid confirmation dispatches once", () => { session.Apply(preview, preview.Confirmation); if (fake.Executions != 1) throw new Exception(); });
Refuse("GUI cannot preview an apply request", () => session.Preview(disk, Req() with { Apply = true }));
Console.WriteLine($"{passed} tests passed. No device operations executed.");

sealed class FakeBackend(Disk disk) : IBackend
{
    public Disk Current = disk;
    public bool Admin = true;
    public int Executions;
    public string PlanVersion = "original";
    public List<Disk> Discover() => [Current];
    public bool IsAdmin() => Admin;
    public Command Plan(Disk d, Request r) => new("fixture", [PlanVersion]);
    public void Execute(Disk d, Request r, Command c) { if (!r.Apply) throw new Exception("Apply flag required"); Executions++; }
}
