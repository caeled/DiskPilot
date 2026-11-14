namespace DiskPilot;

// The GUI must never turn a displayed plan into a write without rechecking its exact disk.
public sealed record OperationPreview(Disk Disk, Request Request, Command Command)
{
    public string Confirmation => $"ERASE {Disk.Id} {Disk.Fingerprint} {Request.Action}";
}
public sealed class OperationSession(IBackend backend)
{
    public OperationPreview Preview(Disk selected, Request request)
    {
        Safety.Require(!request.Apply, "A preview must be read-only.");
        var current = backend.Discover().Single(d => d.Id == selected.Id);
        Safety.Unchanged(selected, current);
        Safety.Validate(current, request);
        return new(current, request, backend.Plan(current, request));
    }
    public void Apply(OperationPreview preview, string confirmation)
    {
        Safety.Require(confirmation == preview.Confirmation, "Confirmation did not match; no changes made.");
        Safety.Require(backend.IsAdmin(), "Start DiskPilot as Administrator/root before applying changes.");
        var current = backend.Discover().Single(d => d.Id == preview.Disk.Id);
        Safety.Unchanged(preview.Disk, current);
        Safety.Validate(current, preview.Request);
        var plan = backend.Plan(current, preview.Request);
        Safety.Require(plan.File == preview.Command.File && plan.Args.SequenceEqual(preview.Command.Args), "The operation plan changed. Preview again.");
        try { backend.Execute(current, preview.Request with { Apply = true }, plan); }
        catch (Exception ex) { throw new IOException("The native operation failed; the disk may already have changed. Inspect before retrying. " + ex.Message, ex); }
    }
}
