# USBDoctor.Core.psm1 - engine for USBDoctor (diagnose and repair common USB drive problems)
# Windows PowerShell 5.1. Read-only checks run as a normal user; repairs and raw sector reads need Administrator.
$script:Version      = '1.1.0'
$script:LogFile      = Join-Path $env:ProgramData 'USBDoctor\USBDoctor.log'
$script:AllowVirtual = $false
$script:UsbSubgroup  = '2a737441-1930-4402-8d77-b2bebba308a3'   # power plan: USB settings
$script:SuspendGuid  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB selective suspend
$script:FakeVidPid   = @('ABCD:1234', '0000:0000', 'FFFF:FFFF', 'FFFF:5678', '1234:5678')
$script:FakeNames    = 'VendorCo|ProductCode|^General UDisk|^UDisk$'
$script:HistoryFile  = Join-Path $env:ProgramData 'USBDoctor\history.json'
$script:TestHooks    = @{}
$script:LastGetDiskMs = 0

if (-not ('UsbDocNative' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Threading; using System.Collections.Generic;
using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;

public class UsbDocRescueState {
  public long Size; public long Position; public long BytesRead; public long BytesBad;
  public List<long[]> BadRanges = new List<long[]>();
  public string Status = "running"; public int LastError; public long LastErrorOffset = -1;
  public List<long[]> SimBad = new List<long[]>(); public long SimDropAt = -1;
  public int ReadTimeoutMs = 15000; public int MaxConsecutiveBad = 16; public long StopAt = -1;
  public void AddBad(long start, long len) {
    BytesBad += len;
    if (BadRanges.Count > 0) { long[] l = BadRanges[BadRanges.Count - 1]; if (l[0] + l[1] == start) { l[1] += len; return; } }
    BadRanges.Add(new long[] { start, len });
  }
  public bool IsSimBad(long off, int len) {
    foreach (long[] r in SimBad) { if (off < r[0] + r[1] && r[0] < off + len) return true; }
    return false;
  }
}

public static class UsbDocNative {
  // Access masks written as decimal on purpose: GENERIC_READ = 2147483648, GENERIC_READ|GENERIC_WRITE = 3221225472.
  public const uint GENERIC_READ = 2147483648u;
  public const uint GENERIC_READ_WRITE = 3221225472u;
  const uint SHARE_RW = 3, OPEN_EXISTING = 3;
  const uint FSCTL_LOCK_VOLUME = 0x00090018, FSCTL_DISMOUNT_VOLUME = 0x00090020;
  const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C, IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;
  const int CHUNK = 1048576, SMALL = 4096;

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, uint il, byte[] o, uint ol, out uint r, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool ReadFile(SafeFileHandle h, byte[] b, int n, out int read, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool WriteFile(SafeFileHandle h, byte[] b, int n, out int written, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long np, uint method);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool FlushFileBuffers(SafeFileHandle h);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CancelSynchronousIo(IntPtr h);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Locate_DevNodeW(out uint dev, string id, uint flags);
  [DllImport("cfgmgr32.dll")] static extern int CM_Get_Parent(out uint parent, uint dev, uint flags);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Request_Device_EjectW(uint dev, out int veto, StringBuilder name, int len, uint flags);

  public static SafeFileHandle OpenPath(string path, bool write) {
    SafeFileHandle h = CreateFile(path, write ? GENERIC_READ_WRITE : GENERIC_READ, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("Cannot open " + path + " (Win32 error " + Marshal.GetLastWin32Error() + ")");
    return h;
  }
  public static SafeFileHandle OpenDisk(int number, bool write) { return OpenPath(@"\\.\PhysicalDrive" + number, write); }

  public static long GetLength(SafeFileHandle h) {
    byte[] o = new byte[8]; uint r;
    if (!DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, o, 8, out r, IntPtr.Zero)) return -1;
    return BitConverter.ToInt64(o, 0);
  }
  public static bool UpdateProperties(SafeFileHandle h) { uint r; return DeviceIoControl(h, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, null, 0, out r, IntPtr.Zero); }
  public static bool Flush(SafeFileHandle h) { return FlushFileBuffers(h); }

  // Read with a watchdog: a hung read on a failing stick is cancelled after timeoutMs (error 995).
  public static int ReadAt(SafeFileHandle h, long off, byte[] buf, int count, int timeoutMs, out int err) {
    err = 0; long np;
    if (!SetFilePointerEx(h, off, out np, 0)) { err = Marshal.GetLastWin32Error(); return -1; }
    IntPtr th = IntPtr.Zero; Timer timer = null; object gate = new object(); bool[] done = new bool[1];
    if (timeoutMs > 0) {
      th = OpenThread(0x0001, false, GetCurrentThreadId());
      if (th != IntPtr.Zero) {
        IntPtr cap = th;
        timer = new Timer(delegate(object o) { lock (gate) { if (!done[0]) CancelSynchronousIo(cap); } }, null, timeoutMs, Timeout.Infinite);
      }
    }
    int rd = 0; bool ok = false;
    try { ok = ReadFile(h, buf, count, out rd, IntPtr.Zero); if (!ok) err = Marshal.GetLastWin32Error(); }
    finally { lock (gate) { done[0] = true; } if (timer != null) timer.Dispose(); if (th != IntPtr.Zero) CloseHandle(th); }
    return ok ? rd : -1;
  }
  public static void WriteAt(SafeFileHandle h, long off, byte[] buf, int count) {
    long np; int wr;
    if (!SetFilePointerEx(h, off, out np, 0)) throw new IOException("Seek to " + off + " failed (Win32 error " + Marshal.GetLastWin32Error() + ")");
    if (!WriteFile(h, buf, count, out wr, IntPtr.Zero) || wr != count) throw new IOException("Write at disk offset " + off + " failed (Win32 error " + Marshal.GetLastWin32Error() + ", wrote " + wr + " of " + count + ")");
  }

  static bool IsGoneError(int e) { return e == 2 || e == 6 || e == 21 || e == 55 || e == 433 || e == 1167 || e == 1110 || e == 1112; }
  static bool Alive(SafeFileHandle h) { return GetLength(h) > 0; }

  // One time-boxed slice of a skip-on-error rescue copy. 1 MiB reads, 4 KiB fallback, zero-fill and record bad ranges.
  // Returns with st.Status = "running" (slice time used up), "done" or "dropped" (device went away; resume after replug).
  public static void RescueSlice(SafeFileHandle src, FileStream dst, UsbDocRescueState st, int maxMillis) {
    byte[] buf = new byte[CHUNK]; byte[] zero = new byte[CHUNK];
    System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
    st.Status = "running";
    while (st.Position < st.Size && sw.ElapsedMilliseconds < maxMillis) {
      if (st.StopAt >= 0 && st.Position >= st.StopAt) return;
      if (st.SimDropAt >= 0 && st.Position >= st.SimDropAt) { st.SimDropAt = -1; st.Status = "dropped"; st.LastError = 1167; st.LastErrorOffset = st.Position; return; }
      int n = (int)Math.Min((long)CHUNK, st.Size - st.Position);
      int err = 0; int rd;
      if (st.IsSimBad(st.Position, n)) { rd = -1; err = 23; } else rd = ReadAt(src, st.Position, buf, n, st.ReadTimeoutMs, out err);
      if (rd == n) { dst.Position = st.Position; dst.Write(buf, 0, n); st.Position += n; st.BytesRead += n; continue; }
      if (rd >= 0 && err == 0) err = 38; // short read
      st.LastError = err; st.LastErrorOffset = st.Position;
      if (IsGoneError(err) || !Alive(src)) { st.Status = "dropped"; return; }
      long start = st.Position; int consec = 0;
      for (int o = 0; o < n; o += SMALL) {
        long p = start + o; int m = Math.Min(SMALL, n - o);
        if (consec >= st.MaxConsecutiveBad) {
          dst.Position = p; dst.Write(zero, 0, n - o); st.AddBad(p, n - o); st.Position = start + n; break;
        }
        int e2 = 0; int r2;
        if (st.IsSimBad(p, m)) { r2 = -1; e2 = 23; } else r2 = ReadAt(src, p, buf, m, st.ReadTimeoutMs, out e2);
        if (r2 == m) { dst.Position = p; dst.Write(buf, 0, m); st.BytesRead += m; consec = 0; }
        else {
          if (r2 >= 0 && e2 == 0) e2 = 38;
          st.LastError = e2; st.LastErrorOffset = p;
          if (IsGoneError(e2) || !Alive(src)) { st.Position = p; st.Status = "dropped"; return; }
          dst.Position = p; dst.Write(zero, 0, m); st.AddBad(p, m); consec++;
        }
        st.Position = p + m;
      }
    }
    if (st.Position >= st.Size) st.Status = "done";
  }

  // Strict copy of a disk range into an open stream (used for backups before a repair). Throws on any read error.
  public static void CopyDiskToStream(SafeFileHandle h, long diskOffset, long length, FileStream fs) {
    byte[] buf = new byte[CHUNK]; long done = 0;
    while (done < length) {
      int n = (int)Math.Min((long)CHUNK, length - done); int err;
      int r = ReadAt(h, diskOffset + done, buf, n, 30000, out err);
      if (r != n) throw new IOException("Read failed at disk offset " + (diskOffset + done) + " (Win32 error " + err + ").");
      fs.Write(buf, 0, n); done += n;
    }
  }
  public static void CopyStreamToDisk(FileStream fs, long fileOffset, SafeFileHandle h, long diskOffset, long length) {
    byte[] buf = new byte[CHUNK]; long done = 0;
    while (done < length) {
      int n = (int)Math.Min((long)CHUNK, length - done);
      fs.Position = fileOffset + done; int got = 0;
      while (got < n) { int k = fs.Read(buf, got, n - got); if (k <= 0) throw new IOException("Backup file ended early at " + (fileOffset + done + got)); got += k; }
      WriteAt(h, diskOffset + done, buf, n); done += n;
    }
  }
  // Returns -1 when equal, else the disk offset of the first differing 1 MiB block.
  public static long CompareDiskToStream(SafeFileHandle h, long diskOffset, FileStream fs, long fileOffset, long length) {
    byte[] a = new byte[CHUNK]; byte[] b = new byte[CHUNK]; long done = 0;
    while (done < length) {
      int n = (int)Math.Min((long)CHUNK, length - done); int err;
      if (ReadAt(h, diskOffset + done, a, n, 30000, out err) != n) return diskOffset + done;
      fs.Position = fileOffset + done; int got = 0;
      while (got < n) { int k = fs.Read(b, got, n - got); if (k <= 0) return diskOffset + done; got += k; }
      for (int i = 0; i < n; i++) if (a[i] != b[i]) return diskOffset + done;
      done += n;
    }
    return -1;
  }


  // CRC32 (IEEE), as used by GPT headers and entry arrays.
  static uint[] crcTable;
  public static uint Crc32(byte[] data, int offset, int count) {
    if (crcTable == null) {
      uint[] t = new uint[256];
      for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[i] = c; }
      crcTable = t;
    }
    uint crc = 0xFFFFFFFFu;
    for (int i = offset; i < offset + count; i++) crc = crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
  }

  // Capacity test pattern: every block carries its own offset and a pseudo-random fill derived from it,
  // so a block written past the real flash (which wraps onto earlier blocks) is detected when read back.
  static void FillPattern(byte[] b, int len, long off, uint seed) {
    ulong x = (ulong)off * 0x9E3779B97F4A7C15UL ^ seed ^ 0xD1B54A32D192ED03UL; if (x == 0) x = 1;
    for (int i = 0; i < len; i += 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; byte[] v = BitConverter.GetBytes(x); Array.Copy(v, 0, b, i, Math.Min(8, len - i)); }
    byte[] o = BitConverter.GetBytes(off); Array.Copy(o, 0, b, 0, 8);
    byte[] s = BitConverter.GetBytes(seed); Array.Copy(s, 0, b, 8, 4);
  }
  public static void CapacityWrite(SafeFileHandle h, long off, int len, uint seed, long simWrapAt) {
    byte[] b = new byte[len]; FillPattern(b, len, off, seed);
    long real = simWrapAt > 0 ? off % simWrapAt : off;
    WriteAt(h, real, b, len);
  }
  // Returns 0 = pattern intact, 1 = mismatch (overwritten / never stored), 2 = read error.
  public static int CapacityCheck(SafeFileHandle h, long off, int len, uint seed, long simWrapAt) {
    byte[] want = new byte[len]; FillPattern(want, len, off, seed);
    byte[] got = new byte[len]; int err;
    long real = simWrapAt > 0 ? off % simWrapAt : off;
    if (ReadAt(h, real, got, len, 30000, out err) != len) return 2;
    for (int i = 0; i < len; i++) if (want[i] != got[i]) return 1;
    return 0;
  }

  // Lock (and if needed force-dismount) a volume such as \\.\H: or \\.\Volume{guid}. Keep the returned handle open while writing.
  public static SafeFileHandle LockVolume(string path, out string message) {
    SafeFileHandle h = CreateFile(path, GENERIC_READ_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    if (h.IsInvalid) { message = "cannot open " + path + " (Win32 error " + Marshal.GetLastWin32Error() + ")"; return null; }
    uint r; bool locked = false;
    for (int i = 0; i < 5 && !locked; i++) { locked = DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, null, 0, out r, IntPtr.Zero); if (!locked) Thread.Sleep(400); }
    bool dism = DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, null, 0, out r, IntPtr.Zero);
    if (!locked) locked = DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, null, 0, out r, IntPtr.Zero);
    message = path + ": locked=" + locked + ", dismounted=" + dism;
    if (!locked) { h.Close(); return null; }
    return h;
  }

  public static string Eject(string instanceId) {
    uint dev; int cr = CM_Locate_DevNodeW(out dev, instanceId, 0);
    if (cr != 0) return "device not found (CM error " + cr + ")";
    string first = null;
    for (int attempt = 0; attempt < 2; attempt++) {
      int veto; StringBuilder sb = new StringBuilder(512);
      cr = CM_Request_Device_EjectW(dev, out veto, sb, sb.Capacity, 0);
      if (cr == 0 && veto == 0) return "OK";
      string why = "CM error " + cr + ", veto " + VetoName(veto) + (sb.Length > 0 ? " (" + sb.ToString() + ")" : "");
      if (first == null) first = why;
      uint p; if (attempt == 0 && CM_Get_Parent(out p, dev, 0) == 0) { dev = p; continue; }
      return first;
    }
    return first;
  }
  // Wipe (Prepare & Tools, not a repair): mode 0 = zeros, 1 = pseudo-random (reproducible from seed, so samples can be verified).
  public static void WipeSlice(SafeFileHandle h, long off, long len, int mode, uint seed) {
    byte[] b = new byte[CHUNK]; long done = 0;
    while (done < len) {
      int n = (int)Math.Min((long)CHUNK, len - done);
      if (mode == 1) FillPattern(b, n, off + done, seed); else if (done == 0) Array.Clear(b, 0, b.Length);
      WriteAt(h, off + done, b, n); done += n;
    }
  }
  // 0 = matches, 1 = mismatch, 2 = read error.
  public static int WipeCheck(SafeFileHandle h, long off, int len, int mode, uint seed) {
    byte[] want = new byte[len]; if (mode == 1) FillPattern(want, len, off, seed);
    byte[] got = new byte[len]; int err;
    if (ReadAt(h, off, got, len, 30000, out err) != len) return 2;
    for (int i = 0; i < len; i++) if (want[i] != got[i]) return 1;
    return 0;
  }
  // Write a byte buffer that may be shorter than a sector: pads with zeros up to the sector size.
  public static void WritePadded(SafeFileHandle h, long off, byte[] data, int count, int sector) {
    int n = ((count + sector - 1) / sector) * sector; byte[] b = new byte[n]; Array.Copy(data, b, count); WriteAt(h, off, b, n);
  }

  static string VetoName(int v) {
    switch (v) {
      case 0: return "none"; case 5: return "device is busy (pending close)"; case 6: return "files are open on the drive";
      case 7: return "device is in use"; case 8: return "a driver refused"; case 9: return "the device is not ejectable";
      case 11: return "insufficient rights"; default: return "type " + v;
    }
  }
}

public class UsbDocBenchResult {
  public double SeqWriteMBs = -1, SeqReadMBs = -1, RandWriteIops = -1, RandReadIops = -1;
  public long Bytes, Mismatches, ReadErrors; public int RandWriteOps, RandReadOps; public string Note = "";
}

// Speed/health benchmark with unbuffered I/O (FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH) and page-aligned buffers,
// so the numbers are the drive's, not the Windows cache's. Every 4 KiB block carries its offset and seed and is verified on read.
public static class UsbDocBench {
  const uint GENERIC_READ = 2147483648u, GENERIC_WRITE = 1073741824u, SHARE_RW = 3, CREATE_ALWAYS = 2, OPEN_EXISTING = 3;
  const uint NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000;
  const int MB = 1048576, K4 = 4096;
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr b, int n, out int read, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, IntPtr b, int n, out int written, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long np, uint method);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr size, uint type, uint protect);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualFree(IntPtr a, UIntPtr size, uint type);

  static SafeFileHandle Open(string path, bool write, bool create) {
    SafeFileHandle h = CreateFile(path, write ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ, SHARE_RW, IntPtr.Zero, create ? CREATE_ALWAYS : OPEN_EXISTING, NO_BUFFERING | WRITE_THROUGH, IntPtr.Zero);
    if (h.IsInvalid) throw new IOException("Cannot open " + path + " unbuffered (Win32 error " + Marshal.GetLastWin32Error() + ")");
    return h;
  }
  static byte[] Base(uint seed) { byte[] b = new byte[MB]; new Random((int)(seed & 0x7FFFFFFF)).NextBytes(b); return b; }
  // Expected content of the 4 KiB-aligned range [off, off+len) into a managed buffer.
  static void Expected(byte[] bas, byte[] dst, long off, int len, uint seed) {
    for (int i = 0; i < len; i += K4) {
      long o = off + i; Array.Copy(bas, (int)(o % MB), dst, i, K4);
      byte[] ob = BitConverter.GetBytes(o); Array.Copy(ob, 0, dst, i, 8);
      byte[] sb = BitConverter.GetBytes(seed); Array.Copy(sb, 0, dst, i + 8, 4);
    }
  }
  static void Seek(SafeFileHandle h, long off) { long np; if (!SetFilePointerEx(h, off, out np, 0)) throw new IOException("Seek to " + off + " failed (Win32 error " + Marshal.GetLastWin32Error() + ")"); }
  static void Write(SafeFileHandle h, IntPtr buf, int n, long off) { int w; Seek(h, off); if (!WriteFile(h, buf, n, out w, IntPtr.Zero) || w != n) throw new IOException("Unbuffered write at " + off + " failed (Win32 error " + Marshal.GetLastWin32Error() + ")"); }
  static bool Read(SafeFileHandle h, IntPtr buf, int n, long off) { int r; Seek(h, off); return ReadFile(h, buf, n, out r, IntPtr.Zero) && r == n; }
  static bool Same(byte[] a, byte[] b, int n) { for (int i = 0; i < n; i++) if (a[i] != b[i]) return false; return true; }

  // File mode: sequential write+read of 'bytes' (multiple of 1 MiB) to a temp file, then 4 KiB random write and read inside it.
  public static UsbDocBenchResult FileBench(string path, long bytes, int randSeconds, int maxRandOps, uint seed) {
    UsbDocBenchResult r = new UsbDocBenchResult(); r.Bytes = bytes;
    byte[] bas = Base(seed); byte[] exp = new byte[MB]; byte[] got = new byte[MB];
    IntPtr buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)MB, 0x3000, 0x04);
    if (buf == IntPtr.Zero) throw new OutOfMemoryException("VirtualAlloc failed");
    try {
      System.Diagnostics.Stopwatch sw = new System.Diagnostics.Stopwatch();
      using (SafeFileHandle h = Open(path, true, true)) {
        double busy = 0;
        for (long off = 0; off < bytes; off += MB) {
          Expected(bas, exp, off, MB, seed); Marshal.Copy(exp, 0, buf, MB);
          sw.Restart(); Write(h, buf, MB, off); busy += sw.Elapsed.TotalSeconds;
        }
        r.SeqWriteMBs = bytes / (double)MB / Math.Max(busy, 1e-6);
      }
      using (SafeFileHandle h = Open(path, false, false)) {
        double busy = 0;
        for (long off = 0; off < bytes; off += MB) {
          sw.Restart(); bool ok = Read(h, buf, MB, off); busy += sw.Elapsed.TotalSeconds;
          if (!ok) { r.ReadErrors++; continue; }
          Marshal.Copy(buf, got, 0, MB); Expected(bas, exp, off, MB, seed); if (!Same(exp, got, MB)) r.Mismatches++;
        }
        r.SeqReadMBs = bytes / (double)MB / Math.Max(busy, 1e-6);
      }
      Random rnd = new Random((int)(seed & 0x7FFFFFFF) ^ 0x5bd1e995); long blocks = bytes / K4;
      using (SafeFileHandle h = Open(path, true, false)) {
        double busy = 0; System.Diagnostics.Stopwatch wall = System.Diagnostics.Stopwatch.StartNew();
        while (r.RandWriteOps < maxRandOps && wall.Elapsed.TotalSeconds < randSeconds) {
          long off = (long)(rnd.NextDouble() * blocks) * K4; if (off >= bytes) off = bytes - K4;
          Expected(bas, exp, off, K4, seed); Marshal.Copy(exp, 0, buf, K4);
          sw.Restart(); Write(h, buf, K4, off); busy += sw.Elapsed.TotalSeconds; r.RandWriteOps++;
        }
        r.RandWriteIops = r.RandWriteOps / Math.Max(busy, 1e-6);
      }
      using (SafeFileHandle h = Open(path, false, false)) {
        double busy = 0; System.Diagnostics.Stopwatch wall = System.Diagnostics.Stopwatch.StartNew();
        while (r.RandReadOps < maxRandOps && wall.Elapsed.TotalSeconds < randSeconds) {
          long off = (long)(rnd.NextDouble() * blocks) * K4; if (off >= bytes) off = bytes - K4;
          sw.Restart(); bool ok = Read(h, buf, K4, off); busy += sw.Elapsed.TotalSeconds; r.RandReadOps++;
          if (!ok) { r.ReadErrors++; continue; }
          Marshal.Copy(buf, got, 0, K4); Expected(bas, exp, off, K4, seed); if (!Same(exp, got, K4)) r.Mismatches++;
        }
        r.RandReadIops = r.RandReadOps / Math.Max(busy, 1e-6);
      }
    } finally { VirtualFree(buf, UIntPtr.Zero, 0x8000); }
    return r;
  }

  // Read-only raw mode (administrator): sequential read of the first 'bytes' of the disk and 4 KiB random reads across all of it.
  public static UsbDocBenchResult RawBench(string devicePath, long diskSize, long bytes, int randSeconds, int maxRandOps, uint seed) {
    UsbDocBenchResult r = new UsbDocBenchResult(); if (bytes > diskSize) bytes = (diskSize / MB) * MB; r.Bytes = bytes; r.Note = "read-only";
    IntPtr buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)MB, 0x3000, 0x04);
    if (buf == IntPtr.Zero) throw new OutOfMemoryException("VirtualAlloc failed");
    try {
      using (SafeFileHandle h = Open(devicePath, false, false)) {
        System.Diagnostics.Stopwatch sw = new System.Diagnostics.Stopwatch(); double busy = 0;
        for (long off = 0; off + MB <= bytes; off += MB) { sw.Restart(); if (!Read(h, buf, MB, off)) r.ReadErrors++; busy += sw.Elapsed.TotalSeconds; }
        r.SeqReadMBs = bytes / (double)MB / Math.Max(busy, 1e-6);
        Random rnd = new Random((int)(seed & 0x7FFFFFFF)); long blocks = diskSize / K4; busy = 0;
        System.Diagnostics.Stopwatch wall = System.Diagnostics.Stopwatch.StartNew();
        while (r.RandReadOps < maxRandOps && wall.Elapsed.TotalSeconds < randSeconds) {
          long off = (long)(rnd.NextDouble() * blocks) * K4; if (off + K4 > diskSize) off = diskSize - K4;
          sw.Restart(); if (!Read(h, buf, K4, off)) r.ReadErrors++; busy += sw.Elapsed.TotalSeconds; r.RandReadOps++;
        }
        r.RandReadIops = r.RandReadOps / Math.Max(busy, 1e-6);
      }
    } finally { VirtualFree(buf, UIntPtr.Zero, 0x8000); }
    return r;
  }
}
'@
}

