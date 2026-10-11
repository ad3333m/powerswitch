using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// Lets the PowerSwitch iPhone app put this PC to sleep or shut it down. Turning it on is the phone's job (Wake-on-LAN).
static class Power
{
    [DllImport("powrprof.dll")] static extern bool SetSuspendState(bool hibernate, bool force, bool disableWakeEvent);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll")] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokenPrivileges { public int Count; public long Luid; public int Attributes; }

    // SetSuspendState needs SeShutdownPrivilege, which every user has but which starts disabled.
    static void EnableShutdownPrivilege()
    {
        IntPtr token;
        if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x28 /* ADJUST_PRIVILEGES | QUERY */, out token)) return;
        var tp = new TokenPrivileges { Count = 1, Attributes = 2 /* SE_PRIVILEGE_ENABLED */ };
        if (LookupPrivilegeValue(null, "SeShutdownPrivilege", out tp.Luid)) AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(token);
    }

    public static void Sleep() { EnableShutdownPrivilege(); SetSuspendState(false, false, false); }

    public static void ShutDown() { Process.Start(new ProcessStartInfo("shutdown.exe", "/s /t 0") { CreateNoWindow = true, UseShellExecute = false }); }
}

// Tiny HTTP server: GET /ping, POST /sleep, POST /shutdown, each needing the pairing code in an X-Key header.
static class Server
{
    public const int Port = 47823;

    public static void Start(Func<string, string, int> handle)
    {
        var listener = new TcpListener(IPAddress.Any, Port);
        listener.Start();
        new Thread(delegate()
        {
            while (true)
            {
                var client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(delegate { Serve(client, handle); });
            }
        }) { IsBackground = true }.Start();
    }

