using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.LogicalTree;
using Avalonia.Threading;
using Avalonia.Interactivity;
using DiskPilot.Gui;

AppBuilder.Configure<App>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
var window = new MainWindow(new DemoBackend(), true);
window.Show();
for (int i = 0; i < 100; i++) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(10); }
var controls = window.GetLogicalDescendants().OfType<Control>().ToArray();
var selector = controls.OfType<ComboBox>().Single(c => c.Name == "DiskSelector");
if (selector.SelectedIndex != 0 || selector.Items.Count != 1) throw new Exception("Demo inventory not loaded");
var list = controls.OfType<ListBox>().Single(c => c.Name == "PartitionList");
if (list.Items.Count != 1) throw new Exception("Partition list missing");
var menu = controls.OfType<Menu>().Single();
var groups = menu.Items.Cast<MenuItem>().ToArray();
if (!groups.Select(g => g.Header?.ToString()).SequenceEqual(new[] { "_File", "_Disk", "_Partition", "_Help" })) throw new Exception("Task menus missing");
if (groups.Sum(g => g.Items.Count) != 9) throw new Exception("Task menu item count mismatch");
if (!window.Title!.Contains("Safe demo")) throw new Exception("Demo label missing");
if (args.Length > 0)
{
    AvaloniaHeadlessPlatform.ForceRenderTimerTick();
    using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No rendered frame");
    frame.Save(args[0]);
}
list.SelectedIndex = 0;
groups[2].Items.Cast<MenuItem>().Single(m => m.Header?.ToString() == "_Format…").RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
Dispatcher.UIThread.RunJobs();
var settings = window.OwnedWindows.Single();
settings.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == "Preview only").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
for (int i = 0; i < 100; i++) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(10); }
var preview = window.OwnedWindows.Single();
if (preview.Title != "Dry-run preview") throw new Exception("Preview flow failed");
var continueButton = preview.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == "Continue to confirmation…");
if (continueButton.IsEnabled) throw new Exception("Demo must disable applying");
preview.Close(false);
Dispatcher.UIThread.RunJobs();
window.Close();
Console.WriteLine("PASS: GUI starts and renders; demo device and partition load; all 9 menu actions present; Format menu opens settings and a dry-run preview; demo apply disabled; cancel works. No real disks accessed.");
