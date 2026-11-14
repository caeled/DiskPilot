using System.Globalization;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace DiskPilot.Gui;
public sealed class MainWindow : Window
{
    readonly IBackend backend;
    readonly OperationSession session;
    readonly bool demo;
    readonly ComboBox disks = new() { HorizontalAlignment = HorizontalAlignment.Stretch, Name = "DiskSelector" };
    readonly ListBox partitions = new() { MinHeight = 120, Name = "PartitionList" };
    readonly TextBox details = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 155 };
    readonly TextBlock status = new() { Text = "Ready", TextWrapping = TextWrapping.Wrap };
    readonly StackPanel actions = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    readonly Menu menu = new();
    List<Disk> inventory = [];
    bool busy;
    Disk Selected => disks.SelectedIndex >= 0 && disks.SelectedIndex < inventory.Count ? inventory[disks.SelectedIndex] : throw new InvalidOperationException("Select a disk first.");

    public MainWindow(IBackend backend, bool demo = false)
    {
        this.backend = backend; session = new(backend); this.demo = demo;
        Title = demo ? "DiskPilot — Safe demo" : "DiskPilot";
        Width = 1000; Height = 740; MinWidth = 780; MinHeight = 620;
        menu.ItemsSource = new[] {
            Group("_File", Item("_Refresh devices", Refresh), Item("E_xit", () => { Close(); return Task.CompletedTask; })),
            Group("_Disk", Item("View _details", ShowDetails), Item("_Initialize GPT…", () => Operation("init"))),
            Group("_Partition", Item("_Create…", () => Operation("create")), Item("_Delete…", () => Operation("delete")), Item("_Format…", () => Operation("format"))),
            Group("_Help", Item("_Safety and usage", Help), Item("_About", () => Message("About DiskPilot", "DiskPilot • .NET 10 / Avalonia\nWindows and Linux native disk management.\nGPT writes; MBR discovery only.\nSee the bundled README for dependencies and validation limits.")))
        };
        var root = new DockPanel(); DockPanel.SetDock(menu, Dock.Top); root.Children.Add(menu);
        var footer = new Border { Padding = new Thickness(18, 10), Background = Brushes.WhiteSmoke, Child = status };
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var body = new StackPanel { Margin = new Thickness(24), Spacing = 12 };
        body.Children.Add(new TextBlock { Text = "DiskPilot", FontSize = 28, FontWeight = FontWeight.SemiBold });
        body.Children.Add(new TextBlock { Text = demo ? "DEMO • sample device only. Applying changes is disabled." : "Select a device, review its layout, then preview a task. No changes happen until you confirm.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(new TextBlock { Text = "Device", FontWeight = FontWeight.SemiBold });
        body.Children.Add(disks); body.Children.Add(details);
        body.Children.Add(new TextBlock { Text = "Partitions • select one to delete or format", FontWeight = FontWeight.SemiBold });
        body.Children.Add(partitions);
        foreach (var (label, action) in new[] { ("Refresh", "refresh"), ("Initialize GPT…", "init"), ("Create…", "create"), ("Delete…", "delete"), ("Format…", "format") })
        {
            var button = new Button { Content = label };
            button.Click += async (_, _) => await Guard(action == "refresh" ? Refresh : () => Operation(action));
            actions.Children.Add(button);
        }
        body.Children.Add(actions); root.Children.Add(new ScrollViewer { Content = body }); Content = root;
        disks.SelectionChanged += (_, _) => UpdateSelection();
        Opened += async (_, _) => await Guard(Refresh);
        Closing += (_, e) => { if (busy) { e.Cancel = true; status.Text = "Finish or cancel the current dialog before closing. Active native operations cannot be interrupted safely."; } };
    }
    static MenuItem Group(string label, params MenuItem[] items) => new() { Header = label, ItemsSource = items };
    MenuItem Item(string label, Func<Task> action)
    {
        var item = new MenuItem { Header = label };
        item.Click += async (_, _) => { if (label == "E_xit") { if (!busy) Close(); } else await Guard(action); };
        return item;
    }
    async Task Guard(Func<Task> task)
    {
        if (busy) return;
        busy = true; menu.IsEnabled = actions.IsEnabled = disks.IsEnabled = partitions.IsEnabled = false;
        try { await task(); }
        catch (Exception ex) { status.Text = "Stopped: " + ex.Message; await Message("Task stopped", ex.Message); }
        finally { busy = false; menu.IsEnabled = actions.IsEnabled = disks.IsEnabled = partitions.IsEnabled = true; }
    }
    async Task Refresh()
    {
        status.Text = "Discovering devices…";
        // Clear stale device choices even if discovery fails.
        inventory = []; disks.ItemsSource = Array.Empty<string>(); UpdateSelection();
        inventory = await Task.Run(backend.Discover);
        disks.ItemsSource = inventory.Select(d => $"{d.Id}   •   {d.Model}   •   {d.Size / (double)(1024 * Safety.MiB):F1} GiB   •   {d.Bus}").ToArray();
        disks.SelectedIndex = inventory.Count > 0 ? 0 : -1;
        status.Text = $"{inventory.Count} device(s). Preview operations before applying.";
    }
    void UpdateSelection()
    {
        if (disks.SelectedIndex < 0 || disks.SelectedIndex >= inventory.Count) { details.Text = "No device selected."; partitions.ItemsSource = Array.Empty<string>(); return; }
        var d = Selected;
        details.Text = Summary(d);
        partitions.ItemsSource = d.Partitions.Select(p => $"#{p.Number}   |   Start {p.Offset / (double)Safety.MiB:N2} MiB   |   Size {p.Size / (double)Safety.MiB:N2} MiB   |   {p.FileSystem}   |   {string.Join(", ", p.Mounts)}").ToArray();
        partitions.SelectedIndex = -1;
    }
    static string Summary(Disk d) => $"Disk: {d.Id} • {d.Model}\nSize: {d.Size:N0} bytes • Table: {d.Table} • Bus: {d.Bus}\nIdentity: {d.Identity}\nFingerprint: {d.Fingerprint}\nProtection: {(d.ReadOnly ? "Read-only. " : "")}{(d.Blocks.Length > 0 ? string.Join("; ", d.Blocks) : "No protection flags reported; final checks still required.")}";
    Task ShowDetails() => Message("Device and partition details", Summary(Selected) + "\n\n" + JsonSerializer.Serialize(Selected.Partitions, new JsonSerializerOptions { WriteIndented = true }));
    Task Help() => Message("Safety and usage", "1. Refresh and verify the device model, size and identity.\n2. Select a partition for Delete or Format.\n3. Choose a task and review its dry-run preview.\n4. Apply requires Administrator/root and the exact confirmation phrase.\n\nUnmount all partitions first. System/protected disks are refused. The GUI never elevates itself or unmounts disks automatically.\n\nStart elevated using your OS's trusted launch mechanism. On Linux, root GUI access depends on your desktop session; the CLI remains available if elevated GUI access is unavailable.\n\nInitialization and formatting destroy data. No undo is available. Use disposable media first. See README for limitations.");
    async Task Operation(string action)
    {
        var disk = Selected;
        var partition = action is "delete" or "format"
            ? partitions.SelectedIndex >= 0 ? disk.Partitions[partitions.SelectedIndex].Number : throw new InvalidOperationException("Select a partition first.") : 0;
        var start = new TextBox { Text = "16" }; var size = new TextBox { Watermark = "Size in MiB" };
        var fs = new ComboBox { ItemsSource = OperatingSystem.IsWindows() ? new[] { "exfat", "ntfs", "fat32" } : new[] { "exfat", "ext4", "ntfs", "fat32" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var form = new StackPanel { Spacing = 10 };
        form.Children.Add(Text(Summary(disk)));
        if (partition > 0) form.Children.Add(Text($"Target partition: #{partition}"));
        if (action == "create") { form.Children.Add(Text("Start (MiB) — choose an unallocated region")); form.Children.Add(start); form.Children.Add(Text("Size (MiB)")); form.Children.Add(size); }
        if (action == "format") { form.Children.Add(Text("Filesystem")); form.Children.Add(fs); }
        if (action == "init") form.Children.Add(Text("Initialize an uninitialized disk as GPT. Windows RAW does not prove the disk is blank."));
        if (action == "delete") form.Children.Add(Text("Delete this partition and its filesystem. This cannot be undone."));
        if (!await Ask($"{Label(action)} • settings", form, "Preview only")) { status.Text = "Cancelled; no changes made."; return; }
        long Parse(TextBox box) => long.TryParse(box.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : throw new ArgumentException("Start and size must be positive whole numbers in MiB.");
        var request = new Request(action, disk.Id, disk.Fingerprint, partition, action == "create" ? Parse(start) : 0, action == "create" ? Parse(size) : 0, action == "format" ? (string)fs.SelectedItem! : "", false);
        status.Text = "Checking device and preparing a dry-run preview…";
        var preview = await Task.Run(() => session.Preview(disk, request));
        var previewText = Summary(disk) + $"\n\nTask: {Label(action)}\nPartition: {(partition > 0 ? partition.ToString() : "—")}\nStart / size: {request.StartMiB} / {request.SizeMiB} MiB\nFilesystem: {request.FileSystem}\n\nNative operation: " + (backend is WindowsBackend ? WindowsBackend.Describe(request) : preview.Command.ToString()) + "\n\nDRY RUN COMPLETE — no changes have been made.";
        if (!await Ask("Dry-run preview", Text(previewText), "Continue to confirmation…", !demo)) { status.Text = "Dry run complete; no changes made."; return; }
        Safety.Require(await Task.Run(backend.IsAdmin), "Start DiskPilot as Administrator/root before applying changes.");
        var input = new TextBox { Watermark = "Type the exact phrase above", AcceptsReturn = false };
        var confirm = new StackPanel { Spacing = 12 };
        confirm.Children.Add(Text(previewText));
        confirm.Children.Add(Text("This may permanently destroy data. Verify the physical device, then type exactly:"));
        confirm.Children.Add(new TextBox { Text = preview.Confirmation, IsReadOnly = true, TextWrapping = TextWrapping.Wrap });
        confirm.Children.Add(input);
        if (!await Ask("Confirm destructive operation", confirm, "Apply change")) { status.Text = "Cancelled; no changes made."; return; }
        status.Text = "Rechecking device and applying operation… Do not disconnect the device or close the app.";
        try { await Task.Run(() => session.Apply(preview, input.Text ?? "")); }
        catch { inventory = []; disks.ItemsSource = Array.Empty<string>(); UpdateSelection(); throw; }
        status.Text = "Operation completed. Refreshing…";
        try { await Refresh(); status.Text = "Operation completed; layout refreshed."; }
        catch (Exception ex) { throw new IOException("Operation completed, but refreshing failed. Inspect the disk before any further changes. " + ex.Message, ex); }
    }
    static string Label(string action) => action switch { "init" => "Initialize GPT", "create" => "Create partition", "delete" => "Delete partition", _ => "Format partition" };
    static TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
    async Task<bool> Ask(string title, Control content, string acceptLabel, bool enabled = true)
    {
        var dialog = new Window { Title = title, Width = 760, Height = 640, MinWidth = 580, MinHeight = 420, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var panel = new DockPanel { Margin = new Thickness(20) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 10, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new Button { Content = "Close / Cancel", IsCancel = true }; cancel.Click += (_, _) => dialog.Close(false);
        var accept = new Button { Content = acceptLabel, IsEnabled = enabled }; accept.Click += (_, _) => dialog.Close(true);
        buttons.Children.Add(cancel); buttons.Children.Add(accept); DockPanel.SetDock(buttons, Dock.Bottom); panel.Children.Add(buttons);
        panel.Children.Add(new ScrollViewer { Content = content }); dialog.Content = panel;
        return await dialog.ShowDialog<bool>(this);
    }
    async Task Message(string title, string message) => _ = await Ask(title, Text(message), "OK");
}
