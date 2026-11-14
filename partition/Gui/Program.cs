using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;

namespace DiskPilot.Gui;
public static class Program
{
    [STAThread]
    public static void Main(string[] args) => AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace().StartWithClassicDesktopLifetime(args);
}
public sealed class App : Application
{
    public override void Initialize() { Styles.Add(new FluentTheme()); RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Light; }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var demo = desktop.Args?.Contains("--demo") == true;
            IBackend backend = demo ? new DemoBackend() : OperatingSystem.IsWindows() ? new WindowsBackend() : new LinuxBackend();
            desktop.MainWindow = new MainWindow(backend, demo);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
public sealed class DemoBackend : IBackend
{
    public List<Disk> Discover() => [new("DEMO-USB", "DEMO ONLY — no physical device", "Sample USB drive", 32L * 1024 * Safety.MiB, "gpt", "USB", false, [],
        [new(1, "demo-partition", Safety.MiB, 4096L * Safety.MiB, "exfat", "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", [])])];
    public bool IsAdmin() => false;
    public Command Plan(Disk disk, Request request) => new("DEMO — never executed", [request.Action]);
    public void Execute(Disk disk, Request request, Command command) => throw new InvalidOperationException("Demo mode cannot modify devices.");
}