# ------------------------------------------------------------------ basics
function Set-UDConfig {
    param([string]$LogFile, [switch]$AllowVirtual, [string]$HistoryFile, [hashtable]$TestHooks)
    if ($LogFile) { $script:LogFile = $LogFile }
    if ($HistoryFile) { $script:HistoryFile = $HistoryFile }
    if ($TestHooks) { $script:TestHooks = $TestHooks }
    $script:AllowVirtual = [bool]$AllowVirtual
    $dir = Split-Path $script:LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
function Get-UDLogFile { $script:LogFile }
function Get-UDVersion { $script:Version }

function Write-UDLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {}
    if ($global:USBDoctorQueue) { $global:USBDoctorQueue.Enqueue($line) } else { Write-Host $line }
}

function Format-Bytes([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Admin([string]$What) {
    if (-not (Test-IsAdmin)) { throw "$What needs administrator rights. Start USBDoctor through USBDoctor.cmd (it asks for UAC)." }
}

function Get-DefaultDataDir {
    if (Test-Path 'D:\') { return 'D:\USB-Backups' }
    Join-Path $env:USERPROFILE 'Documents\USBDoctor'
}

function Get-DiskNumberOfPath([string]$Path) {
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:') { return -1 }
    try { return [int](Get-Partition -DriveLetter $Path.Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { return -1 }
}

function Get-ProtectedDiskNumbers {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    $letters = @('C', 'D', $env:SystemDrive.Substring(0, 1))
    try { $letters += @(Get-CimInstance Win32_PageFileUsage -OperationTimeoutSec 15 -ErrorAction Stop | ForEach-Object { $_.Name.Substring(0, 1) }) } catch {}
    foreach ($l in ($letters | Sort-Object -Unique)) {
        try { [void]$set.Add([int](Get-Partition -DriveLetter $l -ErrorAction Stop).DiskNumber) } catch {}
    }
    foreach ($d in @(Get-Disk)) { if ($d.IsBoot -or $d.IsSystem) { [void]$set.Add([int]$d.Number) } }
    , $set
}

function Get-PartLetter($p) {
    $c = [string]$p.DriveLetter
    if ($c -and $c.Trim([char]0).Trim() -match '^[A-Za-z]$') { return $c.Trim([char]0).Trim().ToUpper() }
    ''
}

function Invoke-Diskpart([string[]]$Lines) {
    $f = Join-Path $env:TEMP ("usbdoctor-dp-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $f -Value ($Lines -join "`r`n") -Encoding ASCII
    try { $out = (& diskpart.exe /s $f 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    $tail = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
    Write-UDLog "diskpart: $tail"
    # diskpart /s stops at the first failing command and exits non-zero (unless that command says noerr), so the exit
    # code is the primary signal. 'online disk noerr' on a disk that is already online prints a harmless
    # "Virtual Disk Service error: This disk is already online." and carries on: that one is not a failure.
    $rest = [regex]::Replace($out, '(?is)Virtual Disk Service error:\s*(The|This) disk is already online\.?', '')
    if ($rest.Length -ne $out.Length) { Write-UDLog 'diskpart: the disk was already online (harmless).' }
    $err = @($rest -split "`r?`n" | Where-Object { $_ -match 'Virtual Disk Service error|DiskPart has encountered an error|is not supported|Access is denied' })
    if ($rc -ne 0 -or $err.Count) {
        $why = @($rest -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 6 | ForEach-Object { $_.Trim() }) -join ' | '
        throw "diskpart failed (exit $rc): $why"
    }
    $out
}

# ------------------------------------------------------------------ identity
function Get-DeviceIdentity([string]$Vid, [string]$PidX, [string]$Serial) {
    # Same physical stick on any port: USB VID/PID plus the storage serial (blank for many cheap sticks).
    if (-not $Vid) { return "UNKNOWN|$Serial" }
    "VID_$($Vid.ToUpper())&PID_$($PidX.ToUpper())|$($Serial.Trim())"
}
function Get-PortKey([string]$ParentId, [string]$LocationPath, [string]$Port) {
    # Windows-generated USB instance IDs ("5&2c4715df&0&20") encode hub and port; unique-serial sticks don't, so use the location path.
    if ($ParentId -match '\\(\d+&[0-9A-Fa-f]+)&\d+&(\d+)$') { return ('port {0} on hub {1}' -f [int]$Matches[2], $Matches[1].ToLower()) }
    if ($LocationPath -match 'USB\(') { return (([regex]::Matches($LocationPath, 'USB\((\d+)\)') | ForEach-Object { $_.Groups[1].Value }) -join '>') -replace '^', 'USB path ' }
    if ($Port) { return $Port }
    'unknown port'
}

# ------------------------------------------------------------------ inventory
function Get-UsbPnpInfo([string]$DiskInstanceId) {
    # Walk up from the disk device to the USB device to get VID/PID, the USB serial and the port.
    $r = [ordered]@{ ParentId = ''; VID = ''; PID = ''; UsbInstance = ''; UniqueUsbSerial = $false; Port = ''; LocationPath = ''; ViaHub = $false; HubName = '' }
    $id = $DiskInstanceId
    for ($i = 0; $i -lt 5 -and $id; $i++) {
        try { $id = "$((Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data)" } catch { $id = '' }
        if ($id -match '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})[^\\]*\\(.+)$') {
            $r.ParentId = $id; $r.VID = $Matches[1].ToUpper(); $r.PID = $Matches[2].ToUpper(); $r.UsbInstance = $Matches[3]
            $r.UniqueUsbSerial = ($Matches[3] -notmatch '&')
            try { $r.Port = "$((Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_LocationInfo -ErrorAction Stop).Data)" } catch {}
            try { $r.LocationPath = "$(@((Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_LocationPaths -ErrorAction Stop).Data)[0])" } catch {}
            try {
                $hub = "$((Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data)"
                $r.HubName = "$((Get-PnpDeviceProperty -InstanceId $hub -KeyName DEVPKEY_Device_FriendlyName -ErrorAction SilentlyContinue).Data)"
                if (-not $r.HubName) { $r.HubName = "$((Get-PnpDeviceProperty -InstanceId $hub -KeyName DEVPKEY_Device_DeviceDesc -ErrorAction SilentlyContinue).Data)" }
                $r.ViaHub = ($hub -notmatch 'ROOT_HUB') -and ($r.HubName -notmatch 'Root Hub')
            } catch {}
            break
        }
    }
    [pscustomobject]$r
}

function Get-UsbDisks {
    # USB disks only (plus attached VHD/VHDX test disks when -AllowVirtual). Never boot/system/C:/D:/pagefile disks.
    $prot = Get-ProtectedDiskNumbers
    $sw = [Diagnostics.Stopwatch]::StartNew(); $all = @(Get-Disk | Sort-Object Number); $script:LastGetDiskMs = $sw.ElapsedMilliseconds
    $wmi = @{}; try { foreach ($w in @(Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 20 -ErrorAction Stop)) { $wmi[[int]$w.Index] = $w } } catch {}
    foreach ($d in $all) {
        $bus = "$($d.BusType)"
        $virtual = $bus -eq 'File Backed Virtual'
        if ($prot.Contains([int]$d.Number)) { continue }
        if (-not ($bus -eq 'USB' -or ($virtual -and $script:AllowVirtual))) { continue }
        $vols = @()
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)) {
            $v = $null; try { $v = $p | Get-Volume -ErrorAction Stop } catch {}
            $vols += [pscustomobject]@{
                PartitionNumber = [int]$p.PartitionNumber; Offset = [long]$p.Offset; PartSize = [long]$p.Size
                Letter = (Get-PartLetter $p); Type = "$($p.Type)"; MbrType = "$($p.MbrType)"; GptType = "$($p.GptType)"; Guid = "$($p.Guid)"; PartReadOnly = [bool]$p.IsReadOnly
                Label = $(if ($v) { "$($v.FileSystemLabel)" } else { '' })
                FileSystem = $(if ($v) { "$($v.FileSystemType)" } else { '' })
                Size = $(if ($v) { [long]$v.Size } else { 0 }); Free = $(if ($v) { [long]$v.SizeRemaining } else { 0 })
                VolumePath = $(if ($v) { "$($v.Path)" } else { '' }); Health = $(if ($v) { "$($v.HealthStatus)" } else { '' })
            }
        }
        $sum = ($vols | Where-Object { $_.FileSystem -and $_.FileSystem -ne 'Unknown' } | ForEach-Object {
                $n = if ($_.Letter) { "$($_.Letter):" } else { '(no letter)' }
                '{0} {1} {2} {3}' -f $n, $(if ($_.Label) { $_.Label } else { '(no label)' }), $_.FileSystem, (Format-Bytes $_.Size)
            }) -join '; '
        if (-not $sum) { $sum = $(if ($vols.Count) { 'unreadable / RAW partition' } else { 'no partitions' }) }
        $w = $wmi[[int]$d.Number]
        $pnpId = if ($w) { "$($w.PNPDeviceID)" } else { '' }
        $pnp = if ($pnpId -and -not $virtual) { Get-UsbPnpInfo $pnpId } else { [pscustomobject]@{ ParentId = ''; VID = ''; PID = ''; UsbInstance = ''; UniqueUsbSerial = $false; Port = ''; LocationPath = ''; ViaHub = $false; HubName = '' } }
        $serial = "$($d.SerialNumber)".Trim()
        $ident = if ($virtual) { "VIRTUAL|$($d.UniqueId)" } else { Get-DeviceIdentity $pnp.VID $pnp.PID $serial }
        [pscustomobject]@{
            Number = [int]$d.Number; Model = "$($d.FriendlyName)".Trim(); Size = [long]$d.Size; Bus = $bus; Virtual = $virtual
            Serial = $serial; UniqueId = "$($d.UniqueId)"; Path = "$($d.Path)"; PartitionStyle = "$($d.PartitionStyle)"
            Signature = $d.Signature; Guid = "$($d.Guid)"
            SectorSize = [int]$d.LogicalSectorSize; ReadOnly = [bool]$d.IsReadOnly; Offline = [bool]$d.IsOffline; OfflineReason = "$($d.OfflineReason)"
            Health = "$($d.HealthStatus)"; OperationalStatus = "$($d.OperationalStatus)"; LargestFreeExtent = [long]$d.LargestFreeExtent
            Removable = ("$($w.MediaType)" -match 'Removable'); DiskInstanceId = $pnpId
            VID = $pnp.VID; PID = $pnp.PID; ParentId = $pnp.ParentId; UsbInstance = $pnp.UsbInstance; UniqueUsbSerial = $pnp.UniqueUsbSerial; Port = $pnp.Port
            LocationPath = $pnp.LocationPath; ViaHub = $pnp.ViaHub; HubName = $pnp.HubName; Identity = $ident
            PortKey = (Get-PortKey $pnp.ParentId $pnp.LocationPath $pnp.Port)
            Volumes = $vols; Summary = $sum
        }
    }
}

function Get-RepairDisk([int]$Number) {
    # The only gate to any disk change: USB (or virtual with -AllowVirtual), never C:/D:/system/boot/pagefile.
    $prot = Get-ProtectedDiskNumbers
    if ($prot.Contains($Number)) { throw "Disk $Number holds C:, D:, Windows, boot or the pagefile. USBDoctor never changes it." }
    $raw = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    if (-not $raw) { throw "Disk $Number is not attached." }
    $bus = "$($raw.BusType)"
    if (-not ($bus -eq 'USB' -or ($bus -eq 'File Backed Virtual' -and $script:AllowVirtual))) { throw "Disk $Number is a $bus disk, not a USB drive. USBDoctor only changes USB drives." }
    $d = @(Get-UsbDisks) | Where-Object { $_.Number -eq $Number }
    if (-not $d) { throw "Disk $Number is not an attached USB disk USBDoctor may change." }
    $d
}

function Assert-Phrase([int]$Number, [string]$Phrase) {
    if ("$Phrase".Trim() -cne "REPAIR $Number") { throw "Confirmation phrase did not match. Type exactly: REPAIR $Number. Nothing was changed." }
}

function Assert-SameDisk($Expected) {
    $now = Get-RepairDisk $Expected.Number
    if ($now.UniqueId -ne $Expected.UniqueId -or $now.Size -ne $Expected.Size) {
        throw "Disk $($Expected.Number) changed since it was checked (identity or size differs). Nothing was written."
    }
    $now
}

function Get-UsbProblemDevices {
    # Present USB devices in an error state, plus leftover "ghost" entries of failed devices (VID_0000, Unknown USB Device).
    $all = @(Get-PnpDevice -Class USB, DiskDrive, WPD, USBDevice -ErrorAction SilentlyContinue)
    foreach ($d in $all) {
        $id = "$($d.InstanceId)"; $present = [bool]$d.Present; $name = "$($d.FriendlyName)"
        if ($id -notmatch '^(USB|USBSTOR)\\') { continue }
        $prob = "$($d.Problem)"
        $kind = $null
        if ($present) {
            if ("$($d.Status)" -in 'Error', 'Degraded' -or ($prob -and $prob -ne 'CM_PROB_NONE' -and $prob -ne '0')) { $kind = 'Error' }
        } elseif ($id -match '^USB\\VID_0000' -or $name -match 'Unknown USB Device|Descriptor Request Failed|Port Reset Failed|Set Address Failed') { $kind = 'Ghost' }
        elseif ($id -like 'USBSTOR\*') { $kind = 'OldDrive' }
        if ($kind) {
            $code = 0; try { $code = [int]$d.ConfigManagerErrorCode } catch {}
            [pscustomobject]@{ Kind = $kind; Present = $present; Status = "$($d.Status)"; Problem = $prob; Code = $code; Class = "$($d.Class)"; FriendlyName = $name; InstanceId = $id }
        }
    }
}

function Get-AutomountState {
    $v = 0
    try { $v = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mountmgr' -Name NoAutoMount -ErrorAction Stop).NoAutoMount } catch {}
    [pscustomobject]@{ Enabled = ($v -eq 0); NoAutoMount = $v }
}

function Get-SelectiveSuspendState {
    $out = & powercfg.exe /query SCHEME_CURRENT $script:UsbSubgroup $script:SuspendGuid 2>&1 | Out-String
    $ac = -1; $dc = -1
    if ($out -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $ac = [Convert]::ToInt32($Matches[1], 16) }
    if ($out -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dc = [Convert]::ToInt32($Matches[1], 16) }
    [pscustomobject]@{ AC = $ac; DC = $dc; Enabled = ($ac -eq 1 -or $dc -eq 1); Known = ($ac -ge 0 -or $dc -ge 0) }
}

# ------------------------------------------------------------------ event history
function Get-UsbEventHistory([int]$Days = 7) {
    # Arrivals/removals from Microsoft-Windows-Partition/Diagnostic 1006 (gives disk number -> USB device at that time),
    # and disk/partmgr errors from the System log, attributed to the USB device that had that disk number at the time.
    $since = (Get-Date).AddDays(-$Days)
    $arr = New-Object System.Collections.Generic.List[object]
    try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Partition/Diagnostic'; Id = 1006; StartTime = $since } -MaxEvents 5000 -ErrorAction Stop) } catch { $ev = @() }
    foreach ($e in $ev) {
        $h = @{}; foreach ($x in ([xml]$e.ToXml()).Event.EventData.Data) { $h[$x.Name] = $x.'#text' }
        $parent = "$($h.ParentId)".ToUpper()
        $vid = ''; $pidx = ''; if ($parent -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { $vid = $Matches[1]; $pidx = $Matches[2] }
        $ser = "$($h.SerialNumber)".Trim()
        $arr.Add([pscustomobject]@{ Time = $e.TimeCreated; Disk = [int]$h.DiskNumber; Capacity = [int64]$h.Capacity; Model = "$($h.Model)".Trim()
                Serial = $ser; ParentId = $parent; PartitionCount = [int]$h.PartitionCount; BusType = [int]$h.BusType
                Key = (Get-DeviceIdentity $vid $pidx $ser); Port = (Get-PortKey $parent '' '') })
    }
    $arrivals = @($arr | Sort-Object Time)
    $errors = New-Object System.Collections.Generic.List[object]
    try { $se = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'partmgr'; StartTime = $since } -MaxEvents 5000 -ErrorAction Stop) } catch { $se = @() }
    foreach ($e in $se) {
        $msg = "$($e.Message)"
        $n = -1
        if ($msg -match '\\Harddisk(\d+)\\') { $n = [int]$Matches[1] } elseif ($msg -match '\b[Dd]isk (\d+)\b') { $n = [int]$Matches[1] }
        if ($n -lt 0) { continue }
        $kind = switch ($e.Id) { 7 { 'BadBlock' } 11 { 'ControllerError' } 15 { 'NotReady' } 51 { 'PagingError' } 153 { 'IoRetried' } 154 { 'HardwareError' } 157 { 'SurpriseRemoved' } default { "Event$($e.Id)" } }
        if ($e.ProviderName -eq 'partmgr') { $kind = "PartMgr$($e.Id)" }
        $owner = $null
        foreach ($a in $arrivals) { if ($a.Time -gt $e.TimeCreated.AddSeconds(2)) { break }; if ($a.Disk -eq $n) { $owner = $a } }
        $errors.Add([pscustomobject]@{ Time = $e.TimeCreated; Disk = $n; Id = $e.Id; Kind = $kind; Provider = $e.ProviderName
                Message = (($msg -replace '\s+', ' ').Trim()); Key = $(if ($owner) { $owner.Key } else { '' }); Model = $(if ($owner) { $owner.Model } else { '' }); Port = $(if ($owner) { $owner.Port } else { '' }) })
    }
    [pscustomobject]@{ Days = $Days; Since = $since; Arrivals = $arrivals; Errors = @($errors | Sort-Object Time) }
}

function Get-DeviceHistorySummary($History, [string]$Key) {
    # Per-stick summary across all ports: connects, read errors, drop-outs right after errors (with time-to-drop),
    # capacity changes, and which ports saw failures ("same failure on N ports").
    $mine = @($History.Arrivals | Where-Object { $_.Key -eq $Key })
    $errs = @($History.Errors | Where-Object { $_.Key -eq $Key })
    $read = @($errs | Where-Object { $_.Kind -in 'BadBlock', 'ControllerError', 'NotReady', 'PagingError', 'IoRetried', 'HardwareError' })
    $drops = @(); $ports = @{}
    $arrivedAt = $null
    for ($i = 0; $i -lt $mine.Count; $i++) {
        $a = $mine[$i]
        if (-not $ports.ContainsKey($a.Port)) { $ports[$a.Port] = [pscustomobject]@{ Port = $a.Port; Connects = 0; ReadErrors = 0; Drops = 0; TimeToDropSec = @() } }
        if ($a.Capacity -gt 0 -and ($i -eq 0 -or $mine[$i - 1].Capacity -eq 0)) { $ports[$a.Port].Connects++; $arrivedAt = $a.Time }
        if ($i -gt 0 -and $a.Capacity -eq 0 -and $mine[$i - 1].Capacity -gt 0) {
            $t = $a.Time
            if (@($read | Where-Object { $_.Time -le $t.AddSeconds(5) -and $_.Time -ge $t.AddSeconds(-120) }).Count) {
                $ttd = if ($arrivedAt) { [int]($t - $arrivedAt).TotalSeconds } else { -1 }
                $drops += [pscustomobject]@{ Time = $t; Port = $a.Port; TimeToDropSec = $ttd }
                $ports[$a.Port].Drops++; $ports[$a.Port].TimeToDropSec += $ttd
            }
        }
    }
    foreach ($e in $read) { if ($e.Port -and $ports.ContainsKey($e.Port)) { $ports[$e.Port].ReadErrors++ } }
    $caps = @($mine | Where-Object { $_.Capacity -gt 0 } | ForEach-Object { [int64]$_.Capacity } | Sort-Object -Unique)
    $last = $mine | Select-Object -Last 1
    $failPorts = @($ports.Values | Where-Object { $_.Drops -gt 0 -or $_.ReadErrors -gt 0 })
    [pscustomobject]@{
        Key = $Key; Model = $(if ($last) { $last.Model } else { '' }); Serial = $(if ($last) { $last.Serial } else { '' })
        Connects = @($mine | Where-Object { $_.Capacity -gt 0 }).Count; ReadErrors = $read.Count; SurpriseRemovals = @($errs | Where-Object Kind -eq 'SurpriseRemoved').Count
        DropsAfterErrors = $drops.Count; Drops = $drops; DropTimes = @($drops | ForEach-Object Time); ErrorTimes = @($read | ForEach-Object { $_.Time })
        PartMgr = @($errs | Where-Object { $_.Kind -like 'PartMgr*' }); Ports = @($ports.Values); FailingPorts = $failPorts
        Capacities = $caps; CapacityChanged = ($caps.Count -gt 1)
        LastSeen = $(if ($last) { $last.Time } else { $null }); Capacity = $(if ($caps) { $caps[-1] } else { 0 })
    }
}

# ------------------------------------------------------------------ local history (Tier 0 memory across ports, machines and days)
function ConvertTo-HashtableDeep($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @(foreach ($x in $o) { ConvertTo-HashtableDeep $x }) }
    $o
}

function Get-UDHistory {
    $h = $null
    if (Test-Path -LiteralPath $script:HistoryFile) { try { $h = ConvertTo-HashtableDeep (Get-Content -LiteralPath $script:HistoryFile -Raw | ConvertFrom-Json) } catch { $h = $null } }
    if (-not $h) { $h = @{ Version = 1; Devices = @{} } }
    if (-not $h.Devices) { $h.Devices = @{} }
    $h
}

function Save-UDHistory($h) {
    $dir = Split-Path $script:HistoryFile; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$($script:HistoryFile).tmp"
    ($h | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:HistoryFile -Force
    # let a later non-elevated run (diagnose) keep updating it
    if (Test-IsAdmin) { & icacls.exe $script:HistoryFile /grant '*S-1-5-32-545:M' /Q 2>$null | Out-Null }
}

function Get-DeviceRecord($h, [string]$Id, [string]$Model) {
    if (-not $h.Devices.ContainsKey($Id)) { $h.Devices[$Id] = @{ Id = $Id; Model = $Model; FirstSeen = (Get-Date).ToString('s') } }
    $r = $h.Devices[$Id]
    foreach ($k in 'Ports') { if (-not $r[$k]) { $r[$k] = @{} } }
    foreach ($k in 'Tier0', 'ReadOnlyClears', 'Images', 'RawReads') { if ($null -eq $r[$k]) { $r[$k] = @() } else { $r[$k] = @($r[$k]) } }
    if ($Model) { $r.Model = $Model }
    $r
}

function Update-DeviceHistory([string]$Id, [string]$Model, [scriptblock]$Change) {
    if (-not $Id) { return $null }
    try {
        $h = Get-UDHistory
        $r = Get-DeviceRecord $h $Id $Model
        & $Change $r
        $r.LastSeen = (Get-Date).ToString('s')
        Save-UDHistory $h
        $r
    } catch { Write-UDLog "Could not update history file $($script:HistoryFile): $($_.Exception.Message)" 'WARN'; $null }
}

function Get-DeviceHistoryRecord([string]$Id) { $h = Get-UDHistory; if ($Id -and $h.Devices.ContainsKey($Id)) { Get-DeviceRecord $h $Id '' } else { $null } }

function Get-DeviceImage([string]$Id) {
    $r = Get-DeviceHistoryRecord $Id
    if (-not $r) { return $null }
    @($r.Images | Where-Object { $_.Complete -and $_.Path -and (Test-Path -LiteralPath $_.Path) }) | Select-Object -Last 1
}

function Set-Tier0Result {
    # Record what happened on another port or machine, so verdicts stop being provisional.
    param([int]$DiskNumber = -1, [string]$Device, [ValidateSet('OtherPortFails', 'OtherPortWorks', 'OtherMachineFails', 'OtherMachineWorks')][string]$Result, [string]$Note)
    if ($DiskNumber -ge 0) { $d = @(Get-UsbDisks) | Where-Object { $_.Number -eq $DiskNumber }; if (-not $d) { throw "Disk $DiskNumber is not an attached USB disk." }; $id = $d.Identity; $model = $d.Model }
    elseif ($Device) { $id = $Device; $model = '' }
    else { throw 'Use -Disk N or -Device <identity or instance ID>.' }
    $r = Update-DeviceHistory $id $model { param($r) $r.Tier0 = @($r.Tier0) + @(@{ Time = (Get-Date).ToString('s'); Result = $Result; Note = $Note; Machine = $env:COMPUTERNAME }) }
    Write-UDLog "Tier 0 result recorded for ${id}: $Result $Note"
    [pscustomobject]@{ Identity = $id; Result = $Result; Recorded = [bool]$r }
}

# ------------------------------------------------------------------ timed probes
function Invoke-WithTimeout([scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$TimeoutMs = 10000) {
    # Runs in a separate runspace; a hung native call (dying stick, sick WMI) is abandoned instead of hanging USBDoctor.
    $ps = [powershell]::Create(); [void]$ps.AddScript($Script); foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $h = $ps.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        $out = $null; $err = ''
        try { $out = $ps.EndInvoke($h); if ($ps.Streams.Error.Count) { $err = "$($ps.Streams.Error[0])" } } catch { $err = $_.Exception.Message } finally { $ps.Dispose() }
        return [pscustomobject]@{ Completed = $true; Ms = $sw.ElapsedMilliseconds; Output = $out; Error = $err }
    }
    [pscustomobject]@{ Completed = $false; Ms = $sw.ElapsedMilliseconds; Output = $null; Error = "timed out after $([int]($TimeoutMs / 1000)) s" }
}

function Test-RawRead([int]$Number, [int]$TimeoutMs = 10000) {
    # #3: read-only raw read of the first 64 KiB with a timeout. Completes -> media answers (file system issue);
    # times out / errors / disk vanishes -> dying media.
    if (-not (Test-IsAdmin)) { return [pscustomobject]@{ Result = 'Skipped'; Ms = 0; Detail = 'needs administrator' } }
    if ($script:TestHooks.RawTimeoutDisk -eq $Number) { return [pscustomobject]@{ Result = 'Timeout'; Ms = $TimeoutMs; Detail = 'simulated timeout (test hook)' } }
    $r = Invoke-WithTimeout {
        param($n)
        $h = [UsbDocNative]::OpenDisk($n, $false)
        try { $b = New-Object byte[] 65536; $e = 0; $got = [UsbDocNative]::ReadAt($h, [int64]0, $b, 65536, 0, [ref]$e); $len = [UsbDocNative]::GetLength($h); , @($got, $e, $len) } finally { $h.Close() }
    } @($Number) $TimeoutMs
    if (-not $r.Completed) { return [pscustomobject]@{ Result = 'Timeout'; Ms = $r.Ms; Detail = $r.Error } }
    if ($r.Error -and -not $r.Output) { return [pscustomobject]@{ Result = 'Error'; Ms = $r.Ms; Detail = $r.Error } }
    $o = @($r.Output)[0]
    if ([int]$o[0] -ne 65536) { return [pscustomobject]@{ Result = 'Error'; Ms = $r.Ms; Detail = "read failed (Win32 error $($o[1]))" } }
    if ([int64]$o[2] -le 0) { return [pscustomobject]@{ Result = 'Vanished'; Ms = $r.Ms; Detail = 'the drive reported 0 bytes after the read' } }
    [pscustomobject]@{ Result = 'OK'; Ms = $r.Ms; Detail = "first 64 KiB read in $($r.Ms) ms" }
}

function Test-VolumeAccess([string]$Letter) {
    # #9: can we list the root and open each top-level folder? Denials on a readable volume = NTFS permissions, not damage.
    $r = Invoke-WithTimeout {
        param($L)
        $denied = @(); $ok = 0; $rootDenied = $false
        try { $items = @([IO.Directory]::GetDirectories("${L}:\")) } catch [UnauthorizedAccessException] { $rootDenied = $true; $items = @() }
        foreach ($p in ($items | Select-Object -First 60)) {
            $n = Split-Path $p -Leaf
            if ($n -in 'System Volume Information', '$RECYCLE.BIN', 'Recycler', 'Config.Msi') { continue }
            try { $e = [IO.Directory]::EnumerateFileSystemEntries($p).GetEnumerator(); [void]$e.MoveNext(); $ok++ } catch [UnauthorizedAccessException] { $denied += $p } catch {}
        }
        [pscustomobject]@{ RootDenied = $rootDenied; Denied = $denied; Checked = $ok + $denied.Count }
    } @($Letter) 10000
    if (-not $r.Completed) { return [pscustomobject]@{ RootDenied = $false; Denied = @(); Checked = 0; TimedOut = $true } }
    $o = @($r.Output)[0]; $o | Add-Member TimedOut $false -PassThru
}

function Test-MachineHealth {
    # Tier 0, machine side: is this PC's WMI/storage/USB stack healthy enough to blame a drive?
    $f = New-Object System.Collections.Generic.List[object]
    $w = Invoke-WithTimeout { Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 | Select-Object -ExpandProperty LastBootUpTime } @() 12000
    $sick = $false
    if (-not $w.Completed) { $sick = $true; $f.Add((New-Finding WARN 'WmiHang' 'WMI did not answer within 12 s. This PC has a sick management stack; drive verdicts are provisional until confirmed on another PC.')) }
    elseif ($w.Ms -gt 5000) { $sick = $true; $f.Add((New-Finding WARN 'WmiSlow' "WMI took $([int]($w.Ms / 1000)) s to answer (normal is under 1 s). Confirm failures on another PC before condemning a drive.")) }
    else { $f.Add((New-Finding OK 'WmiOk' "WMI answers normally ($($w.Ms) ms).")) }
    if ($script:LastGetDiskMs -gt 30000) { $f.Add((New-Finding WARN 'StorageSlow' "Listing disks took $([int]($script:LastGetDiskMs / 1000)) s (storage management service is slow on this PC).")) }
    $svc = $null; try { $svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -ErrorAction Stop } catch {}
    $drv = Join-Path $env:SystemRoot 'System32\drivers\USBSTOR.SYS'
    if (-not $svc) { $sick = $true; $f.Add((New-Finding PROBLEM 'UsbStorMissing' 'The USB mass-storage driver service (USBSTOR) is missing. No USB stick can work on this PC.')) }
    elseif ([int]$svc.Start -eq 4) { $sick = $true; $f.Add((New-Finding PROBLEM 'UsbStorDisabled' 'The USB mass-storage driver (USBSTOR) is disabled (Start=4, usually a policy). USB sticks enumerate but never become disks (#2). Ask whoever set the policy, or set HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR\Start to 3.')) }
    elseif (-not (Test-Path $drv)) { $sick = $true; $f.Add((New-Finding PROBLEM 'UsbStorFile' "USBSTOR.SYS is missing from $drv.")) }
    else { $f.Add((New-Finding OK 'UsbStorOk' "USB mass-storage driver present (Start=$($svc.Start)).")) }
    $hc = @(Get-PnpDevice -Class USB -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.FriendlyName)" -match 'Host Controller|Root Hub' -and "$($_.Status)" -ne 'OK' })
    foreach ($x in $hc) { $sick = $true; $f.Add((New-Finding PROBLEM 'HostController' "USB controller/root hub '$($x.FriendlyName)' is in an error state. That's the PC, not the drive.")) }
    [pscustomobject]@{ Findings = $f.ToArray(); Sick = $sick; WmiMs = $w.Ms; WmiCompleted = $w.Completed }
}

# ------------------------------------------------------------------ boot sector / file system identification (#5)
function Read-DiskBytes([int]$Number, [int64]$Offset, [int]$Count) {
    $h = [UsbDocNative]::OpenDisk($Number, $false)
    try { $b = New-Object byte[] $Count; $e = 0; $n = [UsbDocNative]::ReadAt($h, [int64]$Offset, $b, $Count, 15000, [ref]$e); if ($n -ne $Count) { throw "read at $Offset failed (Win32 error $e)" }; , $b } finally { $h.Close() }
}
function Get-Ascii([byte[]]$b, [int]$o, [int]$n) { [Text.Encoding]::ASCII.GetString($b, $o, $n) }

function Test-BootSector([byte[]]$b, [int]$o, [string]$Kind) {
    # Sanity-check a boot sector of the given kind at offset o inside buffer b.
    if ($b[$o + 510] -ne 0x55 -or $b[$o + 511] -ne 0xAA) { return $false }
    $bps = [BitConverter]::ToUInt16($b, $o + 11)
    switch ($Kind) {
        'NTFS' { return ((Get-Ascii $b ($o + 3) 8) -eq 'NTFS    ' -and $bps -in 512, 1024, 2048, 4096 -and [BitConverter]::ToInt64($b, $o + 0x28) -gt 0) }
        'FAT32' { return ((Get-Ascii $b ($o + 82) 8) -eq 'FAT32   ' -and $bps -in 512, 1024, 2048, 4096 -and $b[$o + 13] -gt 0) }
        'exFAT' { return ((Get-Ascii $b ($o + 3) 8) -eq 'EXFAT   ') }
    }
    $false
}

function Get-PartitionFsInfo([int]$Number, [int64]$Offset, [int64]$Size) {
    # Identify what is really in a partition Windows calls RAW, and whether a damaged NTFS/FAT32/exFAT boot sector has a good backup.
    $r = [ordered]@{ Kind = 'Unknown'; Name = ''; PrimaryValid = $false; BackupValid = $false; BackupOffset = [int64]-1; BackupSectors = 0; Detail = '' }
    try { $b = Read-DiskBytes $Number $Offset 8192 } catch { $r.Kind = 'Unreadable'; $r.Detail = $_.Exception.Message; return [pscustomobject]$r }
    $oem = Get-Ascii $b 3 8
    $foreign = $null
    if ($oem -eq '-FVE-FS-') { $r.Kind = 'BitLocker'; $r.Name = 'BitLocker-encrypted volume'; return [pscustomobject]$r }
    if ($oem.StartsWith('ReFS')) { $foreign = 'ReFS' }
    elseif ([BitConverter]::ToUInt16($b, 1080) -eq 0xEF53) { $foreign = 'Linux ext2/ext3/ext4' }
    elseif ((Get-Ascii $b 32 4) -eq 'NXSB') { $foreign = 'Apple APFS' }
    elseif ((Get-Ascii $b 1024 2) -in 'H+', 'HX') { $foreign = 'Apple HFS+' }
    elseif ((Get-Ascii $b 0 4) -eq 'XFSB') { $foreign = 'Linux XFS' }
    elseif ((Get-Ascii $b 0 4) -eq 'LUKS' -and $b[4] -eq 0xBA -and $b[5] -eq 0xBE) { $foreign = 'Linux LUKS (encrypted)' }
    elseif ([BitConverter]::ToUInt32($b, 1024) -eq 0xF2F52010) { $foreign = 'Linux F2FS' }
    elseif ((Get-Ascii $b 4086 10) -eq 'SWAPSPACE2') { $foreign = 'Linux swap' }
    if (-not $foreign -and $Size -gt 70000) {
        try { $b2 = Read-DiskBytes $Number ($Offset + 65536) 4096; if ((Get-Ascii $b2 64 8) -eq '_BHRfS_M') { $foreign = 'Linux Btrfs' } } catch {}
        try { $b3 = Read-DiskBytes $Number ($Offset + 32768) 4096; if ((Get-Ascii $b3 1 5) -eq 'CD001') { $foreign = 'ISO 9660 (CD/DVD image)' } } catch {}
    }
    if ($foreign) { $r.Kind = 'Foreign'; $r.Name = $foreign; return [pscustomobject]$r }
    $allZero = $true; for ($i = 0; $i -lt 512; $i++) { if ($b[$i] -ne 0) { $allZero = $false; break } }
    foreach ($k in 'NTFS', 'FAT32', 'exFAT') { if (Test-BootSector $b 0 $k) { $r.Kind = $k; $r.PrimaryValid = $true; return [pscustomobject]$r } }
    # primary is not valid: look for backups
    try { $last = Read-DiskBytes $Number ($Offset + $Size - 512) 512; if (Test-BootSector $last 0 'NTFS') { $r.Kind = 'NTFS'; $r.BackupValid = $true; $r.BackupOffset = $Offset + $Size - 512; $r.BackupSectors = 1 } } catch {}
    if (-not $r.BackupValid -and (Test-BootSector $b 3072 'FAT32')) { $r.Kind = 'FAT32'; $r.BackupValid = $true; $r.BackupOffset = $Offset + 3072; $r.BackupSectors = 3 }
    if (-not $r.BackupValid -and (Test-BootSector $b 6144 'exFAT')) { $r.Kind = 'exFAT'; $r.BackupValid = $true; $r.BackupOffset = $Offset + 6144; $r.BackupSectors = 12 }
    if (-not $r.BackupValid) { $r.Kind = $(if ($allZero) { 'Empty' } else { 'Unknown' }) }
    [pscustomobject]$r
}

# ------------------------------------------------------------------ GPT headers (#11)
function Read-GptHeader([byte[]]$b) {
    if ((Get-Ascii $b 0 8) -ne 'EFI PART') { return $null }
    $hs = [int][BitConverter]::ToUInt32($b, 12); if ($hs -lt 92 -or $hs -gt 512) { return $null }
    $c = New-Object byte[] $hs; [Array]::Copy($b, 0, $c, 0, $hs); for ($i = 16; $i -lt 20; $i++) { $c[$i] = 0 }
    [pscustomobject]@{ Raw = $b; HeaderSize = $hs; CrcOk = ([UsbDocNative]::Crc32($c, 0, $hs) -eq [BitConverter]::ToUInt32($b, 16))
        MyLba = [BitConverter]::ToInt64($b, 24); AltLba = [BitConverter]::ToInt64($b, 32); EntryLba = [BitConverter]::ToInt64($b, 72)
        Entries = [int][BitConverter]::ToUInt32($b, 80); EntrySize = [int][BitConverter]::ToUInt32($b, 84); EntriesCrc = [BitConverter]::ToUInt32($b, 88) }
}

function Get-GptInfo([int]$Number, [int64]$DiskSize) {
    $r = [ordered]@{ ProtectiveMbr = $false; PrimaryValid = $false; BackupValid = $false; BackupLba = [int64]0; Detail = ''; Backup = $null; BackupEntries = $null }
    try {
        $s0 = Read-DiskBytes $Number 0 1024
        $r.ProtectiveMbr = ($s0[510] -eq 0x55 -and $s0[511] -eq 0xAA -and $s0[446 + 4] -eq 0xEE)
        $last = [int64]($DiskSize / 512) - 1; $r.BackupLba = $last
        foreach ($which in 'Primary', 'Backup') {
            $lba = if ($which -eq 'Primary') { [int64]1 } else { $last }
            if ($which -eq 'Primary') { $hb = New-Object byte[] 512; [Array]::Copy($s0, 512, $hb, 0, 512) } else { $hb = Read-DiskBytes $Number ($last * 512) 512 }
            $h = Read-GptHeader $hb
            $ok = $false; $ents = $null
            if ($h -and $h.CrcOk -and $h.MyLba -eq $lba -and $h.Entries -gt 0 -and $h.Entries -le 1024 -and $h.EntrySize -ge 128 -and $h.EntrySize -le 1024) {
                $len = $h.Entries * $h.EntrySize; $len = [int]([Math]::Ceiling($len / 512.0) * 512)
                $ents = Read-DiskBytes $Number ($h.EntryLba * 512) $len
                $ok = ([UsbDocNative]::Crc32($ents, 0, $h.Entries * $h.EntrySize) -eq $h.EntriesCrc)
            }
            if ($which -eq 'Primary') { $r.PrimaryValid = $ok } else { $r.BackupValid = $ok; if ($ok) { $r.Backup = $h; $r.BackupEntries = $ents } }
        }
    } catch { $r.Detail = $_.Exception.Message }
    [pscustomobject]$r
}

# ------------------------------------------------------------------ diagnosis
function New-Finding([string]$Level, [string]$Code, [string]$Text, [string]$Fix = '') {
    [pscustomobject]@{ Level = $Level; Code = $Code; Text = $Text; Fix = $Fix }
}
$script:LevelRank = @{ OK = 0; INFO = 1; WARN = 2; PROBLEM = 3; FAILING = 4 }

function Get-MbrEntries([byte[]]$Buf, [int]$Base) {
    for ($i = 0; $i -lt 4; $i++) {
        $e = $Base + 446 + 16 * $i
        $type = $Buf[$e + 4]; $lba = [BitConverter]::ToUInt32($Buf, $e + 8); $cnt = [BitConverter]::ToUInt32($Buf, $e + 12)
        if ($type -ne 0 -and $cnt -gt 0) {
            [pscustomobject]@{ Index = $i + 1; Type = ('0x{0:X2}' -f $type); StartLba = [int64]$lba; Sectors = [int64]$cnt; EndByte = ([int64]$lba + [int64]$cnt) * 512 }
        }
    }
}

function Get-BootSectorInfo([int]$Number) {
    # Raw read of the first 4 KiB (administrator only). Detects normal MBR/GPT and the ImageUSB 512-byte shift.
    $r = [ordered]@{ Read = $false; Error = ''; Sig510 = $false; Sig1022 = $false; ImageUsbText = $false; Gpt = $false; GptShifted = $false
        Partitions0 = @(); Partitions1 = @(); ShiftNeededBytes = [int64]0 }
    if (-not (Test-IsAdmin)) { $r.Error = 'skipped (needs administrator)' }
    else {
        $h = $null
        try {
            $h = [UsbDocNative]::OpenDisk($Number, $false)
            $buf = New-Object byte[] 4096; $err = 0
            $n = [UsbDocNative]::ReadAt($h, [int64]0, $buf, 4096, 15000, [ref]$err)
            if ($n -ne 4096) { $r.Error = "reading the first sectors failed (Win32 error $err)" }
            else {
                $r.Read = $true
                $r.Sig510 = ($buf[510] -eq 0x55 -and $buf[511] -eq 0xAA)
                $r.Sig1022 = ($buf[1022] -eq 0x55 -and $buf[1023] -eq 0xAA)
                $r.ImageUsbText = ([Text.Encoding]::ASCII.GetString($buf, 0, 512) -match 'imageUSB')
                $r.Gpt = ([Text.Encoding]::ASCII.GetString($buf, 512, 8) -eq 'EFI PART')
                $r.GptShifted = ([Text.Encoding]::ASCII.GetString($buf, 1024, 8) -eq 'EFI PART')
                if ($r.Sig510) { $r.Partitions0 = @(Get-MbrEntries $buf 0) }
                if ($r.Sig1022) {
                    $r.Partitions1 = @(Get-MbrEntries $buf 512)
                    if ($r.Partitions1.Count) { $r.ShiftNeededBytes = [int64](($r.Partitions1 | Measure-Object EndByte -Maximum).Maximum) + 512 }
                }
            }
        } catch { $r.Error = $_.Exception.Message } finally { if ($h) { $h.Close() } }
    }
    [pscustomobject]$r
}

function Test-ImageUsbShift($Boot) { $Boot.Read -and $Boot.Sig1022 -and $Boot.ImageUsbText -and -not $Boot.Sig510 -and $Boot.Partitions1.Count -gt 0 }

function Get-DirtyState([string]$Letter) {
    $o = & fsutil.exe dirty query "${Letter}:" 2>&1 | Out-String
    if ($o -match 'is NOT Dirty') { return $false }
    if ($o -match 'is Dirty') { return $true }
    $null
}

function Get-DosDeviceEntries {
    $out = @()
    $k = Get-Item 'HKLM:\SYSTEM\MountedDevices' -ErrorAction SilentlyContinue
    if (-not $k) { return $out }
    foreach ($n in $k.GetValueNames()) {
        if ($n -match '^\\DosDevices\\([A-Z]):$') {
            $e = ConvertFrom-MountedDeviceData ([byte[]]$k.GetValue($n))
            $e | Add-Member Letter $Matches[1]; $out += $e
        }
    }
    $out
}

$script:DyingCodes = @('RawReadTimeout', 'RawReadError', 'Vanished', 'DisconnectDuringRead', 'CapacityFlap', 'ZeroCapacity', 'ReadOnlyReturned', 'Unreadable')

function Get-DyingSignatures($d, $hs, $rec, $raw) {
    # The catalog's dying-media signatures. Any one of these = "dying - image what you can, do not repair".
    $f = @()
    if ($raw.Result -eq 'Timeout') { $f += New-Finding FAILING 'RawReadTimeout' "A read-only raw read of the first sectors did not finish ($($raw.Detail)). Detection that never completes = dying media (#3)." 'Rescue' }
    elseif ($raw.Result -eq 'Error') { $f += New-Finding FAILING 'RawReadError' "A read-only raw read of the first sectors failed: $($raw.Detail). The media is not answering reliably (#3)." 'Rescue' }
    elseif ($raw.Result -eq 'Vanished') { $f += New-Finding FAILING 'Vanished' "The drive dropped to 0 bytes during the read-only check (#15)." 'Rescue' }
    if ([int64]$d.Size -le 0) { $f += New-Finding FAILING 'ZeroCapacity' 'The drive reports 0 bytes capacity (#15: drops to zero after replug).' 'Rescue' }
    if ($hs -and $hs.DropsAfterErrors -gt 0) {
        $ttd = @($hs.Drops | ForEach-Object { if ($_.TimeToDropSec -ge 0) { "$($_.TimeToDropSec) s" } }) -join ', '
        $np = @($hs.FailingPorts).Count
        $f += New-Finding FAILING 'DisconnectDuringRead' ("It disconnected right after read errors {0} time(s) in the event log (time from plug-in to drop: {1}); {2} port(s) affected. A drive that drops out while reading is dying." -f $hs.DropsAfterErrors, $(if ($ttd) { $ttd } else { 'unknown' }), $np) 'Rescue'
    }
    if ($hs -and $hs.CapacityChanged) { $f += New-Finding FAILING 'CapacityFlap' ("Windows has seen this stick with different capacities: {0}. Capacity that changes or shrinks = failing controller (#15) (or two different sticks with the same IDs)." -f ((@($hs.Capacities) | ForEach-Object { Format-Bytes $_ }) -join ', ')) 'Rescue' }
    if ($rec -and @($rec.ReadOnlyClears).Count -and $d.ReadOnly) { $f += New-Finding FAILING 'ReadOnlyReturned' "Read-only came back after USBDoctor cleared it on $(@($rec.ReadOnlyClears)[-1].Time). Flash that re-locks itself is worn out: copy only (#8)." 'Rescue' }
    $f
}

function Get-GateStatus($d, [string]$Kind, $Dying = $null, $Raw = $null, $Rec = $null) {
    # Decides whether a write of this kind is allowed, refused, or needs image/typed risk acceptance.
    if ($null -eq $Rec) { $Rec = Get-DeviceHistoryRecord $d.Identity }
    if ($null -eq $Raw) { $Raw = Test-RawRead $d.Number }
    if ($null -eq $Dying) { $hs = if ($d.Identity) { Get-DeviceHistorySummary (Get-UsbEventHistory 7) $d.Identity } else { $null }; $Dying = @(Get-DyingSignatures $d $hs $Rec $Raw) }
    $refusal = ''
    if ($Kind -ne 'Letter') {
        if (@($Dying).Count) { $refusal = "dying - image what you can, do not repair ($((@($Dying) | ForEach-Object { $_.Code }) -join ', ')). USBDoctor never runs a write repair on a drive that disconnects or times out during read-only diagnosis." }
        elseif ($Kind -in 'Chkdsk', 'BootSector' -and $Raw.Result -notin 'OK', 'Skipped') { $refusal = 'the raw first-sector read did not complete; chkdsk / boot-sector repair would make it worse.' }
        elseif ($Kind -eq 'Extend' -and $Rec -and $Rec.Counterfeit) { $refusal = "this stick failed the capacity test (counterfeit). Its real size is about $(Format-Bytes ([int64]$Rec.Counterfeit.GoodBytes)); 'repairing' capacity is impossible." }
        elseif ($Kind -eq 'ClearReadOnly' -and $Rec -and @($Rec.ReadOnlyClears).Count -and $d.ReadOnly) { $refusal = 'read-only already came back once after clearing. Clearing it a second time is refused: copy only.' }
    }
    $img = if ($Kind -in 'Letter', 'Capacity') { $null } else { Get-DeviceImage $d.Identity }
    [pscustomobject]@{ Kind = $Kind; Refusal = $refusal; Image = $img; NeedsPhrase = ($Kind -notin 'Letter', 'Capacity' -and -not $img); Raw = $Raw; Dying = @($Dying) }
}

function Assert-WriteGate($d, [string]$Kind, [string]$ConfirmPhrase, [switch]$Preview) {
    $g = Get-GateStatus $d $Kind
    if ($g.Refusal) { throw "REFUSED on disk $($d.Number): $($g.Refusal)" }
    if (-not $Preview -and $g.NeedsPhrase -and $ConfirmPhrase -ne "REPAIR $($d.Number)") {
        throw "No complete Rescue image of disk $($d.Number) exists. Make one first (-Rescue -Disk $($d.Number)) or accept the risk by typing REPAIR $($d.Number)."
    }
    if ($g.Image) { Write-UDLog "Gate ${Kind}: image on file $($g.Image.Path) ($($g.Image.Time))." }
    elseif ($g.NeedsPhrase -and -not $Preview) { Write-UDLog "Gate ${Kind}: no image; risk accepted with typed phrase." 'WARN' }
    $g
}

function Get-GateText($g, [int]$Number) {
    if ($g.Refusal) { return "REFUSED: $($g.Refusal)" }
    if ($g.Image) { return "Rescue image on file: $($g.Image.Path) ($($g.Image.Time)), so no typed risk phrase is needed." }
    if ($g.NeedsPhrase) { return "No Rescue image of this drive exists. Image it first (Rescue copy), or type REPAIR $Number to accept the risk of writing without one." }
    ''
}

function Get-DiskDiagnosis($d, $Hist, $Auto, [bool]$IsAdmin, $Machine) {
    $f = New-Object System.Collections.Generic.List[object]
    $hs = if ($d.Identity) { Get-DeviceHistorySummary $Hist $d.Identity } else { $null }
    $rec = Get-DeviceHistoryRecord $d.Identity

    # ---- Tier 1: does the media answer at all? (timed, read-only)
    $raw = Test-RawRead $d.Number
    if ($raw.Result -eq 'Skipped') { $f.Add((New-Finding INFO 'RawCheck' 'Raw first-sector read skipped (needs administrator), so dying-media detection is based on the event log only.')) }
    foreach ($x in @(Get-DyingSignatures $d $hs $rec $raw)) { $f.Add($x) }
    $rawOk = ($raw.Result -eq 'OK')
    if ($hs -and $hs.ReadErrors -gt 0 -and $hs.DropsAfterErrors -eq 0) { $f.Add((New-Finding WARN 'ReadRetries' ("{0} read error/retry event(s) in the last {1} days (latest {2}). Keep a copy of anything important." -f $hs.ReadErrors, $Hist.Days, ($hs.ErrorTimes | Select-Object -Last 1)))) }
    if ($hs -and $hs.SurpriseRemovals -gt 0) { $f.Add((New-Finding INFO 'SurpriseRemoval' "Removed without Eject $($hs.SurpriseRemovals) time(s) in the last $($Hist.Days) days (#14). Use Safe eject; if it drops by itself, use a rear port directly on the PC, no hub or extension cable." 'Eject')) }
    if ($hs) { foreach ($p in $hs.PartMgr) { $f.Add((New-Finding WARN 'PartMgr' "partmgr $($p.Id) at $($p.Time): $($p.Message)")) } }
    if ($rec -and $rec.Counterfeit) { $f.Add((New-Finding FAILING 'Counterfeit' ("Capacity test on {0}: only about {1} of the claimed {2} really stores data. Counterfeit stick - condemned (#13)." -f $rec.Counterfeit.Time, (Format-Bytes ([int64]$rec.Counterfeit.GoodBytes)), (Format-Bytes ([int64]$rec.Counterfeit.Claimed))) 'Rescue')) }

    # ---- disk state
    if ($d.Offline) {
        $coll = ("$($d.OfflineReason)" -match 'Collision') -or ($hs -and @($hs.PartMgr | Where-Object { $_.Id -eq 58 }).Count)
        if ($coll) { $f.Add((New-Finding PROBLEM 'OfflineCollision' 'Disk is offline because its disk signature collides with another disk (usually a clone). Bringing it online makes Windows write a NEW signature into the MBR; letter records and boot entries keyed to the old signature stop matching (#4).' 'Online')) }
        else { $f.Add((New-Finding PROBLEM 'Offline' "Disk is offline (reason: $($d.OfflineReason)), so Windows shows no drive letter (#4)." 'Online')) }
    }
    if ($d.ReadOnly -and -not ($rec -and @($rec.ReadOnlyClears).Count)) { $f.Add((New-Finding PROBLEM 'ReadOnly' 'Disk is read-only (#8). Check for a lock switch first. Clearing it is tracked: if it comes back after a replug, the flash is worn out and USBDoctor will not clear it again.' 'ClearReadOnly')) }
    foreach ($v in @($d.Volumes | Where-Object PartReadOnly)) { $f.Add((New-Finding PROBLEM 'PartReadOnly' "Partition $($v.PartitionNumber) is marked read-only (#8)." 'ClearReadOnly')) }
    if ($d.Health -and $d.Health -ne 'Healthy') { $f.Add((New-Finding WARN 'Health' "Windows reports disk health '$($d.Health)' ($($d.OperationalStatus)).")) }

    # ---- partition table (raw reads only if the media answered)
    $boot = $null; $shift = $false
    if ($rawOk) {
        $boot = Get-BootSectorInfo $d.Number
        $shift = Test-ImageUsbShift $boot
        if ($shift) {
            $f.Add((New-Finding PROBLEM 'ImageUsbShift' ("The partition table starts 512 bytes late: sector 0 holds an ImageUSB header and the real MBR is in sector 1 (an ImageUSB .bin written raw). {0} partition(s) are intact. Fix: image the stick, strip the 512-byte header from the image file, burn the clean image with USBImager. The stick itself is not rewritten." -f $boot.Partitions1.Count) 'FixImageUsbShift'))
        } elseif ($boot.Read -and $boot.Sig1022 -and -not $boot.Sig510) {
            $f.Add((New-Finding WARN 'PossibleShift' 'Sector 1 looks like an MBR but there is no ImageUSB header; USBDoctor will not guess. Image it and inspect the image.'))
        }
        if ($d.PartitionStyle -eq 'GPT' -or ($boot.Read -and $boot.Partitions0.Count -and @($boot.Partitions0 | Where-Object { $_.Type -eq '0xEE' }).Count)) {
            $g = Get-GptInfo $d.Number $d.Size
            if (-not $g.PrimaryValid -and $g.BackupValid -and $g.ProtectiveMbr) { $f.Add((New-Finding PROBLEM 'GptPrimaryDamaged' 'The primary GPT header/partition list is damaged but the backup copy at the end of the disk is good (#11). It can be restored from the backup.' 'RestoreGpt')) }
            elseif (-not $g.PrimaryValid -and $g.BackupValid) { $f.Add((New-Finding PROBLEM 'GptNoPmbr' 'The primary GPT is damaged and the backup is good, but the protective MBR is missing too. Restoring needs an MBR write, which USBDoctor refuses (DiskPilot rule). Image it, then rebuild with USBImager.' 'Rescue')) }
            elseif ($g.PrimaryValid -and -not $g.BackupValid) { $f.Add((New-Finding INFO 'GptBackupDamaged' 'The backup GPT at the end of the disk is damaged; the primary is fine. Windows rewrites the backup the next time partitions change.')) }
            elseif (-not $g.PrimaryValid -and -not $g.BackupValid -and $g.ProtectiveMbr) { $f.Add((New-Finding PROBLEM 'GptLost' 'Both GPT copies are unreadable. Image it (Rescue), recover files from the image, rebuild with USBImager (#12).' 'Rescue')) }
        }
        if ($d.PartitionStyle -eq 'RAW' -and -not $shift -and -not @($f | Where-Object { $_.Code -like 'Gpt*' }).Count) {
            $why = if ($boot.Read -and -not $boot.Sig510) { 'Sector 0 has no MBR signature.' } else { 'The MBR has no partitions.' }
            $f.Add((New-Finding PROBLEM 'NoPartitionTable' "No partition table (#11). $why An MBR has no backup copy, so there is nothing safe to restore, and USBDoctor refuses MBR writes (same rule as DiskPilot). Image it (Rescue), recover files from the image, then rebuild with USBImager." 'Rescue'))
        }
    } elseif ($d.PartitionStyle -eq 'RAW') { $f.Add((New-Finding PROBLEM 'NoPartitionTable' 'No partition table (RAW disk). Run as administrator for the raw checks.' 'Rescue')) }

    # ---- volumes
    $dos = @(Get-DosDeviceEntries)
    foreach ($v in @($d.Volumes | Where-Object { -not $_.FileSystem -or $_.FileSystem -in 'Unknown', 'RAW' })) {
        if ($v.Type -in 'Reserved', 'System', 'Recovery' -or $v.GptType -match 'e3c9e316|de94bba4') { continue }
        if (-not $rawOk) { $f.Add((New-Finding PROBLEM 'RawVolume' ("Partition {0} ({1}) shows as RAW. Run as administrator to identify what is in it." -f $v.PartitionNumber, (Format-Bytes $v.PartSize)) 'Rescue')); continue }
        $fi = Get-PartitionFsInfo $d.Number $v.Offset $v.PartSize
        switch ($fi.Kind) {
            'Foreign' { $f.Add((New-Finding INFO 'ForeignFs' ("Partition {0} holds {1}. The drive is healthy - it is just formatted for another OS, which Windows can't read (#5). Open it on that OS (or a read-only reader app). Do NOT let Windows format it." -f $v.PartitionNumber, $fi.Name))) }
            'BitLocker' { $f.Add((New-Finding INFO 'BitLocker' "Partition $($v.PartitionNumber) is BitLocker-encrypted and locked. Unlock it with its password or recovery key (manage-bde -unlock). Not damage.")) }
            'Unreadable' { $f.Add((New-Finding FAILING 'Unreadable' "Partition $($v.PartitionNumber) start could not be read: $($fi.Detail)." 'Rescue')) }
            'Empty' { $f.Add((New-Finding WARN 'EmptyPartition' "Partition $($v.PartitionNumber) has never been formatted (all zeros) - there is no file system and no data to recover. If you want to use it, set it up with USBImager or DiskPilot; USBDoctor never formats.")) }
            default {
                if ($fi.BackupValid) { $f.Add((New-Finding PROBLEM 'BootSectorDamaged' ("Partition {0}: the {1} boot sector is damaged, but its backup copy is intact (#5). It can be restored from the backup (image first)." -f $v.PartitionNumber, $fi.Kind) 'RestoreBootSector')) }
                elseif ($fi.PrimaryValid) { $f.Add((New-Finding PROBLEM 'FsDamaged' ("Partition {0}: the {1} boot sector looks fine but Windows can't mount it - the file system metadata is damaged. Image it first; then chkdsk on the image copy or rebuild with USBImager (#12)." -f $v.PartitionNumber, $fi.Kind) 'Rescue')) }
                else { $f.Add((New-Finding PROBLEM 'RawUnknown' ("Partition {0} ({1}) has no recognisable file system and no backup boot sector. Image it (Rescue), recover files from the image, then rebuild the stick with USBImager (#12). Formatting is never a repair." -f $v.PartitionNumber, (Format-Bytes $v.PartSize)) 'Rescue')) }
            }
        }
    }
    $fsVols = @($d.Volumes | Where-Object { $_.FileSystem -and $_.FileSystem -notin 'Unknown', 'RAW' })
    foreach ($v in $fsVols) {
        if (-not $v.Letter) {
            $why = if (-not $Auto.Enabled) { ' Automount is off on this PC, which stops new volumes getting letters.' } else { '' }
            $want = @($dos | Where-Object { Test-EntryMatchesVolume $_ $d $v })
            $conf = $null
            foreach ($w in $want) { $use = Get-LetterUse $w.Letter; if ($use) { $conf = "$($w.Letter): is remembered for this volume but is now taken by $use" } }
            if ($conf) { $f.Add((New-Finding PROBLEM 'LetterConflict' ("Partition {0} gets no letter: {1} (#7). Pick another letter, or remove the squatter yourself after checking it (USBDoctor shows mappings, it never deletes them silently)." -f $v.PartitionNumber, $conf) 'AssignLetter')) }
            else { $f.Add((New-Finding PROBLEM 'NoLetter' ("Partition {0} ({1} '{2}', {3}) has no drive letter, so it doesn't show in Explorer (#6).{4}" -f $v.PartitionNumber, $v.FileSystem, $v.Label, (Format-Bytes $v.Size), $why) 'AssignLetter')) }
        } else {
            if ([int64]$v.Size -le 0) { $f.Add((New-Finding WARN 'MountIncomplete' "$($v.Letter): exists but reports no size - the volume never finished mounting (#3).")) }
            $dirty = if ($rawOk -or -not $IsAdmin) { Get-DirtyState $v.Letter } else { $null }
            if ($dirty -eq $true) { $f.Add((New-Finding PROBLEM 'Dirty' "$($v.Letter): is marked dirty (not cleanly closed) (#10). chkdsk /f is safe only because the raw read check passed; image first anyway if the data matters." 'Chkdsk')) }
            elseif ($null -eq $dirty -and $rawOk) { $f.Add((New-Finding INFO 'DirtyUnknown' "Could not query the dirty bit on $($v.Letter):.")) }
            if ($rawOk -or -not $IsAdmin) {
                $acc = Test-VolumeAccess $v.Letter
                if ($acc.TimedOut) { $f.Add((New-Finding WARN 'ListingSlow' "Listing $($v.Letter):\ took more than 10 s.")) }
                elseif ($acc.RootDenied -or @($acc.Denied).Count) {
                    $ex = if ($acc.RootDenied) { "$($v.Letter):\" } else { @($acc.Denied)[0] }
                    $f.Add((New-Finding PROBLEM 'AccessDenied' ("Access denied on {0} of {1} folder(s) (e.g. {2}) (#9). The disk is fine - these are NTFS permissions from another PC or account. To take them over (administrator prompt): takeown /f ""{2}"" /r /d y  then  icacls ""{2}"" /grant ""%USERNAME%"":F /t. USBDoctor does not change permissions." -f $(if ($acc.RootDenied) { 'the root' } else { @($acc.Denied).Count }), $acc.Checked, $ex)))
                }
            }
        }
        if ($v.Health -and $v.Health -ne 'Healthy') { $f.Add((New-Finding WARN 'VolumeHealth' "Volume $($v.Letter): health is '$($v.Health)'." 'Chkdsk')) }
        if ($v.FileSystem -in 'FAT', 'FAT32' -and $d.LargestFreeExtent -le 16MB) { $f.Add((New-Finding INFO 'Fat32' "$($v.FileSystem) volume: files over 4 GB can't be stored. Convert to NTFS if you need that." 'ConvertToNtfs')) }
        if ($v.Offset % 1MB -ne 0) { $f.Add((New-Finding INFO 'Alignment' ("Partition {0} starts at byte {1:N0} (not 1 MiB aligned). Works, can be slower to write." -f $v.PartitionNumber, $v.Offset))) }
    }
    if ($d.Volumes.Count -and $d.LargestFreeExtent -gt 16MB) {
        $last = $d.Volumes | Sort-Object Offset | Select-Object -Last 1
        $txt = "{0} of the drive is unallocated (partition is smaller than the disk; #13 truncated partition)." -f (Format-Bytes $d.LargestFreeExtent)
        if ($last.FileSystem -in 'NTFS', 'exFAT') { $f.Add((New-Finding WARN 'Unallocated' "$txt Extend the $($last.FileSystem) partition to use it (run the capacity test first if the stick is blank and you doubt its size)." 'Extend')) }
        elseif ($last.FileSystem -in 'FAT', 'FAT32') { $f.Add((New-Finding WARN 'FatCantGrow' "$txt The last partition is $($last.FileSystem), which Windows can't enlarge. Convert it to NTFS (keeps files) and then Extend, or rebuild the stick with USBImager." 'ConvertToNtfs')) }
        else { $f.Add((New-Finding WARN 'Unallocated' $txt)) }
    }

    # ---- identity sanity (fake / generic controllers, #13 hint)
    if (-not $d.Virtual) {
        $vp = "$($d.VID):$($d.PID)"
        if ($d.VID -and $vp -in $script:FakeVidPid) { $f.Add((New-Finding WARN 'FakeId' "USB ID VID_$($d.VID)&PID_$($d.PID) is a placeholder ID used by cheap controllers, often fake-capacity sticks. If it is blank, run the capacity test (#13)." 'CapacityTest')) }
        if ($d.Model -match $script:FakeNames) { $f.Add((New-Finding WARN 'GenericName' "Model '$($d.Model)' is a generic/unbranded controller name.")) }
        if (-not $d.Serial -or $d.Serial -match '^0+$') { $f.Add((New-Finding WARN 'NoSerial' 'The drive reports no serial number (common on unbranded sticks).')) }
        if ($d.UsbInstance -and -not $d.UniqueUsbSerial) { $f.Add((New-Finding INFO 'PortBoundId' "The stick has no unique USB serial, so Windows identifies it by the USB port ($($d.Port)). A fixed drive letter follows it reliably only on this port.")) }
    }

    if (-not $f.Count) { $f.Add((New-Finding OK 'Healthy' 'No problems found.')) }
    $top = ($f | ForEach-Object { $script:LevelRank[$_.Level] } | Measure-Object -Maximum).Maximum
    $lvl = ($script:LevelRank.GetEnumerator() | Where-Object { $_.Value -eq $top }).Key

    # remember where this stick was seen (Tier 0 history); never fatal
    if ($d.Identity) {
        $pk = if ($d.PortKey) { $d.PortKey } else { 'unknown port' }
        $evPorts = if ($hs) { @($hs.Ports) } else { @() }
        $rawRes = $raw.Result; $codesNow = @($f | ForEach-Object { $_.Code })
        $rec2 = Update-DeviceHistory $d.Identity $d.Model {
            param($r)
            if (-not $r.Ports.ContainsKey($pk)) { $r.Ports[$pk] = @{ Hub = [bool]$d.ViaHub; HubName = "$($d.HubName)"; Seen = 0; Connects = 0; ReadErrors = 0; Drops = 0; TimeToDropSec = @() } }
            $r.Ports[$pk].Seen = [int]$r.Ports[$pk].Seen + 1; $r.Ports[$pk].LastSeen = (Get-Date).ToString('s')
            foreach ($ep in $evPorts) {
                $k = if ($ep.Port) { "$($ep.Port)" } else { 'unknown port' }
                if (-not $r.Ports.ContainsKey($k)) { $r.Ports[$k] = @{ Hub = $false; HubName = ''; Seen = 0; Connects = 0; ReadErrors = 0; Drops = 0; TimeToDropSec = @() } }
                $p = $r.Ports[$k]
                $p.Connects = [Math]::Max([int]$p.Connects, [int]$ep.Connects); $p.ReadErrors = [Math]::Max([int]$p.ReadErrors, [int]$ep.ReadErrors); $p.Drops = [Math]::Max([int]$p.Drops, [int]$ep.Drops)
                $p.TimeToDropSec = @(@($p.TimeToDropSec) + @($ep.TimeToDropSec) | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            }
            if ($rawRes -ne 'Skipped') { $r.RawReads = @(@($r.RawReads) + @(@{ Time = (Get-Date).ToString('s'); Result = $rawRes; Port = $pk }) | Select-Object -Last 20) }
            $r.LastCodes = $codesNow; $r.LastSize = [int64]$d.Size
        }
        if ($rec2) { $rec = $rec2 }
    }
    $res = [pscustomobject]@{ Disk = $d; Findings = $f.ToArray(); Level = $lvl; History = $hs; Record = $rec; Boot = $boot; Raw = $raw; Verdict = ''; Assessment = $null }
    $res.Assessment = Get-DiskAssessment $res $Machine
    $res.Verdict = $res.Assessment.State
    $res
}

function Get-DiskAssessment($Res, $Machine, [int]$OtherHealthy = -1) {
    # Catalog output: State -> Fault owner -> Safe action or refusal -> what would have to change.
    $d = $Res.Disk; $f = @($Res.Findings); $codes = @($f | ForEach-Object { $_.Code }); $rec = $Res.Record; $hs = $Res.History; $n = $d.Number
    $dying = @($f | Where-Object { $_.Code -in $script:DyingCodes })
    $problems = @($f | Where-Object { $_.Level -in 'PROBLEM', 'FAILING' })
    $t0 = if ($rec) { @($rec.Tier0) } else { @() }
    $t0Fails = @($t0 | Where-Object { $_.Result -in 'OtherPortFails', 'OtherMachineFails' })
    $t0Works = @($t0 | Where-Object { $_.Result -in 'OtherPortWorks', 'OtherMachineWorks' })
    $histPorts = if ($rec -and $rec.Ports) { @($rec.Ports.Keys | Where-Object { $rec.Ports[$_].Drops -gt 0 -or $rec.Ports[$_].ReadErrors -gt 0 }) } else { @() }
    $evPorts = if ($hs) { @($hs.FailingPorts | ForEach-Object { $_.Port }) } else { @() }
    $failPorts = @(@($histPorts) + @($evPorts) | Where-Object { $_ } | Sort-Object -Unique)
    $driveSide = @($problems | Where-Object { $_.Code -in ($script:DyingCodes + @('Counterfeit', 'ReadOnly', 'PartReadOnly', 'RawVolume', 'RawUnknown', 'FsDamaged', 'BootSectorDamaged', 'GptPrimaryDamaged', 'GptNoPmbr', 'GptLost', 'NoPartitionTable', 'ImageUsbShift', 'Dirty')) })
    $cfgSide = @($problems | Where-Object { $_.Code -in 'NoLetter', 'LetterConflict', 'Offline', 'OfflineCollision' })
    $permOnly = ($problems.Count -gt 0 -and @($problems | Where-Object { $_.Code -ne 'AccessDenied' }).Count -eq 0)
    $provisional = $false
    $owner = 'None - no fault found'
    if ($Machine -and $Machine.Sick -and $problems.Count) { $owner = "Machine (provisional) - this PC's USB/storage stack is unhealthy, see 'This PC'. Confirm on another PC before blaming the drive."; $provisional = $true }
    elseif ($permOnly) { $owner = 'Permissions - the disk is fine; NTFS permissions block access' }
    elseif (-not $problems.Count -and ('ForeignFs' -in $codes -or 'BitLocker' -in $codes)) { $owner = 'None - healthy drive, wrong OS / locked (formatted for another system)' }
    elseif ($driveSide.Count) {
        if ($t0Fails.Count -or $failPorts.Count -ge 2) {
            $why = @(); if ($failPorts.Count -ge 2) { $why += "same failure on $($failPorts.Count) ports" }; if ($t0Fails.Count) { $why += "confirmed: $(($t0Fails | ForEach-Object { $_.Result }) -join ', ')" }
            $owner = "Drive ($($why -join '; '))"
        } elseif ($t0Works.Count) { $owner = "Connection (port, hub or cable) - it worked elsewhere ($(($t0Works | ForEach-Object { $_.Result }) -join ', ')). Avoid this port/hub."; $provisional = $false }
        elseif ($d.ViaHub) { $owner = "Drive or connection (provisional) - it is plugged into a hub ($($d.HubName)). Try a rear port directly on the PC."; $provisional = $true }
        else { $owner = 'Drive (provisional - not yet tried on another port or PC)'; $provisional = $true }
    } elseif ($cfgSide.Count) { $owner = 'Windows configuration on this PC (letters/online state) - not the drive' }
    elseif ($problems.Count) { $owner = 'Drive' }

    $actions = @(); $refusals = @()
    $fixes = @($problems + @($f | Where-Object { $_.Level -eq 'WARN' -and $_.Fix }) | ForEach-Object { $_.Fix } | Where-Object { $_ } | Select-Object -Unique)
    $hasImg = $false; if ($d.Identity) { $hasImg = [bool](Get-DeviceImage $d.Identity) }
    if ($dying.Count) {
        $state = "DYING - image what you can, do not repair ($(($dying | ForEach-Object { $_.Code }) -join ', '))"
        $actions += "Rescue copy now (image with skip-on-error and resume): -Rescue -Disk $n"
        $refusals += 'Every write repair is refused on this drive (it disconnected or timed out during read-only diagnosis).'
        if ('ReadOnlyReturned' -in $codes) { $refusals += 'Clearing read-only a second time is refused: it came back after a replug.' }
        if ('RawReadTimeout' -in $codes -or 'RawReadError' -in $codes) { $refusals += 'chkdsk and boot-sector repair are refused: the raw first-sector read did not complete.' }
        $change = 'Nothing will make USBDoctor repair this stick. Recover files from the image and retire it.'
        if ($provisional) { $change += ' If it reads cleanly on another port or PC (record it with Tier 0), run Diagnose there - the verdict may move to Connection.' }
    } elseif ('Counterfeit' -in $codes) {
        $state = 'COUNTERFEIT capacity - condemned'
        $actions += 'Copy off anything on it (Rescue copy); use it, if at all, only below its real size.'
        $refusals += "Capacity 'repair' (extend) is refused on a counterfeit; the missing flash does not exist."
        $change = 'Nothing - a fake-capacity stick cannot be fixed.'
    } elseif ($problems.Count) {
        $state = 'Needs attention: ' + (($problems | ForEach-Object { $_.Code }) -join ', ')
        foreach ($fx in $fixes) {
            $gated = $fx -in 'Online', 'ClearReadOnly', 'Chkdsk', 'RestoreBootSector', 'RestoreGpt', 'Extend', 'ConvertToNtfs'
            $txt = switch ($fx) {
                'AssignLetter' { "Assign a drive letter (persistent): -AssignLetter -Disk $n -Letter X -Persistent (no image needed)" }
                'Online' { "Bring online: -Online -Disk $n" + $(if ('OfflineCollision' -in $codes) { ' (Windows writes a new disk signature - disclosed before it runs)' } else { '' }) }
                'ClearReadOnly' { "Clear read-only, test-write, then replug and re-diagnose: -ClearReadOnly -Disk $n" }
                'Chkdsk' { "Check disk (chkdsk /f): -Chkdsk -Letter X" }
                'RestoreBootSector' { "Restore the boot sector from its backup: -RestoreBootSector -Disk $n" }
                'RestoreGpt' { "Restore the GPT from the backup header: -RestoreGpt -Disk $n" }
                'Extend' { "Extend the partition: -Extend -Disk $n" }
                'ConvertToNtfs' { "Convert FAT32 to NTFS (keeps files): -ConvertToNtfs -Letter X" }
                'FixImageUsbShift' { "Image + strip the ImageUSB header + burn with USBImager: -FixImageUsbShift -Disk $n -Out <file>.img (the stick is only read)" }
                'Rescue' { "Rescue copy (image): -Rescue -Disk $n" }
                'Eject' { "Safe eject: -Eject -Disk $n" }
                'CapacityTest' { "Capacity test (blank stick only, erases it): -CapacityTest -Disk $n" }
                default { $fx }
            }
            if ($gated -and -not $hasImg) { $txt += ' [image first, or type REPAIR ' + $n + ']' }
            $actions += $txt
        }
        if (-not $actions.Count) { $actions += 'No repair applies; see the findings.' }
        if (@($problems | Where-Object { $_.Code -in 'NoPartitionTable', 'GptNoPmbr' }).Count) { $refusals += 'MBR writes are refused (an MBR has no backup to restore from; DiskPilot rule).' }
        if ('AccessDenied' -in $codes) { $refusals += 'USBDoctor does not change permissions (use takeown/icacls as shown).' }
        $change = if ($driveSide.Count -and -not $hasImg) { "Write repairs unlock once a complete Rescue image of this drive exists (or you type REPAIR $n to accept the risk)." } elseif ($problems.Count) { 'Apply the safe action above, then run Diagnose again.' } else { '-' }
    } else {
        $warn = @($f | Where-Object Level -eq 'WARN')
        $state = if ($warn.Count) { 'Works, with warnings: ' + (($warn | ForEach-Object { $_.Code }) -join ', ') } elseif ('ForeignFs' -in $codes) { 'Healthy drive, wrong OS (file system Windows cannot read)' } else { 'Healthy' }
        foreach ($fx in $fixes) { $actions += "Optional: $fx" }
        if (-not $actions.Count) { $actions += 'None needed.' }
        $change = '-'
    }
    $refusals += 'Formatting is never offered as a repair.'
    $prompt = ''
    if ($provisional) { $prompt = "Tier 0: try another USB port (rear, directly on the PC, no hub/extension) or another PC, then record the result: -Tier0Result OtherPortFails|OtherPortWorks|OtherMachineFails|OtherMachineWorks -Disk $n (GUI: Tier 0 buttons). Until then this verdict is provisional." }
    [pscustomobject]@{ State = $state; FaultOwner = $owner; Actions = $actions; Refusals = $refusals; Change = $change; Provisional = $provisional; Tier0Prompt = $prompt; FailingPorts = $failPorts; Tier0 = $t0 }
}

function Get-ProblemDeviceAssessment($p, $Hist) {
    # #1 Code 43 = hardware, no repair. #2 Code 10/28/31 = driver on this PC: remove device + rescan.
    $ports = @()
    if ($p.InstanceId -match '^USB\\(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { $vp = $Matches[1] }
    if ($p.Code -eq 43 -or $p.FriendlyName -match 'Descriptor Request Failed|Port Reset Failed|Set Address Failed') {
        return [pscustomobject]@{ Device = $p; State = "Code 43 / USB descriptor failed: '$($p.FriendlyName)'"; FaultOwner = 'Drive hardware (or its cable/port) - provisional until tried on another port/PC'
            Action = 'No software repair exists. Try another port and another PC (Tier 0). If it fails everywhere, the stick''s controller is dead; a data-recovery lab is the only option.'; Change = 'Only a working USB handshake on some port/PC would change this.'; Fix = '' }
    }
    if ($p.Code -in 10, 28, 31) {
        return [pscustomobject]@{ Device = $p; State = "Code $($p.Code) (driver could not start / not installed / not working): '$($p.FriendlyName)'"; FaultOwner = 'Machine (driver stack on this PC)'
            Action = "Remove the device and rescan: -ResetDevice -Device ""$($p.InstanceId)"" (also checks USBSTOR driver and start type)."; Change = 'If it still fails after remove+rescan on a PC with a healthy USBSTOR, treat it as the drive.'; Fix = 'ResetDevice' }
    }
    [pscustomobject]@{ Device = $p; State = "$($p.Problem) (code $($p.Code)): '$($p.FriendlyName)'"; FaultOwner = 'Unknown'; Action = 'Try another port; remove and rescan.'; Change = ''; Fix = 'ResetDevice' }
}

function Invoke-UsbDiagnosis {
    param([int]$DiskNumber = -1, [int]$Days = 7)
    $isAdmin = Test-IsAdmin
    $disks = @(Get-UsbDisks)
    if ($DiskNumber -ge 0) {
        $disks = @($disks | Where-Object { $_.Number -eq $DiskNumber })
        if (-not $disks) { throw "Disk $DiskNumber is not an attached USB disk (see -List)." }
    }
    $hist = Get-UsbEventHistory $Days
    $auto = Get-AutomountState
    $ss = Get-SelectiveSuspendState
    $probs = @(Get-UsbProblemDevices)
    $mh = Test-MachineHealth
    $sys = New-Object System.Collections.Generic.List[object]
    foreach ($x in $mh.Findings) { $sys.Add($x) }
    if (-not $auto.Enabled) { $sys.Add((New-Finding PROBLEM 'AutomountOff' 'Automount is OFF (mountmgr NoAutoMount=1): newly plugged-in drives get no drive letter (#6).' 'EnableAutomount')) }
    else { $sys.Add((New-Finding OK 'AutomountOn' 'Automount is on.')) }
    if (-not $ss.Known) { $sys.Add((New-Finding INFO 'SuspendUnknown' 'Could not read the USB selective suspend setting.')) }
    elseif ($ss.Enabled) { $sys.Add((New-Finding WARN 'SelectiveSuspend' "USB selective suspend is ON (AC=$($ss.AC), DC=$($ss.DC)). Windows may cut power to idle USB devices (#14)." 'DisableSelectiveSuspend')) }
    else { $sys.Add((New-Finding OK 'SuspendOff' 'USB selective suspend is off.')) }
    $devAssess = @(foreach ($p in @($probs | Where-Object Kind -eq 'Error')) { Get-ProblemDeviceAssessment $p $hist })
    foreach ($a in $devAssess) { $sys.Add((New-Finding PROBLEM 'DeviceError' "$($a.State). Fault: $($a.FaultOwner). $($a.Action)" $a.Fix)) }
    $ghosts = @($probs | Where-Object Kind -eq 'Ghost')
    if ($ghosts.Count) {
        $c43 = @($ghosts | Where-Object { $_.FriendlyName -match 'Descriptor|Reset Failed|Set Address' -or $_.InstanceId -match 'VID_0000' })
        $sys.Add((New-Finding INFO 'Ghosts' "$($ghosts.Count) leftover entry(ies) from USB devices that failed to start ($($c43.Count) look like Code 43 descriptor failures, e.g. '$($ghosts[0].FriendlyName)'). Harmless, can be removed." 'RemoveGhostDevices'))
    }
    $old = @($probs | Where-Object Kind -eq 'OldDrive')
    if ($old.Count) { $sys.Add((New-Finding INFO 'OldDrives' "$($old.Count) remembered USB drives that aren't plugged in (normal).")) }
    if (-not $isAdmin) { $sys.Add((New-Finding INFO 'NotAdmin' 'Running without administrator rights: the timed raw read (#3) and raw partition-table/boot-sector checks were skipped.')) }

    $results = @(foreach ($d in $disks) { Get-DiskDiagnosis $d $hist $auto $isAdmin $mh })
    $healthy = @($results | Where-Object { $_.Level -in 'OK', 'INFO', 'WARN' -and -not $_.Disk.Virtual })
    foreach ($r in $results) {
        $others = @($healthy | Where-Object { $_.Disk.Number -ne $r.Disk.Number })
        if ($r.Level -in 'PROBLEM', 'FAILING' -and $others.Count) { $r.Assessment.FaultOwner += " Other USB disks on this PC work ($(($others | ForEach-Object { $_.Disk.Model }) -join ', ')), so the PC's USB is fine." }
    }
    $attached = @($results | ForEach-Object { $_.Disk.Identity })
    $recent = @(foreach ($k in @($hist.Arrivals | Where-Object { $_.BusType -eq 7 } | ForEach-Object Key | Sort-Object -Unique)) {
            if ($k -in $attached) { continue }
            $s = Get-DeviceHistorySummary $hist $k
            if ($s.ReadErrors -gt 0 -or $s.DropsAfterErrors -gt 0 -or $s.CapacityChanged) { $s }
        })
    [pscustomobject]@{ Time = Get-Date; Computer = $env:COMPUTERNAME; IsAdmin = $isAdmin; Days = $Days; System = $sys.ToArray(); Automount = $auto; Machine = $mh
        SelectiveSuspend = $ss; ProblemDevices = $probs; DeviceAssessments = $devAssess; Disks = $results; RecentProblemDrives = $recent; Version = $script:Version }
}

function Format-UsbDisk($d) {
    $id = if ($d.VID) { "VID_$($d.VID)&PID_$($d.PID)" } else { '-' }
    $lines = @(("Disk {0}: {1}  {2}  {3}  serial '{4}'  {5}  {6}" -f $d.Number, $d.Model, (Format-Bytes $d.Size), $id, $d.Serial, $d.PartitionStyle, $(if ($d.Removable) { 'removable' } else { 'fixed' })))
    $where = if ($d.PortKey) { "  port: $($d.PortKey)$(if ($d.ViaHub) { " (via hub $($d.HubName))" })" } else { '' }
    $lines += "  health: $($d.Health)   offline: $($d.Offline)   read-only: $($d.ReadOnly)$where"
    foreach ($v in $d.Volumes) {
        $lines += ("  Part {0}: {1,-4} {2,-6} '{3}'  {4} (partition {5}, offset {6:N0})" -f $v.PartitionNumber, $(if ($v.Letter) { "$($v.Letter):" } else { '--' }), $(if ($v.FileSystem) { $v.FileSystem } else { 'RAW' }), $v.Label, $(if ($v.Size) { (Format-Bytes $v.Size) + ' total, ' + (Format-Bytes $v.Free) + ' free' } else { '' }), (Format-Bytes $v.PartSize), $v.Offset)
    }
    if (-not $d.Volumes.Count) { $lines += '  (no partitions)' }
    if ($d.LargestFreeExtent -gt 16MB) { $lines += "  Unallocated: $(Format-Bytes $d.LargestFreeExtent)" }
    $lines
}

function Format-Assessment($a) {
    $o = @("  STATE:        $($a.State)", "  FAULT OWNER:  $($a.FaultOwner)")
    $first = $true; foreach ($x in $a.Actions) { $o += $(if ($first) { "  SAFE ACTION:  $x" } else { "                $x" }); $first = $false }
    $first = $true; foreach ($x in $a.Refusals) { $o += $(if ($first) { "  REFUSED:      $x" } else { "                $x" }); $first = $false }
    $o += "  TO CHANGE:    $($a.Change)"
    if ($a.Tier0Prompt) { $o += "  $($a.Tier0Prompt)" }
    if (@($a.Tier0).Count) { $o += "  Tier 0 results on file: $((@($a.Tier0) | ForEach-Object { "$($_.Result) ($($_.Time))" }) -join '; ')" }
    $o
}

function Format-UsbDiagnosis($Diag) {
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add(("USBDoctor {0} diagnosis on {1}, {2:yyyy-MM-dd HH:mm} (admin: {3}, event history: last {4} days)" -f $Diag.Version, $Diag.Computer, $Diag.Time, $Diag.IsAdmin, $Diag.Days))
    $o.Add(''); $o.Add('== This PC (Tier 0: machine)')
    foreach ($s in $Diag.System) { $o.Add(("  [{0}] {1}{2}" -f $s.Level, $s.Text, $(if ($s.Fix -and $s.Level -ne 'OK') { "  -> fix: $($s.Fix)" } else { '' }))) }
    if (-not $Diag.Disks.Count) { $o.Add(''); $o.Add('== No USB drives attached.') }
    foreach ($r in $Diag.Disks) {
        $o.Add('')
        foreach ($l in (Format-UsbDisk $r.Disk)) { $o.Add($l) }
        foreach ($x in $r.Findings) { $o.Add(("  [{0}] {1}" -f $x.Level, $x.Text)) }
        foreach ($l in (Format-Assessment $r.Assessment)) { $o.Add($l) }
    }
    if ($Diag.RecentProblemDrives.Count) {
        $o.Add(''); $o.Add("== USB drives seen in the last $($Diag.Days) days with errors (not attached now)")
        foreach ($s in $Diag.RecentProblemDrives) {
            $pp = @($s.FailingPorts | ForEach-Object { "$($_.Port): $($_.ReadErrors) err/$($_.Drops) drops" }) -join '; '
            $o.Add(("  {0} serial '{1}' ({2}): {3} read errors, dropped off after errors {4} time(s), {5} connects, last seen {6}" -f $s.Model, $s.Serial, $s.Key, $s.ReadErrors, $s.DropsAfterErrors, $s.Connects, $s.LastSeen))
            if (@($s.FailingPorts).Count -ge 2) { $o.Add("      same failure on $(@($s.FailingPorts).Count) ports ($pp) -> the drive, not the port: image what you can, do not repair.") }
            elseif ($pp) { $o.Add("      failing on one port only ($pp) -> try another port/PC before condemning it.") }
        }
    }
    $devs = @($Diag.ProblemDevices | Where-Object { $_.Kind -ne 'OldDrive' })
    if ($devs.Count) {
        $o.Add(''); $o.Add('== Problem / leftover USB device entries')
        foreach ($p in $devs) { $o.Add(("  {0,-6} {1,-8} code {2,-3} {3}  [{4}]" -f $p.Kind, $(if ($p.Present) { 'present' } else { 'absent' }), $p.Code, $p.FriendlyName, $p.InstanceId)) }
    }
    $o.ToArray()
}

# ------------------------------------------------------------------ drive letters
function Get-LetterUse([string]$L) {
    $uses = @()
    $v = Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue
    if ($v) {
        $p = Get-Partition -DriveLetter $L -ErrorAction SilentlyContinue
        $uses += ("volume '{0}' ({1}){2}" -f $v.FileSystemLabel, $v.FileSystemType, $(if ($p) { " on disk $($p.DiskNumber)" } else { '' }))
    }
    foreach ($di in [IO.DriveInfo]::GetDrives()) { if ($di.Name -eq "${L}:\" -and -not $v) { $uses += "a $($di.DriveType) drive" } }
    $net = Get-ItemProperty "HKCU:\Network\$L" -ErrorAction SilentlyContinue
    if ($net) { $uses += "mapped network drive $($net.RemotePath)" }
    $nu = & net.exe use 2>$null | Out-String
    if ($nu -match "(?m)^\S*\s+${L}:\s+(\\\\\S+)") { $uses += "network drive $($Matches[1])" }
    $su = & subst.exe 2>$null | Out-String
    if ($su -match "(?m)^${L}:\\: => (.+)$") { $uses += "subst of $($Matches[1].Trim())" }
    (@($uses | Select-Object -Unique)) -join '; '
}

function ConvertFrom-MountedDeviceData([byte[]]$b) {
    if ($b.Length -eq 12) {
        $sig = [BitConverter]::ToUInt32($b, 0); $off = [BitConverter]::ToInt64($b, 4)
        return [pscustomobject]@{ Kind = 'MBR'; Signature = $sig; Offset = $off; Guid = ''; Text = ('MBR disk signature {0:X8}, partition at byte {1:N0}' -f $sig, $off) }
    }
    if ($b.Length -ge 24 -and [Text.Encoding]::ASCII.GetString($b, 0, 8) -eq 'DMIO:ID:') {
        $g = New-Object Guid (, [byte[]]($b[8..23]))
        return [pscustomobject]@{ Kind = 'GPT'; Signature = 0; Offset = 0; Guid = "{$g}"; Text = "GPT partition {$g}" }
    }
    [pscustomobject]@{ Kind = 'Device'; Signature = 0; Offset = 0; Guid = ''; Text = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0) }
}

function Get-MountedLetterEntry([string]$L) {
    $name = "\DosDevices\${L}:"
    $item = Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -Name $name -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $raw = [byte[]]$item.$name
    $e = ConvertFrom-MountedDeviceData $raw
    $e | Add-Member -NotePropertyName Raw -NotePropertyValue $raw
    $e
}

function Test-EntryMatchesVolume($e, $d, $v) {
    switch ($e.Kind) {
        'MBR' { return ($null -ne $d.Signature -and [uint32]$e.Signature -eq [uint32]$d.Signature -and [int64]$e.Offset -eq [int64]$v.Offset) }
        'GPT' { return [bool]($e.Guid -and $e.Guid -ieq $v.Guid) }
        default { return [bool]($d.Path -and $e.Text -ieq ($d.Path -replace '^\\\\\?\\', '_??_')) }
    }
}

function Get-EntryOwner($e) {
    if ($e.Kind -eq 'Device') {
        if ($e.Text -match 'USBSTOR#Disk&Ven_([^&]*)&Prod_([^&#]*)') { return ("USB drive {0} {1}" -f $Matches[1], $Matches[2]).Replace('_', ' ').Trim() }
        return $e.Text
    }
    if ($e.Kind -eq 'MBR') {
        $m = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Signature -eq $e.Signature })
        if ($m) { return "disk $($m[0].Number) ($($m[0].FriendlyName)), $($e.Text)" }
    }
    $e.Text
}

function Test-PersistentLetter([string]$L, $d, $v) {
    $e = Get-MountedLetterEntry $L
    if (-not $e) { return [pscustomobject]@{ Recorded = $false; Matches = $false; Kind = ''; Detail = "No \DosDevices\${L}: entry in HKLM\SYSTEM\MountedDevices." } }
    $m = Test-EntryMatchesVolume $e $d $v
    [pscustomobject]@{ Recorded = $true; Matches = $m; Kind = $e.Kind; Detail = "\DosDevices\${L}: = $($e.Text)" }
}

function New-Plan([string]$Action, [string]$Title, [string[]]$Text, [bool]$Destructive = $false, [int]$DiskNumber = -1) {
    [pscustomobject]@{ Action = $Action; Title = $Title; Text = ($Text -join "`r`n"); Destructive = $Destructive; DiskNumber = $DiskNumber; Phrase = $(if ($Destructive) { "REPAIR $DiskNumber" } else { '' }) }
}

function Select-Volume($d, [int]$PartitionNumber, [switch]$Last) {
    if ($PartitionNumber -gt 0) {
        $v = $d.Volumes | Where-Object { $_.PartitionNumber -eq $PartitionNumber }
        if (-not $v) { throw "Disk $($d.Number) has no partition $PartitionNumber." }
        return $v
    }
    $vols = @($d.Volumes | Where-Object { $_.FileSystem -and $_.FileSystem -ne 'Unknown' })
    if (-not $vols) { throw "Disk $($d.Number) has no partition with a readable file system." }
    if ($Last) { return ($vols | Sort-Object Offset | Select-Object -Last 1) }
    $vols | Sort-Object PartSize -Descending | Select-Object -First 1
}

function Set-UsbDriveLetter {
    param([int]$DiskNumber, [int]$PartitionNumber = 0, [string]$Letter, [switch]$Persistent, [switch]$Force, [switch]$Preview)
    $d = Get-RepairDisk $DiskNumber
    $v = Select-Volume $d $PartitionNumber
    $auto = -not $Letter
    $L = ''; $stale = $null
    if (-not $auto) {
        $L = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
        if ($L -notmatch '^[D-Z]$') { throw "'$Letter' is not a usable drive letter. Use D to Z." }
        if ($v.Letter -ne $L) {
            $use = Get-LetterUse $L
            if ($use) { throw "Drive letter ${L}: is already in use by $use. Pick another letter or free ${L}: first. Nothing was changed." }
            $res = Get-MountedLetterEntry $L
            if ($res -and -not (Test-EntryMatchesVolume $res $d $v)) {
                $stale = $res
                if (-not $Force) { throw "Drive letter ${L}: is reserved by Windows for another drive that is not plugged in ($(Get-EntryOwner $res)). Use -Force (or tick 'Release reservation' in the window) to take it over. Nothing was changed." }
            }
        }
    }
    $target = if ($auto) { 'the next free letter' } else { "${L}:" }
    $txt = @("Disk $($d.Number) $($d.Model), partition $($v.PartitionNumber): $($v.FileSystem) '$($v.Label)' $(Format-Bytes $v.Size), current letter: $(if ($v.Letter) { "$($v.Letter):" } else { 'none' }).")
    if ($auto -or $v.Letter -ne $L) { $txt += "Assign $target to it." }
    if ($stale) { $txt += "Also release the old reservation of ${L}: held by $(Get-EntryOwner $stale) (deletes \DosDevices\${L}: from HKLM\SYSTEM\MountedDevices; the old value is written to the log)." }
    if ($Persistent -or -not $auto) {
        $txt += 'Windows records the letter in HKLM\SYSTEM\MountedDevices keyed to this drive and gives it the same letter on every plug-in. USBDoctor checks that entry afterwards.'
        if ($d.Removable -and $d.UsbInstance -and -not $d.UniqueUsbSerial) { $txt += "Note: this stick has no unique USB serial, so Windows keys it by USB port ($($d.Port)). The letter sticks only when it's plugged into the same port." }
    }
    if ($v.Letter -eq $L -and -not $auto) { $txt += "It already has ${L}:; only the MountedDevices record will be checked." }
    if ($Preview) { return New-Plan 'AssignLetter' 'Assign drive letter' $txt $false $DiskNumber }

    if ($auto -or $v.Letter -ne $L) { Assert-Admin 'Assigning a drive letter' }
    Write-UDLog "=== Assign letter: disk $DiskNumber partition $($v.PartitionNumber) ($($v.FileSystem) '$($v.Label)') -> $target"
    if ($v.Letter -ne $L -or $auto) {
        if ($stale) {
            Write-UDLog ("Releasing stale reservation \DosDevices\{0}: = {1} (old value hex {2})" -f $L, $stale.Text, (($stale.Raw | ForEach-Object { $_.ToString('X2') }) -join '')) 'WARN'
            Remove-ItemProperty -Path 'HKLM:\SYSTEM\MountedDevices' -Name "\DosDevices\${L}:" -ErrorAction Stop
        }
        try {
            if ($auto) { Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber -AssignDriveLetter -ErrorAction Stop }
            elseif ($v.Letter) { Set-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber -NewDriveLetter $L -ErrorAction Stop }
            else { Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber -AccessPath "${L}:\" -ErrorAction Stop }
        } catch {
            if ($auto -or -not $v.VolumePath) { throw }
            Write-UDLog "Storage cmdlet failed ($($_.Exception.Message)); using mountvol." 'WARN'
            if ($v.Letter) { & mountvol.exe "$($v.Letter):\" /D | Out-Null }
            $o = & mountvol.exe "${L}:\" $v.VolumePath 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "mountvol ${L}:\ failed: $($o.Trim())" }
        }
        Start-Sleep -Seconds 2
    }
    $now = Get-PartLetter (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber)
    if (-not $now) { throw 'Windows did not assign a drive letter.' }
    if (-not $auto -and $now -ne $L) { throw "Windows assigned ${now}: instead of ${L}:." }
    $ver = Test-PersistentLetter $now $d $v
    if ($ver.Matches) { Write-UDLog "Letter ${now}: assigned. Recorded for this drive in MountedDevices ($($ver.Kind) entry): $($ver.Detail)" }
    else { Write-UDLog "Letter ${now}: assigned, but MountedDevices does not show it keyed to this drive: $($ver.Detail)" 'WARN' }
    if ($Persistent -and -not $ver.Matches) { throw "${now}: was assigned, but Windows did not record it for this drive, so it may not stick. $($ver.Detail)" }
    Write-UDLog '=== Assign letter OK'
    [pscustomobject]@{ Disk = $DiskNumber; Partition = $v.PartitionNumber; Letter = $now; Persistent = $ver.Matches; RecordKind = $ver.Kind; Record = $ver.Detail }
}

# ------------------------------------------------------------------ simple repairs
function Enable-UsbAutomount([switch]$Preview) {
    $a = Get-AutomountState
    $txt = if ($a.Enabled) { @('Automount is already on. Nothing to do.') } else { @('Automount is OFF (NoAutoMount=1). Run "mountvol /E" so new USB volumes get drive letters again.') }
    if ($Preview) { return New-Plan 'EnableAutomount' 'Enable automount' $txt }
    if ($a.Enabled) { Write-UDLog 'Automount already enabled; nothing changed.'; return [pscustomobject]@{ Enabled = $true; Changed = $false } }
    Assert-Admin 'Enabling automount'
    Write-UDLog '=== Enable automount (mountvol /E)'
    $o = & mountvol.exe /E 2>&1 | Out-String
    $b = Get-AutomountState
    if (-not $b.Enabled) { throw "mountvol /E did not enable automount: $($o.Trim())" }
    Write-UDLog 'Automount is now enabled.'
    [pscustomobject]@{ Enabled = $true; Changed = $true }
}

function Set-UsbDiskOnline([int]$DiskNumber, [string]$ConfirmPhrase, [switch]$Preview) {
    # #4: bring an offline disk online. A signature collision is disclosed first: Windows writes a new MBR disk signature.
    $d = Get-RepairDisk $DiskNumber
    if (-not $d.Offline) {
        if ($Preview) { return New-Plan 'Online' 'Bring disk online' @("Disk $DiskNumber is already online. Nothing to do.") $false $DiskNumber }
        Write-UDLog "Disk $DiskNumber already online."; return [pscustomobject]@{ Disk = $DiskNumber; Online = $true; Changed = $false }
    }
    $g = Assert-WriteGate $d 'Online' $ConfirmPhrase -Preview:$Preview
    $coll = "$($d.OfflineReason)" -match 'Collision'
    if (-not $coll) { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'partmgr'; Id = 58; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match "disk $DiskNumber\b" }); $coll = [bool]$ev.Count }
    $txt = @("Bring disk $DiskNumber $($d.Model) online (reason it is offline: $($d.OfflineReason)).")
    if ($coll) {
        $txt += 'DISCLOSURE - signature collision: this disk has the same MBR disk signature as another disk (usually a clone). To bring it online, Windows writes a NEW random signature into its MBR (4 bytes at offset 440).'
        $txt += "Consequences: drive-letter records keyed to the old signature ($('{0:X8}' -f [uint32]$d.Signature)) no longer match, and any boot entry that points at the old signature breaks. File data is not touched."
    }
    $txt += (Get-GateText $g $DiskNumber)
    if ($Preview) { return New-Plan 'Online' 'Bring disk online' $txt ($g.NeedsPhrase -or $coll) $DiskNumber }
    if ($coll -and $ConfirmPhrase -ne "REPAIR $DiskNumber") { throw "Bringing disk $DiskNumber online rewrites its disk signature. Type REPAIR $DiskNumber to confirm." }
    Assert-Admin 'Bringing a disk online'
    Write-UDLog "=== Online disk $DiskNumber (collision: $coll)"
    try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop }
    catch { Write-UDLog "Set-Disk failed ($($_.Exception.Message)); using diskpart." 'WARN'; Invoke-Diskpart @("select disk $DiskNumber", 'online disk noerr') | Out-Null }
    Start-Sleep -Seconds 1
    $n = Get-Disk -Number $DiskNumber
    if ($n.IsOffline) { throw "Disk $DiskNumber is still offline ($($n.OfflineReason))." }
    if ($coll) { Write-UDLog ("Disk signature now {0:X8} (was {1:X8})." -f [uint32]$n.Signature, [uint32]$d.Signature) }
    Write-UDLog "Disk $DiskNumber is online."
    [pscustomobject]@{ Disk = $DiskNumber; Online = $true; Changed = $true; SignatureRewritten = $coll; Signature = ('{0:X8}' -f [uint32]$n.Signature) }
}

function Clear-UsbReadOnly([int]$DiskNumber, [string]$ConfirmPhrase, [switch]$Preview) {
    # #8: clear disk/partition read-only, test-write, record it. If it comes back after a replug: dying, copy-only, never cleared twice.
    $d = Get-RepairDisk $DiskNumber
    $rop = @($d.Volumes | Where-Object PartReadOnly)
    if (-not $d.ReadOnly -and -not $rop.Count) {
        if ($Preview) { return New-Plan 'ClearReadOnly' 'Clear read-only' @("Disk $DiskNumber is not read-only. Nothing to do.") $false $DiskNumber }
        Write-UDLog "Disk $DiskNumber is not read-only."; return [pscustomobject]@{ Disk = $DiskNumber; ReadOnly = $false; Changed = $false }
    }
    $rec = Get-DeviceHistoryRecord $d.Identity
    if ($rec -and @($rec.ReadOnlyClears).Count) {
        Update-DeviceHistory $d.Identity $d.Model { param($r) $r.ReadOnlyReturned = (Get-Date).ToString('s') } | Out-Null
    }
    $g = Assert-WriteGate $d 'ClearReadOnly' $ConfirmPhrase -Preview:$Preview
    $txt = @("Disk $DiskNumber $($d.Model): clear the read-only attribute on the $(if ($d.ReadOnly) { 'disk' })$(if ($d.ReadOnly -and $rop.Count) { ' and ' })$(if ($rop.Count) { "partition(s) $(($rop | ForEach-Object PartitionNumber) -join ',')" }).",
        'Then write, read back and delete a 64 KiB test file to prove it really accepts writes.',
        'Afterwards unplug and replug it and run Diagnose again. If read-only comes back, the flash is worn out: USBDoctor will then refuse to clear it again and you should copy everything off.',
        'Check for a physical lock switch on the stick first.', (Get-GateText $g $DiskNumber))
    if ($Preview) { return New-Plan 'ClearReadOnly' 'Clear read-only' $txt $g.NeedsPhrase $DiskNumber }
    Assert-Admin 'Clearing read-only'
    Write-UDLog "=== Clear read-only on disk $DiskNumber"
    try {
        if ($d.ReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop }
        foreach ($v in $rop) { Set-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber -IsReadOnly $false -ErrorAction Stop }
    } catch {
        Write-UDLog "Storage cmdlet failed ($($_.Exception.Message)); using diskpart." 'WARN'
        $cmds = @("select disk $DiskNumber", 'attributes disk clear readonly noerr'); foreach ($v in $rop) { $cmds += "select partition $($v.PartitionNumber)", 'attributes volume clear readonly noerr' }
        Invoke-Diskpart $cmds | Out-Null
    }
    Start-Sleep -Seconds 2
    $n = Get-Disk -Number $DiskNumber
    $pro = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
    if ($n.IsReadOnly -or $pro.Count) { throw "Disk $DiskNumber is still read-only (disk=$($n.IsReadOnly), partitions=$($pro.Count)). A lock switch or worn-out flash; copy the data off." }
    $test = 'no letter to test'
    $L = @($d.Volumes | Where-Object Letter | ForEach-Object Letter) | Select-Object -First 1
    if ($L) {
        # remount so the file system notices it is writable again
        $m = ''; $lh = [UsbDocNative]::LockVolume("\\.\${L}:", [ref]$m); if ($lh) { $lh.Close() }; Start-Sleep -Seconds 2
        $p = "${L}:\USBDoctor-writetest-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $data = New-Object byte[] 65536; (New-Object Random).NextBytes($data)
            [IO.File]::WriteAllBytes($p, $data); $back = [IO.File]::ReadAllBytes($p); Remove-Item -LiteralPath $p -Force
            $same = ($back.Length -eq $data.Length) -and -not (Compare-Object $data $back -SyncWindow 0 | Select-Object -First 1)
            $test = if ($same) { "test write on ${L}: OK" } else { "test write on ${L}: data read back DIFFERENT" }
        } catch { $test = "test write on ${L}: FAILED ($($_.Exception.Message))" }
    }
    Write-UDLog "Read-only cleared on disk $DiskNumber; $test."
    Update-DeviceHistory $d.Identity $d.Model { param($r) $r.ReadOnlyClears = @(@($r.ReadOnlyClears) + @(@{ Time = (Get-Date).ToString('s'); Test = $test })) } | Out-Null
    if ($test -match 'FAILED|DIFFERENT') { throw "Read-only attribute cleared, but $test. Treat the drive as failing: copy only." }
    [pscustomobject]@{ Disk = $DiskNumber; ReadOnly = $false; Changed = $true; WriteTest = $test; Next = 'Unplug, replug, Diagnose again. If read-only returns, the drive is dying (copy-only).' }
}

function Get-DiskOfLetter([string]$Letter) {
    $L = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
    if ($L -notmatch '^[A-Z]$') { throw "'$Letter' is not a drive letter." }
    $p = Get-Partition -DriveLetter $L -ErrorAction SilentlyContinue
    if (-not $p) { throw "No partition has drive letter ${L}:." }
    [pscustomobject]@{ Letter = $L; DiskNumber = [int]$p.DiskNumber; PartitionNumber = [int]$p.PartitionNumber }
}

function Invoke-UsbChkdsk([string]$Letter, [string]$ConfirmPhrase, [switch]$Preview) {
    # #10: chkdsk /f only when the timed raw read passed (no #3 symptoms); image first or typed risk acceptance.
    $x = Get-DiskOfLetter $Letter
    $d = Get-RepairDisk $x.DiskNumber
    $v = $d.Volumes | Where-Object { $_.PartitionNumber -eq $x.PartitionNumber }
    $g = Assert-WriteGate $d 'Chkdsk' $ConfirmPhrase -Preview:$Preview
    if ($g.Raw.Result -eq 'Skipped' -and -not $Preview) { Assert-Admin 'Check disk' }
    $txt = @("Run 'chkdsk $($x.Letter): /f /x' on $($v.FileSystem) '$($v.Label)' (disk $($d.Number) $($d.Model)).",
        "Raw first-sector read check: $($g.Raw.Result) ($($g.Raw.Detail)).",
        'It closes open files on the drive (dismounts it), then fixes file system errors. chkdsk writes to the drive and can delete damaged files.', (Get-GateText $g $d.Number))
    if ($Preview) { return New-Plan 'Chkdsk' 'Check disk' $txt $g.NeedsPhrase $d.Number }
    Assert-Admin 'Check disk'
    Write-UDLog "=== chkdsk $($x.Letter): /f /x"
    $out = & chkdsk.exe "$($x.Letter):" /f /x 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    foreach ($l in @($out | Where-Object { $_.Trim() -and $_ -notmatch '^\s*Progress:|percent complete' } | Select-Object -Last 25)) { Write-UDLog "chkdsk: $($l.Trim())" }
    $meaning = switch ($rc) { 0 { 'no errors found' } 1 { 'errors found and fixed' } 2 { 'cleanup done (or not run because /f was missing)' } 3 { 'could not check the disk, or errors could not be fixed' } default { "exit code $rc" } }
    Write-UDLog "chkdsk finished: $meaning."
    if ($rc -ge 3) { throw "chkdsk could not finish: $meaning. See the log." }
    [pscustomobject]@{ Letter = $x.Letter; ExitCode = $rc; Result = $meaning; ImageOnFile = [bool]$g.Image }
}

function Reset-UsbDevice([string]$InstanceId, [switch]$Preview) {
    # #2: Code 10/28/31 - remove the device node and rescan; also verify the USBSTOR driver and its start type.
    $p = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if (-not $p) { throw "No device with instance ID $InstanceId." }
    if ("$($p.InstanceId)" -notmatch '^(USB|USBSTOR)\\') { throw 'Only USB device entries can be reset.' }
    $svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -ErrorAction SilentlyContinue
    $st = if ($svc) { [int]$svc.Start } else { -1 }
    $txt = @("Remove '$($p.FriendlyName)' [$InstanceId] (status $($p.Status), code $($p.ConfigManagerErrorCode)) with pnputil /remove-device, then rescan so Windows reinstalls it from scratch.",
        "USB mass-storage driver USBSTOR: start type $st $(if ($st -eq 3) { '(correct)' } elseif ($st -eq 4) { '(DISABLED - USB sticks cannot work; usually a policy. USBDoctor reports it but does not override policy.)' } else { '' }).")
    if ($Preview) { return New-Plan 'ResetDevice' 'Remove device and rescan' $txt }
    Assert-Admin 'Removing a device'
    Write-UDLog "=== Reset device $InstanceId"
    $o = & pnputil.exe /remove-device "$InstanceId" 2>&1 | Out-String
    $ok = ($LASTEXITCODE -eq 0)
    & pnputil.exe /scan-devices | Out-Null
    Start-Sleep -Seconds 3
    $n = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    Write-UDLog "Removed: $ok. After rescan: $(if ($n) { "$($n.Status) code $($n.ConfigManagerErrorCode)" } else { 'not present' })."
    if (-not $ok) { throw "pnputil could not remove the device: $(($o -replace '\s+', ' ').Trim())" }
    [pscustomobject]@{ InstanceId = $InstanceId; Removed = $ok; StatusAfter = $(if ($n) { "$($n.Status)" } else { 'absent' }); UsbStorStart = $st }
}

function Disable-UsbSelectiveSuspend([switch]$Preview) {
    $s = Get-SelectiveSuspendState
    $txt = if ($s.Known -and -not $s.Enabled) { @("USB selective suspend is already off (AC=$($s.AC), DC=$($s.DC)). Nothing to do.") } else { @("Turn off USB selective suspend in the current power plan for both plugged-in (AC) and battery (DC). Now: AC=$($s.AC), DC=$($s.DC).") }
    if ($Preview) { return New-Plan 'DisableSelectiveSuspend' 'Turn off USB selective suspend' $txt }
    if ($s.Known -and -not $s.Enabled) { Write-UDLog 'USB selective suspend already off; nothing changed.'; return [pscustomobject]@{ AC = $s.AC; DC = $s.DC; Changed = $false } }
    Write-UDLog '=== Disable USB selective suspend (current power scheme, AC and DC)'
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $script:UsbSubgroup $script:SuspendGuid 0 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT $script:UsbSubgroup $script:SuspendGuid 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    $n = Get-SelectiveSuspendState
    if ($n.Enabled) { throw "powercfg did not turn it off (AC=$($n.AC), DC=$($n.DC))." }
    Write-UDLog "USB selective suspend is off (AC=$($n.AC), DC=$($n.DC))."
    [pscustomobject]@{ AC = $n.AC; DC = $n.DC; Changed = $true }
}

function Remove-UsbGhostDevices([switch]$IncludeOldDrives, [switch]$Preview) {
    $t = @(Get-UsbProblemDevices | Where-Object { $_.Kind -in 'Ghost', 'Error' -or ($IncludeOldDrives -and $_.Kind -eq 'OldDrive') })
    $txt = if ($t.Count) { @("Remove these $($t.Count) device entries with 'pnputil /remove-device', then rescan (pnputil /scan-devices). Working devices come straight back; a stick that is plugged in is re-detected from scratch:") + @($t | ForEach-Object { "  $($_.Kind) $(if ($_.Present) { '(present)' } else { '(absent)' }): $($_.FriendlyName) [$($_.InstanceId)]" }) } else { @('No failed or leftover USB device entries found. Nothing to do.') }
    if ($Preview) { return New-Plan 'RemoveGhostDevices' 'Remove failed/ghost USB devices' $txt }
    if (-not $t.Count) { Write-UDLog 'No ghost USB devices to remove.'; return [pscustomobject]@{ Removed = 0; Failed = 0 } }
    Assert-Admin 'Removing device entries'
    Write-UDLog "=== Remove $($t.Count) USB device entries"
    $ok = 0; $bad = 0
    foreach ($x in $t) {
        $o = & pnputil.exe /remove-device "$($x.InstanceId)" 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $ok++; Write-UDLog "Removed $($x.FriendlyName) [$($x.InstanceId)]" } else { $bad++; Write-UDLog "Could not remove $($x.InstanceId): $(($o -replace '\s+', ' ').Trim())" 'WARN' }
    }
    & pnputil.exe /scan-devices | Out-Null
    Write-UDLog "Rescanned devices. Removed $ok, failed $bad."
    [pscustomobject]@{ Removed = $ok; Failed = $bad }
}

function Dismount-UsbDrive([string]$Letter, [int]$DiskNumber = -1, [switch]$Preview) {
    if ($Letter) { $DiskNumber = (Get-DiskOfLetter $Letter).DiskNumber }
    if ($DiskNumber -lt 0) { throw 'Use -Letter X or -Disk N.' }
    $d = Get-RepairDisk $DiskNumber
    $letters = @($d.Volumes | Where-Object Letter | ForEach-Object { "$($_.Letter):" })
    $txt = @("Flush and safely remove disk $DiskNumber $($d.Model) ($(if ($letters) { $letters -join ', ' } else { 'no letters' })). Close files and Explorer windows on it first.")
    if ($Preview) { return New-Plan 'Eject' 'Safe eject' $txt $false $DiskNumber }
    Write-UDLog "=== Safe eject disk $DiskNumber $($d.Model)"
    foreach ($v in @($d.Volumes | Where-Object Letter)) { try { Write-VolumeCache -DriveLetter $v.Letter -ErrorAction Stop } catch { Write-UDLog "Flush of $($v.Letter): failed: $($_.Exception.Message)" 'WARN' } }
    if ($d.Virtual) {
        Dismount-DiskImage -DevicePath "\\.\PHYSICALDRIVE$DiskNumber" -ErrorAction Stop | Out-Null
        Write-UDLog "Virtual disk $DiskNumber detached."
        return [pscustomobject]@{ Disk = $DiskNumber; Ejected = $true }
    }
    $r = [UsbDocNative]::Eject($d.DiskInstanceId)
    if ($r -ne 'OK') { throw "Windows would not eject disk ${DiskNumber}: $r. Close open files or Explorer windows on it and try again." }
    Write-UDLog "Disk $DiskNumber ejected. It is safe to unplug."
    [pscustomobject]@{ Disk = $DiskNumber; Ejected = $true }
}

# ------------------------------------------------------------------ writing repairs (gated: image first or typed REPAIR N)
function Get-FreeBytes([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:') { return [int64]-1 }
    try { return [int64](New-Object IO.DriveInfo ($Path.Substring(0, 1))).AvailableFreeSpace } catch { return [int64]-1 }
}

function Lock-DiskVolumes([int]$DiskNumber) {
    $locks = @()
    foreach ($p in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
        $v = $null; try { $v = $p | Get-Volume -ErrorAction Stop } catch {}
        $l = Get-PartLetter $p
        $path = if ($l) { "\\.\${l}:" } elseif ($v -and $v.Path) { ($v.Path -replace '^\\\\\?\\', '\\.\').TrimEnd('\') } else { $null }
        if (-not $path) { continue }
        $msg = ''
        $h = [UsbDocNative]::LockVolume($path, [ref]$msg)
        Write-UDLog "Lock volume $msg"
        if (-not $h) { foreach ($x in $locks) { $x.Close() }; throw "Could not lock $path (files open on it?). Close everything using the drive and try again. Nothing was written." }
        $locks += $h
    }
    , $locks
}

function Copy-DiskToFileChecked($Handle, [int64]$Length, $Stream, [string]$What) {
    $done = [int64]0; $slice = [int64]256MB; $t = [Diagnostics.Stopwatch]::StartNew()
    while ($done -lt $Length) {
        $n = [int64][Math]::Min([int64]$slice, [int64]($Length - $done))
        [UsbDocNative]::CopyDiskToStream($Handle, [int64]$done, [int64]$n, $Stream)
        $done += $n
        if ($t.ElapsedMilliseconds -gt 10000 -or $done -eq $Length) { Write-UDLog ("{0}: {1} of {2}" -f $What, (Format-Bytes $done), (Format-Bytes $Length)); $t.Restart() }
    }
}

function Get-UsbImagerPath { $p = Join-Path (Split-Path $PSScriptRoot) 'USBImager\USBImager.cmd'; if (Test-Path $p) { $p } else { 'USBImager.cmd' } }

function Convert-ImageUsbFile([string]$Image, [string]$Out, [switch]$Preview) {
    # ImageUSB shift, design rule: never rewrite the stick. Strip the 512-byte imageUSB header from an IMAGE FILE so the
    # MBR is at offset 0, then burn the clean image with USBImager.
    if (-not $Image -or -not (Test-Path -LiteralPath $Image)) { throw "Image file '$Image' not found." }
    $Image = (Resolve-Path -LiteralPath $Image).ProviderPath
    $b = New-Object byte[] 1024
    $fs = [IO.File]::OpenRead($Image); try { $n = $fs.Read($b, 0, 1024); $len = $fs.Length } finally { $fs.Close() }
    $hdr = ($n -eq 1024) -and ([Text.Encoding]::ASCII.GetString($b, 0, 512) -match 'imageUSB')
    if (-not ($hdr -and $b[1022] -eq 0x55 -and $b[1023] -eq 0xAA)) { throw "$Image does not start with a 512-byte imageUSB header followed by an MBR (0x55AA at byte 1022). Nothing to strip." }
    $parts = @(Get-MbrEntries $b 512)
    if (-not $Out) { $Out = Join-Path (Split-Path $Image) ([IO.Path]::GetFileNameWithoutExtension($Image) + '-fixed.img') }
    if (Test-Path -LiteralPath $Out) { throw "$Out already exists. Choose another -Out file." }
    $free = Get-FreeBytes $Out
    if ($free -ge 0 -and $free -lt $len) { throw "Not enough free space for $Out ($(Format-Bytes $free) free, $(Format-Bytes $len) needed)." }
    $txt = @("Image file: $Image ($(Format-Bytes $len)). Sector 0 is an imageUSB header; the MBR is in sector 1 with $($parts.Count) partition(s):")
    $txt += @($parts | ForEach-Object { "  partition $($_.Index): type $($_.Type), starts at sector $($_.StartLba), $(Format-Bytes ($_.Sectors * 512))" })
    $txt += @("Write $Out = the same bytes without the first 512, so the MBR is at offset 0. The original image and the stick are not changed.",
        "Then burn the clean image with USBImager: $(Get-UsbImagerPath) -Burn -Image ""$Out"" -Disk <N>")
    if ($Preview) { return New-Plan 'FixImageUsbShift' 'Strip the imageUSB header from the image file' $txt $false -1 }
    Write-UDLog "=== Strip imageUSB header: $Image -> $Out"
    $dir = Split-Path $Out; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $src = [IO.File]::OpenRead($Image)
    $dst = New-Object IO.FileStream($Out, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $src.Position = 512; $src.CopyTo($dst, 4MB); $dst.Flush($true) } finally { $dst.Close(); $src.Close() }
    $c = New-Object byte[] 512; $fs = [IO.File]::OpenRead($Out); try { [void]$fs.Read($c, 0, 512); $olen = $fs.Length } finally { $fs.Close() }
    for ($i = 0; $i -lt 512; $i++) { if ($c[$i] -ne $b[512 + $i]) { throw "Verify failed: $Out sector 0 differs from the image's sector 1." } }
    if ($c[510] -ne 0x55 -or $c[511] -ne 0xAA -or $olen -ne $len - 512) { throw "Verify failed on $Out." }
    $hash = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash
    $burn = "$(Get-UsbImagerPath) -Burn -Image ""$Out"" -Disk <N>"
    Write-UDLog "Clean image written: $Out ($(Format-Bytes $olen)), MBR at offset 0, SHA256 $hash. Burn it with: $burn"
    [pscustomobject]@{ Image = $Image; Out = $Out; Bytes = $olen; MbrAt0 = $true; Partitions = $parts.Count; SHA256 = $hash; BurnCommand = $burn }
}

function Invoke-ImageUsbFix {
    # Image the shifted stick (read-only rescue), strip the header from the image file, hand off to USBImager. Never writes the stick.
    param([int]$DiskNumber, [string]$OutFile, [string]$RawFile, [switch]$Preview, $Control)
    $d = Get-RepairDisk $DiskNumber
    Assert-Admin 'Reading the raw sectors'
    $boot = Get-BootSectorInfo $DiskNumber
    if (-not $boot.Read) { throw "Could not read disk ${DiskNumber}'s first sectors: $($boot.Error)" }
    if (-not (Test-ImageUsbShift $boot)) { throw "Disk $DiskNumber does not have an ImageUSB-shifted MBR ('imageUSB' text in sector 0, 0x55AA at byte 1022 and not at 510). Nothing to fix." }
    $base = Join-Path (Join-Path (Get-DefaultDataDir) 'Rescue') ('{0}-{1}' -f ($d.Model -replace '[^A-Za-z0-9]+', '_'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not $RawFile) { $RawFile = if ($OutFile) { [IO.Path]::ChangeExtension($OutFile, $null).TrimEnd('.') + '-raw-imageusb.img' } else { "$base-raw-imageusb.img" } }
    if (-not $OutFile) { $OutFile = "$base-fixed.img" }
    $txt = @("Disk $DiskNumber $($d.Model) has an imageUSB header in sector 0 and the real MBR in sector 1 ($($boot.Partitions1.Count) partition(s)).",
        "  1. Rescue copy (read-only, skip-on-error, resumable) of the whole stick to $RawFile.",
        "  2. Strip the first 512 bytes from that image into $OutFile, so the MBR is at offset 0 (verified).",
        "  3. Burn $OutFile with USBImager onto this or another stick: $(Get-UsbImagerPath) -Burn -Image ""$OutFile"" -Disk <N>.",
        'USBDoctor never rewrites the MBR of the stick itself (DiskPilot rule).')
    if ($Preview) { return New-Plan 'FixImageUsbShift' 'Image + strip imageUSB header (stick is only read)' $txt $false $DiskNumber }
    Write-UDLog "=== ImageUSB fix (image-file route): disk $DiskNumber -> $RawFile -> $OutFile"
    $r = Start-UsbRescue -DiskNumber $DiskNumber -OutFile $RawFile -Control $Control
    if ($r.Status -ne 'done') { throw "The rescue copy did not finish (status $($r.Status)); run the same command again to resume. Nothing was written to the stick." }
    if ($r.BytesBad -gt 0) { Write-UDLog "Rescue had $(Format-Bytes $r.BytesBad) unreadable (zero-filled); the fixed image carries those gaps." 'WARN' }
    $c = Convert-ImageUsbFile -Image $RawFile -Out $OutFile
    [pscustomobject]@{ Disk = $DiskNumber; RawImage = $RawFile; FixedImage = $c.Out; SHA256 = $c.SHA256; BytesBad = $r.BytesBad; StickWritten = $false; BurnCommand = $c.BurnCommand }
}

function Restore-UsbBootSector([int]$DiskNumber, [int]$PartitionNumber = 0, [string]$ConfirmPhrase, [switch]$Preview) {
    # #5: corrupt NTFS/FAT32/exFAT boot sector with an intact backup -> copy the backup back. Image first (gate).
    $d = Get-RepairDisk $DiskNumber
    Assert-Admin 'Reading boot sectors'
    $cands = @($d.Volumes | Where-Object { ($PartitionNumber -le 0 -or $_.PartitionNumber -eq $PartitionNumber) -and (-not $_.FileSystem -or $_.FileSystem -in 'Unknown', 'RAW') })
    if (-not $cands.Count) { throw "Disk $DiskNumber has no RAW partition$(if ($PartitionNumber -gt 0) { " $PartitionNumber" }) to restore." }
    $v = $cands[0]
    $fi = Get-PartitionFsInfo $DiskNumber $v.Offset $v.PartSize
    if ($fi.Kind -eq 'Foreign') { throw "Partition $($v.PartitionNumber) holds $($fi.Name) - healthy, just another OS. Nothing to restore." }
    if ($fi.PrimaryValid) { throw "Partition $($v.PartitionNumber): the $($fi.Kind) boot sector is valid; the damage is elsewhere. Image it and rebuild with USBImager." }
    if (-not $fi.BackupValid) { throw "Partition $($v.PartitionNumber): no intact backup boot sector was found, so there is nothing safe to restore. Image it (Rescue) and recover from the image." }
    $g = Assert-WriteGate $d 'BootSector' $ConfirmPhrase -Preview:$Preview
    $bytes = [int]($fi.BackupSectors * 512)
    $txt = @("Disk $DiskNumber partition $($v.PartitionNumber) ($(Format-Bytes $v.PartSize)): the $($fi.Kind) boot sector is damaged; an intact backup copy is at byte $('{0:N0}' -f $fi.BackupOffset).",
        "Copy $bytes bytes from the backup to the start of the partition (byte $('{0:N0}' -f $v.Offset)). The current (damaged) sectors are saved to a file first so this can be undone.",
        'Nothing else on the disk is touched; the partition table and MBR are not written.', (Get-GateText $g $DiskNumber))
    if ($Preview) { return New-Plan 'RestoreBootSector' 'Restore boot sector from backup' $txt $g.NeedsPhrase $DiskNumber }
    $bdir = Join-Path (Get-DefaultDataDir) 'USBDoctor-Backups'; if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
    $save = Join-Path $bdir ('disk{0}-part{1}-bootsector-before-restore-{2}.bin' -f $DiskNumber, $v.PartitionNumber, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-UDLog "=== Restore $($fi.Kind) boot sector: disk $DiskNumber partition $($v.PartitionNumber) from byte $($fi.BackupOffset)"
    $old = Read-DiskBytes $DiskNumber $v.Offset $bytes; [IO.File]::WriteAllBytes($save, $old)
    $bk = Read-DiskBytes $DiskNumber $fi.BackupOffset $bytes
    Write-UDLog "Saved the damaged sectors to $save."
    $d = Assert-SameDisk $d
    $locks = Lock-DiskVolumes $DiskNumber
    try {
        $w = [UsbDocNative]::OpenDisk($DiskNumber, $true)
        try {
            [UsbDocNative]::WriteAt($w, [int64]$v.Offset, $bk, $bytes); [void][UsbDocNative]::Flush($w)
            $chk = New-Object byte[] $bytes; $e = 0
            if ([UsbDocNative]::ReadAt($w, [int64]$v.Offset, $chk, $bytes, 15000, [ref]$e) -ne $bytes) { throw "read-back failed (Win32 $e)" }
            for ($i = 0; $i -lt $bytes; $i++) { if ($chk[$i] -ne $bk[$i]) { throw "Verify failed at byte $i. Undo by writing $save back." } }
            [void][UsbDocNative]::UpdateProperties($w)
        } finally { $w.Close() }
    } finally { foreach ($l in $locks) { $l.Close() } }
    Start-Sleep -Seconds 2; try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch {}; Start-Sleep -Seconds 3
    if ($v.Letter) { [void](Test-Path "$($v.Letter):\"); Start-Sleep -Seconds 1 }
    $vol = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber | Get-Volume -ErrorAction SilentlyContinue
    $fsNow = if ($vol) { "$($vol.FileSystemType)" } else { '?' }
    Write-UDLog "After restore: partition $($v.PartitionNumber) file system = $fsNow."
    [pscustomobject]@{ Disk = $DiskNumber; Partition = $v.PartitionNumber; Kind = $fi.Kind; FileSystemNow = $fsNow; SavedOldSectors = $save; ImageOnFile = [bool]$g.Image }
}

function Restore-UsbGpt([int]$DiskNumber, [string]$ConfirmPhrase, [switch]$Preview) {
    # #11: rebuild the primary GPT header + entry array from the intact backup at the end of the disk.
    # Requires the protective MBR to be present: USBDoctor never writes an MBR (DiskPilot rule).
    $d = Get-RepairDisk $DiskNumber
    Assert-Admin 'Reading the partition table'
    $g0 = Get-GptInfo $DiskNumber $d.Size
    if ($g0.PrimaryValid) { throw "Disk ${DiskNumber}: the primary GPT is valid. Nothing to restore." }
    if (-not $g0.BackupValid) { throw "Disk ${DiskNumber}: the backup GPT is not valid either. Nothing safe to restore; image it and rebuild with USBImager." }
    if (-not $g0.ProtectiveMbr) { throw "Disk ${DiskNumber}: the protective MBR is missing too. Restoring would need an MBR write, which USBDoctor refuses (an MBR has no backup; same rule as DiskPilot). Image it and rebuild with USBImager." }
    $g = Assert-WriteGate $d 'PartitionTable' $ConfirmPhrase -Preview:$Preview
    $bh = $g0.Backup
    $entBytes = $bh.Entries * $bh.EntrySize; $entSectors = [int][Math]::Ceiling($entBytes / 512.0)
    $txt = @("Disk $DiskNumber $($d.Model): the primary GPT (sector 1 and the partition list from sector 2) is damaged; the backup at sector $('{0:N0}' -f $g0.BackupLba) is intact ($($bh.Entries) entries).",
        "Write a new primary header (MyLBA=1, AlternateLBA=$($g0.BackupLba), entries at LBA 2, CRCs recomputed) and copy the $entSectors-sector partition list from the backup. The damaged sectors are saved to a file first.",
        'The protective MBR in sector 0 is NOT written.', (Get-GateText $g $DiskNumber))
    if ($Preview) { return New-Plan 'RestoreGpt' 'Restore GPT from backup' $txt $g.NeedsPhrase $DiskNumber }
    $hdr = New-Object byte[] 512; [Array]::Copy($bh.Raw, 0, $hdr, 0, $bh.HeaderSize)
    [Array]::Copy([BitConverter]::GetBytes([int64]1), 0, $hdr, 24, 8)
    [Array]::Copy([BitConverter]::GetBytes([int64]$g0.BackupLba), 0, $hdr, 32, 8)
    [Array]::Copy([BitConverter]::GetBytes([int64]2), 0, $hdr, 72, 8)
    for ($i = 16; $i -lt 20; $i++) { $hdr[$i] = 0 }
    $crc = [UsbDocNative]::Crc32($hdr, 0, $bh.HeaderSize); [Array]::Copy([BitConverter]::GetBytes([uint32]$crc), 0, $hdr, 16, 4)
    $ents = New-Object byte[] ($entSectors * 512); [Array]::Copy($g0.BackupEntries, 0, $ents, 0, [Math]::Min($ents.Length, $g0.BackupEntries.Length))
    $bdir = Join-Path (Get-DefaultDataDir) 'USBDoctor-Backups'; if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
    $save = Join-Path $bdir ('disk{0}-gpt-sectors1-{1}-before-restore-{2}.bin' -f $DiskNumber, (1 + $entSectors), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-UDLog "=== Restore GPT on disk $DiskNumber from backup header at LBA $($g0.BackupLba)"
    [IO.File]::WriteAllBytes($save, (Read-DiskBytes $DiskNumber 512 (512 * (1 + $entSectors))))
    Write-UDLog "Saved the damaged sectors to $save."
    $d = Assert-SameDisk $d
    $locks = Lock-DiskVolumes $DiskNumber
    try {
        $w = [UsbDocNative]::OpenDisk($DiskNumber, $true)
        try { [UsbDocNative]::WriteAt($w, [int64]1024, $ents, $ents.Length); [UsbDocNative]::WriteAt($w, [int64]512, $hdr, 512); [void][UsbDocNative]::Flush($w); [void][UsbDocNative]::UpdateProperties($w) } finally { $w.Close() }
    } finally { foreach ($l in $locks) { $l.Close() } }
    Start-Sleep -Seconds 2; try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch {}; Start-Sleep -Seconds 2
    $g1 = Get-GptInfo $DiskNumber $d.Size
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    Write-UDLog "After restore: primary GPT valid = $($g1.PrimaryValid); Windows sees $($parts.Count) partition(s)."
    if (-not $g1.PrimaryValid) { throw "The primary GPT still does not validate. Undo with the saved sectors in $save." }
    [pscustomobject]@{ Disk = $DiskNumber; PrimaryValid = $g1.PrimaryValid; Partitions = $parts.Count; SavedOldSectors = $save; ImageOnFile = [bool]$g.Image }
}

function Test-DiskBlank($d) {
    # A stick counts as blank if it has no partitions, or only file systems whose root holds nothing but system folders.
    if (-not $d.Volumes.Count) { return [pscustomobject]@{ Blank = $true; Why = 'no partitions' } }
    foreach ($v in $d.Volumes) {
        if (-not $v.FileSystem -or $v.FileSystem -in 'Unknown', 'RAW') { return [pscustomobject]@{ Blank = $false; Why = "partition $($v.PartitionNumber) is RAW, so USBDoctor can't tell whether it holds data" } }
        if (-not $v.Letter) { return [pscustomobject]@{ Blank = $false; Why = "partition $($v.PartitionNumber) has no drive letter, so its contents can't be checked" } }
        $items = @(Get-ChildItem -LiteralPath "$($v.Letter):\" -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'System Volume Information', '$RECYCLE.BIN', 'IndexerVolumeGuid', 'WPSettings.dat' })
        if ($items.Count) { return [pscustomobject]@{ Blank = $false; Why = "$($v.Letter): holds $($items.Count) item(s), e.g. '$($items[0].Name)'" } }
    }
    [pscustomobject]@{ Blank = $true; Why = 'all file systems are empty' }
}

function Test-UsbCapacity {
    # #13: destructive write-read-verify across the full claimed size. ONLY on a blank/empty stick, typed ERASE N.
    param([int]$DiskNumber, [string]$ConfirmPhrase, [switch]$Quick, [int64]$SimulateWrapAt = 0, [switch]$Preview)
    $d = Get-RepairDisk $DiskNumber
    $bl = Test-DiskBlank $d
    if (-not $bl.Blank) { throw "REFUSED: the capacity test erases the whole stick and only runs on a blank/empty one; $($bl.Why). Copy the data off and empty it first." }
    $g = Get-GateStatus $d 'Capacity'
    if ($g.Refusal) { throw "REFUSED on disk ${DiskNumber}: $($g.Refusal)" }
    $blk = 1MB; $start = [int64]1MB; $size = [int64]$d.Size
    $count = [int64][Math]::Floor(($size - $start) / $blk)
    $offs = if ($Quick) { $step = [Math]::Max(1, [int64][Math]::Floor($count / 512)); @(for ($i = [int64]0; $i -lt $count; $i += $step) { $start + $i * $blk }) + @($start + ($count - 1) * $blk) | Sort-Object -Unique } else { @(for ($i = [int64]0; $i -lt $count; $i++) { $start + $i * $blk }) }
    $txt = @("Disk $DiskNumber $($d.Model) claims $(Format-Bytes $size). It is blank ($($bl.Why)).",
        "ERASES THE WHOLE STICK: write a unique pattern to $(@($offs).Count) block(s) of 1 MiB from 1 MiB to the end$(if ($Quick) { ' (quick: evenly spaced sample)' } else { ' (every block)' }), then read every block back.",
        'Blocks that come back wrong mean the flash is smaller than claimed (counterfeit) or failing. The first 1 MiB (partition table) is skipped, but on a counterfeit, writes past the real size wrap around and can land there.',
        'Afterwards the stick holds test data; set it up again with USBImager or DiskPilot if it passes.', "Type ERASE $DiskNumber to confirm.")
    if ($Preview) { $p = New-Plan 'CapacityTest' 'Capacity test (destructive)' $txt $true $DiskNumber; $p.Phrase = "ERASE $DiskNumber"; return $p }
    if ($ConfirmPhrase -ne "ERASE $DiskNumber") { throw "Not confirmed: type ERASE $DiskNumber exactly. Nothing was written." }
    Assert-Admin 'Capacity test'
    Write-UDLog "=== Capacity test disk $DiskNumber $($d.Model) claimed $size bytes, $(@($offs).Count) blocks$(if ($SimulateWrapAt) { ", SIMULATED wrap at $SimulateWrapAt" })"
    $seed = [uint32](Get-Random -Minimum 1 -Maximum 2147483647)
    $d = Assert-SameDisk $d
    $locks = Lock-DiskVolumes $DiskNumber
    $bad = [int64]0; $readErr = [int64]0; $firstBad = [int64]-1; $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $w = [UsbDocNative]::OpenDisk($DiskNumber, $true)
        try { $i = 0; foreach ($o in $offs) { [UsbDocNative]::CapacityWrite($w, [int64]$o, $blk, $seed, $SimulateWrapAt); $i++; if ($t.ElapsedMilliseconds -gt 10000) { Write-UDLog "Capacity test: written $i of $(@($offs).Count) blocks"; $t.Restart() } }; [void][UsbDocNative]::Flush($w) } finally { $w.Close() }
        $r = [UsbDocNative]::OpenDisk($DiskNumber, $false)
        try {
            $i = 0
            foreach ($o in $offs) {
                $c = [UsbDocNative]::CapacityCheck($r, [int64]$o, $blk, $seed, $SimulateWrapAt)
                if ($c -ne 0) { $bad++; if ($c -eq 2) { $readErr++ }; if ($firstBad -lt 0) { $firstBad = [int64]$o } }
                $i++; if ($t.ElapsedMilliseconds -gt 10000) { Write-UDLog "Capacity test: verified $i of $(@($offs).Count) blocks, $bad bad"; $t.Restart() }
            }
        } finally { $r.Close() }
    } finally { foreach ($l in $locks) { $l.Close() } }
    try { Update-Disk -Number $DiskNumber -ErrorAction Stop } catch {}
    $n = @($offs).Count
    $good = [int64]($start + [Math]::Round(($n - $bad) / [double]$n * ($size - $start)))
    if ($bad -eq 0) {
        Write-UDLog "Capacity test PASSED: all $n blocks verified. The stick really stores $(Format-Bytes $size)."
        Update-DeviceHistory $d.Identity $d.Model { param($x) $x.Counterfeit = $null; $x.CapacityTests = @(@($x.CapacityTests) + @(@{ Time = (Get-Date).ToString('s'); Result = 'genuine'; Blocks = $n })) } | Out-Null
        return [pscustomobject]@{ Disk = $DiskNumber; Result = 'Genuine'; Blocks = $n; BadBlocks = 0; Claimed = $size; GoodBytes = $size; Verdict = 'Genuine capacity. If the partition is smaller than the disk, extend or rebuild it (truncated partition).' }
    }
    $verdict = if ($readErr -eq $bad) { 'FAILING flash (read errors), not necessarily fake - condemn it.' } else { "COUNTERFEIT: only about $(Format-Bytes $good) of the claimed $(Format-Bytes $size) stores data. Condemned; capacity 'repair' is impossible." }
    Write-UDLog "Capacity test FAILED: $bad of $n blocks bad ($readErr read errors), first bad at byte $firstBad. $verdict" 'WARN'
    Update-DeviceHistory $d.Identity $d.Model { param($x) $x.Counterfeit = @{ Time = (Get-Date).ToString('s'); Claimed = $size; GoodBytes = $good; BadBlocks = $bad; Blocks = $n; ReadErrors = $readErr }; $x.CapacityTests = @(@($x.CapacityTests) + @(@{ Time = (Get-Date).ToString('s'); Result = 'counterfeit'; Blocks = $n; Bad = $bad })) } | Out-Null
    [pscustomobject]@{ Disk = $DiskNumber; Result = 'Counterfeit'; Blocks = $n; BadBlocks = $bad; ReadErrors = $readErr; FirstBadOffset = $firstBad; Claimed = $size; GoodBytes = $good; Verdict = $verdict }
}

function Expand-UsbPartition([int]$DiskNumber, [int]$PartitionNumber = 0, [string]$ConfirmPhrase, [switch]$Preview) {
    $d = Get-RepairDisk $DiskNumber
    $v = Select-Volume $d $PartitionNumber -Last
    if ($v.FileSystem -in 'FAT', 'FAT32') { throw "Partition $($v.PartitionNumber) is $($v.FileSystem); Windows can't enlarge FAT. Convert it to NTFS first (Convert to NTFS), then extend." }
    if ($v.FileSystem -notin 'NTFS', 'exFAT', 'ReFS') { throw "Partition $($v.PartitionNumber) is '$($v.FileSystem)'; only NTFS (and possibly exFAT) can be extended." }
    $sz = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber
    if ([int64]$sz.SizeMax -le [int64]$v.PartSize + 1MB) { throw "Partition $($v.PartitionNumber) already uses all the space it can ($(Format-Bytes $v.PartSize)). Nothing to do." }
    $txt = @("Disk $DiskNumber $($d.Model): grow partition $($v.PartitionNumber) ($($v.FileSystem) '$($v.Label)') from $(Format-Bytes $v.PartSize) to $(Format-Bytes $sz.SizeMax).",
        'Files stay in place. This rewrites the partition table and file system size. Keep a backup of anything important.')
    if ($v.FileSystem -eq 'exFAT') { $txt += 'Note: Windows may refuse to extend exFAT. If so, nothing is changed.' }
    $g = Assert-WriteGate $d 'Extend' $ConfirmPhrase -Preview:$Preview
    $txt += (Get-GateText $g $DiskNumber)
    if ($Preview) { return New-Plan 'Extend' 'Extend partition to full disk' $txt $g.NeedsPhrase $DiskNumber }
    Assert-Admin 'Extending a partition'
    Write-UDLog "=== Extend disk $DiskNumber partition $($v.PartitionNumber) $($v.FileSystem) to $($sz.SizeMax) bytes"
    try { Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber -Size $sz.SizeMax -ErrorAction Stop }
    catch { throw "Windows could not extend the $($v.FileSystem) partition: $($_.Exception.Message)" }
    $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $v.PartitionNumber
    $vol = $p | Get-Volume -ErrorAction SilentlyContinue
    Write-UDLog ("Partition is now {0}; volume {1}." -f (Format-Bytes $p.Size), $(if ($vol) { Format-Bytes $vol.Size } else { '?' }))
    Write-UDLog '=== Extend OK'
    [pscustomobject]@{ Disk = $DiskNumber; Partition = $v.PartitionNumber; NewSize = [int64]$p.Size; VolumeSize = $(if ($vol) { [int64]$vol.Size } else { 0 }) }
}

function Convert-UsbToNtfs([string]$Letter, [string]$ConfirmPhrase, [switch]$Preview) {
    $x = Get-DiskOfLetter $Letter
    $d = Get-RepairDisk $x.DiskNumber
    $v = $d.Volumes | Where-Object { $_.PartitionNumber -eq $x.PartitionNumber }
    if ($v.FileSystem -notin 'FAT', 'FAT32') { throw "$($x.Letter): is $($v.FileSystem). convert only works on FAT and FAT32." }
    $g = Assert-WriteGate $d 'Convert' $ConfirmPhrase -Preview:$Preview
    $txt = @("Convert $($x.Letter): ($($v.FileSystem) '$($v.Label)', $(Format-Bytes $v.Size), $(Format-Bytes $v.Free) free) on disk $($d.Number) to NTFS in place: convert $($x.Letter): /FS:NTFS /X /NoSecurity.",
        'Files are kept. It is one-way: going back to FAT32 means reformatting.',
        'Some TVs, car stereos, cameras and game consoles cannot read NTFS; Macs can read it but not write it.',
        'Needs some free space for the new NTFS metadata.', (Get-GateText $g $d.Number))
    if ($Preview) { return New-Plan 'ConvertToNtfs' 'Convert FAT32 to NTFS' $txt $g.NeedsPhrase $d.Number }
    Assert-Admin 'Converting to NTFS'
    Write-UDLog "=== Convert $($x.Letter): $($v.FileSystem) -> NTFS"
    $out = "$($v.Label)" | & convert.exe "$($x.Letter):" /FS:NTFS /X /NoSecurity 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    foreach ($l in @($out | Where-Object { $_.Trim() } | Select-Object -Last 12)) { Write-UDLog "convert: $($l.Trim())" }
    Start-Sleep -Seconds 2
    $now = Get-Volume -DriveLetter $x.Letter -ErrorAction SilentlyContinue
    if ($rc -ne 0 -or "$($now.FileSystemType)" -ne 'NTFS') { throw "convert failed (exit $rc, file system now '$($now.FileSystemType)'). See the log." }
    Write-UDLog '=== Convert OK'
    [pscustomobject]@{ Letter = $x.Letter; FileSystem = 'NTFS'; ExitCode = $rc }
}

# ------------------------------------------------------------------ rescue copy
function Find-RescueSource($Ident, [string]$Model, $Prot) {
    $hits = @(foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
        if ($Prot.Contains([int]$d.Number)) { continue }
        $bus = "$($d.BusType)"
        if (-not ($bus -eq 'USB' -or ($bus -eq 'File Backed Virtual' -and $script:AllowVirtual))) { continue }
        if ([int64]$d.Size -le 0) { continue }
        if ($Ident) {
            if ([int64]$d.Size -eq [int64]$Ident.Size -and "$($d.SerialNumber)".Trim() -eq $Ident.Serial -and "$($d.FriendlyName)".Trim() -eq $Ident.Model) { $d }
        } elseif ("$($d.FriendlyName)" -like "*$Model*") { $d }
    })
    if (-not $hits.Count) { return $null }
    if ($Ident -and $hits.Count -gt 1) { $u = @($hits | Where-Object { "$($_.UniqueId)" -eq $Ident.UniqueId }); if ($u.Count) { return $u[0] } }
    $hits[0]
}

function Wait-RescueSource($Ident, [string]$Model, [int]$Minutes, $Prot, $Control) {
    $until = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $until) {
        if ($Control -and $Control.Cancel) { return $null }
        $d = Find-RescueSource $Ident $Model $Prot
        if ($d) { return $d }
        Start-Sleep -Seconds 3
    }
    $null
}

function Save-RescueMap([string]$Map, $Ident, $St, [string]$OutFile) {
    $o = [ordered]@{ Tool = "USBDoctor $script:Version"; Updated = (Get-Date).ToString('s'); Source = $Ident; Image = $OutFile
        Size = [int64]$St.Size; Position = [int64]$St.Position; BytesBad = [int64]$St.BytesBad; Status = "$($St.Status)"
        BadRanges = @($St.BadRanges | ForEach-Object { , @([int64]$_[0], [int64]$_[1]) }) }
    $tmp = "$Map.tmp"
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Map -Force
}

function Start-UsbRescue {
    param([int]$DiskNumber = -1, [string]$WaitForModel, [string]$OutFile, [int]$WaitMinutes = 30,
        [string]$SimulateBadRanges, [int64]$SimulateDropAt = -1, [int64]$StopAfterBytes = 0, $Control)
    Assert-Admin 'Rescue copy'
    $prot = Get-ProtectedDiskNumbers
    if ($DiskNumber -ge 0) { [void](Get-RepairDisk $DiskNumber); $src = Get-Disk -Number $DiskNumber }
    elseif ($WaitForModel) {
        Write-UDLog "Waiting up to $WaitMinutes min for a USB drive whose name contains '$WaitForModel'. Plug it in now."
        $src = Wait-RescueSource $null $WaitForModel $WaitMinutes $prot $Control
        if (-not $src) { throw "No USB drive matching '$WaitForModel' appeared." }
    } else { throw 'Use -Disk N or -WaitForModel <text>.' }
    $ident = [pscustomobject]@{ Model = "$($src.FriendlyName)".Trim(); Serial = "$($src.SerialNumber)".Trim(); Size = [int64]$src.Size; UniqueId = "$($src.UniqueId)" }
    if (-not $OutFile) {
        $OutFile = Join-Path (Join-Path (Get-DefaultDataDir) 'Rescue') ('{0}-{1}.img' -f ($ident.Model -replace '[^A-Za-z0-9]+', '_'), $(if ($ident.Serial) { $ident.Serial -replace '[^A-Za-z0-9]+', '_' } else { 'noserial' }))
    }
    if ((Get-DiskNumberOfPath $OutFile) -eq [int]$src.Number) { throw 'The rescue image cannot be written to the drive being rescued.' }
    $dir = Split-Path $OutFile; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $map = "$OutFile.rescue.json"
    $st = New-Object UsbDocRescueState
    $st.Size = [int64]$ident.Size
    if (Test-Path -LiteralPath $map) {
        $m = Get-Content -LiteralPath $map -Raw | ConvertFrom-Json
        if ([int64]$m.Source.Size -ne $ident.Size -or "$($m.Source.Serial)" -ne $ident.Serial -or "$($m.Source.Model)" -ne $ident.Model) { throw "$map belongs to a different drive ($($m.Source.Model), $($m.Source.Size) bytes). Use another -Out file." }
        $st.Position = [int64]$m.Position
        foreach ($r in @($m.BadRanges)) { if ($r) { $st.AddBad([int64]$r[0], [int64]$r[1]) } }
        Write-UDLog ("Resuming rescue of {0} at {1} of {2} ({3} unreadable so far)." -f $ident.Model, (Format-Bytes $st.Position), (Format-Bytes $st.Size), (Format-Bytes $st.BytesBad))
    } elseif (Test-Path -LiteralPath $OutFile) { throw "$OutFile already exists without a .rescue.json progress file. Choose another -Out file." }
    $have = if (Test-Path -LiteralPath $OutFile) { [int64](Get-Item -LiteralPath $OutFile).Length } else { [int64]0 }
    $free = Get-FreeBytes $OutFile
    if ($free -ge 0 -and $free -lt ([int64]$st.Size - $have)) { throw "Not enough free space for the image: $(Format-Bytes $free) free, $(Format-Bytes ($st.Size - $have)) needed." }
    if ($SimulateBadRanges) { foreach ($p in $SimulateBadRanges.Split(',')) { $a = $p.Split(':'); $st.SimBad.Add([int64[]]@([int64]$a[0], [int64]$a[1])) } }
    $st.SimDropAt = $SimulateDropAt
    $startPos0 = [int64]$st.Position
    if ($StopAfterBytes -gt 0) { $st.StopAt = $startPos0 + $StopAfterBytes }
    $udId = ''; try { $u = @(Get-UsbDisks) | Where-Object { $_.Number -eq [int]$src.Number } | Select-Object -First 1; if ($u) { $udId = $u.Identity } } catch {}
    Write-UDLog ("=== Rescue copy: disk {0} {1} serial '{2}' {3} -> {4}" -f $src.Number, $ident.Model, $ident.Serial, (Format-Bytes $ident.Size), $OutFile)
    Write-UDLog 'Read-only: nothing is written to the drive. Unreadable areas are skipped and zero-filled. If it drops out, unplug and replug it; the copy resumes.'
    $fs = New-Object IO.FileStream($OutFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $startPos = [int64]$st.Position; $clock = [Diagnostics.Stopwatch]::StartNew(); $lastLog = [Diagnostics.Stopwatch]::StartNew(); $drops = 0; $final = ''
    try {
        while ($true) {
            $h = $null
            try { $h = [UsbDocNative]::OpenDisk([int]$src.Number, $false) } catch { Write-UDLog "Cannot open the drive: $($_.Exception.Message)" 'WARN' }
            if ($h) {
                $len = [UsbDocNative]::GetLength($h)
                if ([int64]$len -ne [int64]$ident.Size) { Write-UDLog "Drive reports $len bytes instead of $($ident.Size); treating it as dropped." 'WARN'; $h.Close(); $h = $null }
            }
            if ($h) {
                $st.Status = 'running'
                while ($st.Status -eq 'running') {
                    [UsbDocNative]::RescueSlice($h, $fs, $st, 2000)
                    Save-RescueMap $map $ident $st $OutFile
                    if ($lastLog.ElapsedMilliseconds -gt 10000 -or $st.Status -ne 'running') {
                        $rate = ([int64]$st.Position - $startPos) / [Math]::Max(1, $clock.Elapsed.TotalSeconds)
                        Write-UDLog ("Rescue: {0:N1}% ({1} of {2}), {3}/s, unreadable {4} in {5} range(s)" -f (100.0 * $st.Position / $st.Size), (Format-Bytes $st.Position), (Format-Bytes $st.Size), (Format-Bytes $rate), (Format-Bytes $st.BytesBad), $st.BadRanges.Count)
                        $lastLog.Restart()
                    }
                    if ($Control -and $Control.Cancel) { $st.Status = 'stopped'; Write-UDLog 'Rescue stopped by user; progress saved. Run it again with the same output file to resume.' 'WARN' }
                    elseif ($StopAfterBytes -gt 0 -and ([int64]$st.Position - $startPos) -ge $StopAfterBytes -and $st.Status -eq 'running') { $st.Status = 'stopped'; Write-UDLog "Stopped after $StopAfterBytes bytes (test switch); progress saved." 'WARN' }
                }
                $h.Close()
            } else { $st.Status = 'dropped' }
            Save-RescueMap $map $ident $st $OutFile
            if ($st.Status -in 'done', 'stopped') { $final = $st.Status; break }
            $drops++
            Write-UDLog ("The drive stopped answering at {0:N0} bytes (Win32 error {1}). Progress saved. Unplug it and plug it back in; waiting up to {2} min." -f $st.Position, $st.LastError, $WaitMinutes) 'WARN'
            $fs.Flush()
            $src = Wait-RescueSource $ident $null $WaitMinutes $prot $Control
            if (-not $src) { $final = 'waiting-timeout'; Write-UDLog 'The drive did not come back. Run the same rescue command again later to resume.' 'WARN'; break }
            Write-UDLog "Drive is back as disk $($src.Number). Resuming at $(Format-Bytes $st.Position)."
            Start-Sleep -Seconds 2
        }
    } finally {
        if ($st.Status -eq 'done') { $fs.SetLength([int64]$st.Size) }
        $fs.Flush(); $fs.Close()
    }
    if ($final -eq 'done') {
        $badFile = "$OutFile.badranges.txt"
        $lines = @("# Unreadable ranges (zero-filled in the image): start_byte length_bytes", @($st.BadRanges | ForEach-Object { '{0} {1}' -f $_[0], $_[1] }))
        Set-Content -LiteralPath $badFile -Value $lines -Encoding ASCII
        Write-UDLog ("=== Rescue complete: {0}. Unreadable: {1} in {2} range(s) (listed in {3})." -f $OutFile, (Format-Bytes $st.BytesBad), $st.BadRanges.Count, $badFile)
        $fullOut = (Resolve-Path -LiteralPath $OutFile).ProviderPath; $bb = [int64]$st.BytesBad; $sz = [int64]$st.Size
        if ($udId) { Update-DeviceHistory $udId $ident.Model { param($x) $x.Images = @(@($x.Images) + @(@{ Time = (Get-Date).ToString('s'); Path = $fullOut; Complete = $true; Size = $sz; BadBytes = $bb })) } | Out-Null; Write-UDLog "Image recorded in the device history ($udId); gated repairs no longer need the typed risk phrase." }
    }
    [pscustomobject]@{ Image = $OutFile; Status = $final; Size = [int64]$st.Size; Position = [int64]$st.Position; BytesBad = [int64]$st.BytesBad; BadRanges = $st.BadRanges.Count; DropOuts = $drops; Map = $map }
}

# ------------------------------------------------------------------ report
function New-UsbDoctorReport([string]$OutDir, [int]$Days = 7, $Diag, [string[]]$ExtraText, [string]$ExtraHtml) {
    if (-not $OutDir) { $OutDir = if (Test-Path 'D:\') { 'D:\USB-Backups\Reports' } else { Join-Path $env:USERPROFILE 'Documents' } }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    if (-not $Diag) { $Diag = Invoke-UsbDiagnosis -Days $Days }
    $lines = @(Format-UsbDiagnosis $Diag) + @($ExtraText)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $txt = Join-Path $OutDir "USBDoctor-$stamp.txt"; $html = Join-Path $OutDir "USBDoctor-$stamp.html"
    Set-Content -LiteralPath $txt -Value $lines -Encoding UTF8
    $color = @{ OK = '#1a7f37'; INFO = '#555'; WARN = '#9a6700'; PROBLEM = '#cf222e'; FAILING = '#a40e26' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>USBDoctor report $stamp</title><style>body{font-family:Segoe UI,Arial;margin:24px}td,th{border:1px solid #ccc;padding:4px 8px;vertical-align:top}table{border-collapse:collapse}pre{background:#f6f8fa;padding:10px}</style></head><body>")
    [void]$sb.Append("<h2>USBDoctor report - $([Net.WebUtility]::HtmlEncode($Diag.Computer)) - $($Diag.Time.ToString('yyyy-MM-dd HH:mm'))</h2>")
    [void]$sb.Append('<table><tr><th>Disk</th><th>Drive</th><th>State</th><th>Fault owner</th><th>Safe action / refusal</th></tr>')
    foreach ($r in $Diag.Disks) {
        $act = [Net.WebUtility]::HtmlEncode(((@($r.Assessment.Actions) + @($r.Assessment.Refusals | ForEach-Object { "REFUSED: $_" })) -join "`n")) -replace "`n", '<br>'
        [void]$sb.Append(("<tr><td>{0}</td><td>{1}<br>{2}</td><td style='color:{3}'><b>{4}</b></td><td>{5}</td><td>{6}<br><i>To change: {7}</i></td></tr>" -f $r.Disk.Number, [Net.WebUtility]::HtmlEncode($r.Disk.Model), [Net.WebUtility]::HtmlEncode($r.Disk.Summary), $color[$r.Level], [Net.WebUtility]::HtmlEncode($r.Verdict), [Net.WebUtility]::HtmlEncode($r.Assessment.FaultOwner), $act, [Net.WebUtility]::HtmlEncode($r.Assessment.Change)))
    }
    if (-not $Diag.Disks.Count) { [void]$sb.Append('<tr><td colspan=5>No USB drives attached.</td></tr>') }
    [void]$sb.Append('</table>'); if ($ExtraHtml) { [void]$sb.Append($ExtraHtml) }; [void]$sb.Append('<h3>Full details</h3><pre>' + [Net.WebUtility]::HtmlEncode(($lines -join "`r`n")) + '</pre></body></html>')
    Set-Content -LiteralPath $html -Value $sb.ToString() -Encoding UTF8
    Write-UDLog "Report written: $txt and $html"
    [pscustomobject]@{ Text = $txt; Html = $html }
}

Export-ModuleMember -Function Set-UDConfig, Get-UDLogFile, Get-UDVersion, Write-UDLog, Format-Bytes, Test-IsAdmin, Get-DefaultDataDir,
    Get-UsbDisks, Get-RepairDisk, Get-UsbProblemDevices, Get-AutomountState, Get-SelectiveSuspendState, Get-UsbEventHistory, Get-DeviceHistorySummary,
    Get-BootSectorInfo, Test-ImageUsbShift, Invoke-UsbDiagnosis, Format-UsbDiagnosis, Format-UsbDisk, Format-Assessment, Get-LetterUse, Get-MountedLetterEntry, Test-PersistentLetter,
    Set-UsbDriveLetter, Enable-UsbAutomount, Set-UsbDiskOnline, Clear-UsbReadOnly, Invoke-UsbChkdsk, Disable-UsbSelectiveSuspend, Remove-UsbGhostDevices, Reset-UsbDevice,
    Dismount-UsbDrive, Convert-ImageUsbFile, Invoke-ImageUsbFix, Restore-UsbBootSector, Restore-UsbGpt, Test-UsbCapacity, Test-DiskBlank, Expand-UsbPartition, Convert-UsbToNtfs,
    Start-UsbRescue, New-UsbDoctorReport, Get-DiskOfLetter, Get-UDHistory, Get-DeviceHistoryRecord, Get-DeviceImage, Set-Tier0Result, Test-RawRead, Test-MachineHealth,
    Get-PartitionFsInfo, Get-GptInfo, Get-GateStatus, Assert-WriteGate, Test-VolumeAccess, Get-UsbImagerPath,
    Invoke-Diskpart, New-Plan, Assert-SameDisk, Lock-DiskVolumes, Get-FreeBytes, Update-DeviceHistory, Get-DyingSignatures, Assert-Admin, Save-UDHistory,
    Get-DeviceRecord, Get-PortKey, Read-DiskBytes, Get-ProtectedDiskNumbers, Get-DiskNumberOfPath, Invoke-WithTimeout, Get-PartLetter