    static void Serve(TcpClient client, Func<string, string, int> handle)
    {
        try
        {
            using (client)
            {
                var stream = client.GetStream();
                stream.ReadTimeout = 3000;
                var reader = new StreamReader(stream, Encoding.ASCII);
                string[] request = (reader.ReadLine() ?? "").Split(' ');
                string key = "", line;
                while (!string.IsNullOrEmpty(line = reader.ReadLine()))
                    if (line.StartsWith("x-key:", StringComparison.OrdinalIgnoreCase)) key = line.Substring(6).Trim();

                int status = request.Length < 2 ? 400 : handle(request[1], key);
                string body = status == 200 ? "ok" : status == 401 ? "wrong code" : "not found";
                byte[] reply = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " " + body + "\r\nContent-Type: text/plain\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body);
                stream.Write(reply, 0, reply.Length);
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }
}

class MainForm : Form
{
    const string SettingsKey = @"Software\PowerSwitch", RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static readonly Color Bg = Color.FromArgb(24, 24, 27), Card = Color.FromArgb(39, 39, 42),
        Accent = Color.FromArgb(16, 185, 129), Fg = Color.FromArgb(244, 244, 245), Dim = Color.FromArgb(161, 161, 170);

    readonly string code;
    NotifyIcon tray;
    TextBox ipBox, macBox;
    bool quitting, startHidden;

    public MainForm(bool hidden)
    {
        startHidden = hidden;
        code = LoadOrCreateCode();

        Text = "PowerSwitch";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Bg;
        Font = new Font("Segoe UI", 10f);
        AutoScaleDimensions = new SizeF(96f, 96f);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(420, 318);

        Controls.Add(new Label { Text = "PowerSwitch", ForeColor = Fg, Font = new Font("Segoe UI Semibold", 13f), Location = new Point(20, 14), AutoSize = true });
        Controls.Add(new Label { Text = "Type these into PowerSwitch on your iPhone.", ForeColor = Dim, Location = new Point(20, 44), AutoSize = true });
        ipBox = Field("PC address", 76);
        macBox = Field("MAC address", 126);
        Field("Pairing code", 176).Text = code;
        Controls.Add(new Label
        {
            Text = "Over Wi-Fi the phone can wake this PC from Sleep. Waking it after Shut Down needs an Ethernet cable.",
            ForeColor = Dim, Location = new Point(20, 228), Size = new Size(380, 40)
        });

        var startup = new CheckBox { Text = "Start with Windows", ForeColor = Fg, Location = new Point(20, 280), AutoSize = true, Checked = StartsWithWindows(), TabStop = false };
        startup.CheckedChanged += delegate { SetStartWithWindows(startup.Checked); };
        Controls.Add(startup);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, delegate { ShowWindow(); });
        menu.Items.Add("Exit", null, delegate { quitting = true; Close(); });
        tray = new NotifyIcon { Icon = Icon, Text = "PowerSwitch", ContextMenuStrip = menu, Visible = true };
        tray.MouseDoubleClick += delegate { ShowWindow(); };

        RefreshAddress();
        NetworkChange.NetworkAddressChanged += delegate { BeginInvoke((Action)RefreshAddress); };
    }

    TextBox Field(string label, int y)
    {
        Controls.Add(new Label { Text = label, ForeColor = Dim, Location = new Point(20, y + 12), AutoSize = true });
        var box = new TextBox
        {
            ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Card, ForeColor = Fg,
            Font = new Font("Consolas", 13f), Location = new Point(140, y + 8), Width = 260, TabStop = false
        };
        Controls.Add(new Panel { BackColor = Card, Location = new Point(130, y), Size = new Size(270, 40) });
        Controls.Add(box);
        box.BringToFront();
        return box;
    }

    // The Wi-Fi or Ethernet adapter that has the default gateway (skips VPN tunnels like NordLynx).
    void RefreshAddress()
    {
        var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n =>
            n.OperationalStatus == OperationalStatus.Up &&
            (n.NetworkInterfaceType == NetworkInterfaceType.Ethernet || n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211) &&
            n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork) &&
            !n.Description.ToLower().Contains("virtual"));
        if (nic == null) { ipBox.Text = "not connected"; macBox.Text = ""; return; }
        var ip = nic.GetIPProperties().UnicastAddresses.FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
        ipBox.Text = ip == null ? "" : ip.Address.ToString();
        macBox.Text = string.Join(":", nic.GetPhysicalAddress().GetAddressBytes().Select(b => b.ToString("X2")));
    }

    // ---- pairing code ----

    static string LoadOrCreateCode()
    {
        using (var k = Registry.CurrentUser.CreateSubKey(SettingsKey))
        {
            var existing = k.GetValue("Code") as string;
            if (!string.IsNullOrEmpty(existing)) return existing;
            const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 32 symbols, no 0/O or 1/I
            var bytes = new byte[10];
            using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(bytes);
            string code = new string(bytes.Select(b => alphabet[b % 32]).ToArray());
            k.SetValue("Code", code);
            SetStartWithWindows(true); // first run: it only helps if it is running
            return code;
        }
    }

    static bool SameCode(string a, string b)
    {
        if (a.Length != b.Length) return false;
        int diff = 0;
        for (int i = 0; i < a.Length; i++) diff |= char.ToUpperInvariant(a[i]) ^ b[i];
        return diff == 0;
    }

    // Runs on a server thread; the actual sleep/shutdown waits a moment so the reply reaches the phone first.
    int OnRequest(string path, string key)
    {
        if (path != "/ping" && path != "/sleep" && path != "/shutdown") return 404;
        if (!SameCode(key, code)) return 401;
        if (path == "/sleep") Later(Power.Sleep);
        if (path == "/shutdown") Later(Power.ShutDown);
        return 200;
    }

    void Later(Action act)
    {
        BeginInvoke((Action)delegate
        {
            var t = new System.Windows.Forms.Timer { Interval = 800 };
            t.Tick += delegate { t.Dispose(); act(); };
            t.Start();
        });
    }

    // ---- start with Windows ----

    static bool StartsWithWindows()
    {
        using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
            return k != null && k.GetValue("PowerSwitch") != null;
    }

    static void SetStartWithWindows(bool on)
    {
        using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            if (on) k.SetValue("PowerSwitch", "\"" + Application.ExecutablePath + "\" /tray");
            else k.DeleteValue("PowerSwitch", false);
    }

    // ---- window / tray ----

    protected override void SetVisibleCore(bool value)
    {
        if (!IsHandleCreated)
        {
            CreateHandle();
            try { Server.Start(OnRequest); }
            catch (SocketException)
            {
                MessageBox.Show("Port " + Server.Port + " is already in use, so the iPhone app can't reach this PC.", "PowerSwitch", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (startHidden) value = false;
        }
        base.SetVisibleCore(value);
    }

    void ShowWindow()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
        tray.Visible = false;
        base.OnFormClosing(e);
    }
}

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        bool fresh;
        using (new Mutex(true, "PowerSwitch.SingleInstance", out fresh))
        {
            if (!fresh) return;
            Application.EnableVisualStyles();
            Application.Run(new MainForm(args.Contains("/tray")));
        }
    }
}
