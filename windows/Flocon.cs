// Flocon pour Windows : il neige sur le bureau, la neige se pose sur les fenêtres et sur la barre des tâches.
// Un seul fichier. Deux calques transparents plein écran, que les clics traversent :
//   - « fond », tout en bas de la pile des fenêtres : les flocons tombent derrière les fenêtres ;
//   - « avant », toujours au-dessus : la neige posée et les paquets qui tombent.
// L'icône près de l'horloge porte les réglages. Compiler : dotnet build -c Release (voir LISEZ-MOI à la racine).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
[StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] struct SIZE { public int W, H; }
[StructLayout(LayoutKind.Sequential)] struct BLEND { public byte Op, Flags, Alpha, Format; }
[StructLayout(LayoutKind.Sequential)] struct BMPHEADER {
    public int Size, Width, Height; public short Planes, BitCount;
    public int Compression, SizeImage, XPels, YPels, ClrUsed, ClrImportant;
}
[StructLayout(LayoutKind.Sequential)] unsafe struct ULWINFO {
    public int cb; public IntPtr hdcDst; public POINT* dst; public SIZE* size; public IntPtr hdcSrc; public POINT* src;
    public int key; public BLEND* blend; public int flags; public RECT* dirty;
}

static class Native {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, int flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindowIndirect(IntPtr h, ref ULWINFO info);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] public static extern int DwmGetWindowAttributeInt(IntPtr h, int attr, out int v, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BMPHEADER h, int usage, out IntPtr bits, IntPtr section, int offset);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
}

// MARK: Morceaux visibles d'un bord

struct Seg { public float a, b; public Seg(float a, float b) { this.a = a; this.b = b; } }

static class Segs {
    /// Ce qui reste de [a, b] une fois retirés les trous ; les restes de moins de 8 px sont ignorés.
    public static List<Seg> Subtract(float a, float b, List<Seg> holes) {
        var rest = new List<Seg>();
        if (b - a >= 8) rest.Add(new Seg(a, b));
        foreach (var hole in holes) {
            var next = new List<Seg>();
            foreach (var s in rest) {
                if (hole.b <= s.a || hole.a >= s.b) { next.Add(s); continue; }
                if (hole.a - s.a >= 8) next.Add(new Seg(s.a, hole.a));
                if (s.b - hole.b >= 8) next.Add(new Seg(hole.b, s.b));
            }
            rest = next;
        }
        return rest;
    }
    public static bool Same(List<Seg> x, List<Seg> y) {
        if (x.Count != y.Count) return false;
        for (int i = 0; i < x.Count; i++) if (x[i].a != y[i].a || x[i].b != y[i].b) return false;
        return true;
    }
}

// MARK: Neige posée sur un bord (dessus d'une fenêtre, barre des tâches)

/// La neige est rangée en colonnes de largeur fixe. La colonne 0 commence à « origin », une position à l'écran :
/// quand la fenêtre change de largeur, la neige ne bouge donc pas, et ce qui dépasse tombe.
sealed class Ledge {
    public readonly List<float> h = new List<float>();
    public readonly float col, maxH;
    public float origin, left, right, y;
    public List<Seg> visible = new List<Seg>();
    public Rectangle rect;
    public int stamp;
    public Ledge(float col, float maxH) { this.col = col; this.maxH = maxH; }

    /// Nouveau bord [l, r] : les colonnes qui n'ont plus de support sont rendues à « drop » (position, hauteur).
    public void Resize(float l, float r, Action<float, float> drop) {
        if (h.Count == 0) origin = l;
        left = l; right = r;
        while (h.Count > 0 && origin + col <= l + 0.001f) { Drop(0, drop); h.RemoveAt(0); origin += col; }
        while (h.Count > 0 && origin + h.Count * col - col >= r - 0.001f) { Drop(h.Count - 1, drop); h.RemoveAt(h.Count - 1); }
        if (h.Count == 0) origin = l;
        while (origin - col >= l - 0.001f) { h.Insert(0, 0); origin -= col; }
        while (origin + (h.Count + 1) * col <= r + 0.001f) h.Add(0);
    }
    public void Shift(float dx) { origin += dx; left += dx; right += dx; }
    public void Shed(Action<float, float> drop) { for (int i = 0; i < h.Count; i++) Drop(i, drop); h.Clear(); }
    void Drop(int i, Action<float, float> drop) { if (drop != null && h[i] > 0) drop(origin + (i + 0.5f) * col, h[i]); }

    /// Hauteur de neige à la position x, lissée entre les colonnes et arrondie aux deux bouts du bord.
    public float Height(float x) {
        float f = (x - origin) / col - 0.5f;
        int i = (int)Math.Floor(f);
        float t = f - i;
        float a = i >= 0 && i < h.Count ? h[i] : 0, b = i + 1 >= 0 && i + 1 < h.Count ? h[i + 1] : 0;
        float edge = Math.Min(x - left, right - x);
        return Math.Max(0, Math.Min(a + (b - a) * t, edge * 0.9f));
    }
    public bool Covers(float x) {
        foreach (var s in visible) if (x >= s.a && x < s.b) return true;
        return false;
    }
    /// Un flocon se pose en x. La neige glisse vers la colonne voisine si la pente est trop raide. Faux si c'est plein.
    public bool Deposit(float x, float amount) {
        int i = (int)Math.Floor((x - origin) / col);
        if (i < 0 || i >= h.Count) return false;
        for (int n = 0; n < 3; n++) {
            int j = i;
            if (i > 0 && h[i - 1] < h[j]) j = i - 1;
            if (i + 1 < h.Count && h[i + 1] < h[j]) j = i + 1;
            if (j == i || h[i] - h[j] < col * 0.7f) break;
            i = j;
        }
        if (h[i] >= maxH) return false;
        h[i] = Math.Min(maxH, h[i] + amount);
        return true;
    }
    public float Total() { float s = 0; foreach (float v in h) s += v; return s; }
}

// MARK: Fenêtres des autres applications

sealed class Win { public IntPtr h; public Rectangle r; public bool ledge, tray; }

static class Desk {
    static readonly List<Win> list = new List<Win>();
    static readonly Dictionary<IntPtr, string> classes = new Dictionary<IntPtr, string>();
    static readonly StringBuilder sb = new StringBuilder(80);
    static readonly Native.EnumProc proc = Each;   // gardé en vie : Windows le rappelle
    static IntPtr back, front;
    static bool backSeen, desktopSeen;
    static float scale;
    /// Le calque de fond est-il bien juste au-dessus du bureau ? Sinon, la fenêtre sous laquelle le glisser.
    public static bool backOk;
    public static IntPtr lowest;

    /// Fenêtres visibles, de la plus haute à la plus basse dans la pile.
    public static List<Win> Scan(IntPtr backLayer, IntPtr frontLayer, float s) {
        list.Clear();
        back = backLayer; front = frontLayer; scale = s;
        backSeen = desktopSeen = false; lowest = IntPtr.Zero;
        if (classes.Count > 2000) classes.Clear();
        Native.EnumWindows(proc, IntPtr.Zero);
        if (!desktopSeen) backOk = backSeen;
        return list;
    }

    static string ClassOf(IntPtr h) {
        string c;
        if (classes.TryGetValue(h, out c)) return c;
        sb.Length = 0;
        Native.GetClassName(h, sb, 80);
        return classes[h] = sb.ToString();
    }

    static bool Each(IntPtr h, IntPtr p) {
        if (desktopSeen || h == front || !Native.IsWindowVisible(h)) return true;
        if (h == back) { backSeen = true; return true; }
        int cloaked;   // fenêtre d'un autre bureau virtuel, ou app du Store en veille : là sans être affichée
        if (Native.DwmGetWindowAttributeInt(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
        string c = ClassOf(h);
        if (c == "Progman" || c == "WorkerW") { desktopSeen = true; backOk = backSeen; return true; }
        if (Native.IsIconic(h)) return true;
        int ex = Native.GetWindowLong(h, -20);
        if ((ex & 0x20) != 0) return true;   // calque d'une autre app que les clics traversent : ce n'est pas un obstacle
        RECT r;
        if (Native.DwmGetWindowAttribute(h, 9, out r, 16) != 0) Native.GetWindowRect(h, out r);   // 9 : le cadre réellement dessiné
        if (r.R - r.L < 1 || r.B - r.T < 1) return true;
        backSeen = false; lowest = h;   // une fenêtre visible se trouve sous notre fond : il n'est pas (ou plus) tout en bas
        var w = new Win { h = h, r = Rectangle.FromLTRB(r.L, r.T, r.R, r.B), tray = c == "Shell_TrayWnd" };
        w.ledge = !w.tray && (ex & 0x08000080) == 0 && Native.GetWindow(h, 4) == IntPtr.Zero   // ni palette, ni menu, ni dialogue
            && w.r.Width >= 150 * scale && w.r.Height >= 80 * scale;
        list.Add(w);
        return true;
    }
}

// MARK: Calque transparent plein écran

sealed unsafe class Layer : Form {
    readonly bool top;
    IntPtr dc, bmp, old;
    bool full;                       // la prochaine image doit être envoyée en entier
    public uint* px;                 // pixels blancs, opacité prémultipliée
    public int W, H;
    int bx0, by0, bx1, by1;          // zone touchée depuis le dernier effacement

    public Layer(bool top) {
        this.top = top;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            var p = base.CreateParams;
            p.Style = unchecked((int)0x80000000);                            // sans cadre
            p.ExStyle = 0x80000 | 0x20 | 0x80 | 0x08000000 | (top ? 8 : 0);  // transparent, traversé par les clics, hors Alt+Tab, jamais actif
            return p;
        }
    }
    public void Fit(Rectangle r) {
        Release();
        W = r.Width; H = r.Height;
        var hd = new BMPHEADER { Size = 40, Width = W, Height = -H, Planes = 1, BitCount = 32 };
        dc = Native.CreateCompatibleDC(IntPtr.Zero);
        IntPtr bits;
        bmp = Native.CreateDIBSection(dc, ref hd, 0, out bits, IntPtr.Zero, 0);
        old = Native.SelectObject(dc, bmp);
        px = (uint*)bits;
        full = true; ResetBox();
        Native.SetWindowPos(Handle, (IntPtr)(top ? -1 : 1), r.X, r.Y, W, H, 0x10);
    }
    void Release() {
        if (dc == IntPtr.Zero) return;
        Native.SelectObject(dc, old); Native.DeleteObject(bmp); Native.DeleteDC(dc);
        dc = IntPtr.Zero; px = null;
    }
    public void SetShown(bool on) { Native.ShowWindow(Handle, on ? 4 : 0); if (on) full = true; }

    void ResetBox() { bx0 = W; by0 = H; bx1 = 0; by1 = 0; }
    public void Touch(int x0, int y0, int x1, int y1) {
        if (x0 < bx0) bx0 = x0; if (y0 < by0) by0 = y0; if (x1 > bx1) bx1 = x1; if (y1 > by1) by1 = y1;
    }
    public void Clear(int x0, int y0, int x1, int y1) {
        if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > W) x1 = W; if (y1 > H) y1 = H;
        for (int y = y0; y < y1; y++) { uint* p = px + (long)y * W + x0; for (int x = x0; x < x1; x++) *p++ = 0; }
    }
    /// Efface la zone touchée et repart de zéro ; rend cette zone pour l'envoi suivant.
    public RECT ClearTouched() {
        var r = new RECT { L = bx0, T = by0, R = bx1, B = by1 };
        Clear(bx0, by0, bx1, by1); ResetBox();
        return r;
    }
    /// Disque blanc aux bords doux, centré au pixel près ou entre deux pixels.
    public void Disc(float cx, float cy, float r, float alpha) {
        int x0 = Math.Max(0, (int)(cx - r - 1)), x1 = Math.Min(W, (int)(cx + r + 2));
        int y0 = Math.Max(0, (int)(cy - r - 1)), y1 = Math.Min(H, (int)(cy + r + 2));
        for (int y = y0; y < y1; y++) {
            float dy = y + 0.5f - cy;
            uint* p = px + (long)y * W + x0;
            for (int x = x0; x < x1; x++, p++) {
                float dx = x + 0.5f - cx;
                float c = r + 0.5f - (float)Math.Sqrt(dx * dx + dy * dy);
                if (c <= 0) continue;
                uint a = (uint)((c > 1 ? 1 : c) * alpha * 255);
                uint under = *p >> 24;
                *p = (a + under * (255 - a) / 255) * 0x01010101u;
            }
        }
    }
    /// Envoie l'image à l'écran : en entier, ou seulement la zone donnée.
    public void Present(bool whole, RECT zone) {
        var dst = new POINT(); var size = new SIZE { W = W, H = H }; var src = new POINT();
        var blend = new BLEND { Alpha = 255, Format = 1 };
        var info = new ULWINFO { cb = sizeof(ULWINFO), hdcSrc = dc, dst = &dst, size = &size, src = &src, blend = &blend, flags = 2 };
        zone.L = Math.Max(0, Math.Min(zone.L, bx0)); zone.T = Math.Max(0, Math.Min(zone.T, by0));
        zone.R = Math.Min(W, Math.Max(zone.R, bx1)); zone.B = Math.Min(H, Math.Max(zone.B, by1));
        if (!whole && !full) { if (zone.R <= zone.L || zone.B <= zone.T) return; info.dirty = &zone; }
        Native.UpdateLayeredWindowIndirect(Handle, ref info);
        full = false;
    }
}

// MARK: La scène (tourne sur son propre fil, au rythme de l'écran)

struct Flake { public float x, y, r, vy, k, phase, w; public int lx, ly, ls; }
struct Lump { public float x, y, r, vx, vy; }

sealed unsafe class Scene {
    Layer back, front;
    Rectangle bounds;
    int W, H, frame, stamp;
    float s = 1, col = 3, t, fade, evap;
    int state = 2;                 // 0 = il neige, 1 = la neige s'évapore, 2 = tout est caché
    bool bare;                     // pendant l'évaporation, plus rien ne se pose
    bool frontDirty;
    Flake[] flakes = new Flake[0];
    readonly List<Lump> lumps = new List<Lump>();
    readonly Dictionary<IntPtr, Ledge> ledges = new Dictionary<IntPtr, Ledge>();
    readonly List<Ledge> all = new List<Ledge>();   // les bords de fenêtres, puis le sol
    readonly List<IntPtr> gone = new List<IntPtr>();
    Ledge ground;
    RECT lastFront;
    readonly Random rnd = new Random();
    public volatile string status = "etat=2";

    float Rand() { return (float)rnd.NextDouble(); }

    public void Run() {
        back = new Layer(false); front = new Layer(true);
        var clock = Stopwatch.StartNew();
        double last = 0;
        while (!App.quit) {
            Application.DoEvents();
            bool want = App.enabled && !App.locked;
            if (state == 2) {
                status = "etat=2";
                if (!want) { Thread.Sleep(100); continue; }
                Show(); last = clock.Elapsed.TotalSeconds;
            }
            if (state == 0 && !want) { state = 1; evap = 0.6f; bare = true; }
            if (state == 1 && want) { state = 0; bare = false; }
            double now = clock.Elapsed.TotalSeconds;
            float dt = (float)Math.Max(0, Math.Min(0.05, now - last));
            last = now;
            Step(dt);
            if (state == 1 && (evap -= dt) <= 0) Hide();
            if (Native.DwmFlush() != 0) Thread.Sleep(15);   // attend la prochaine image de l'écran
        }
    }

    void Show() {
        var b = Screen.PrimaryScreen.Bounds;   // shortcut: écran principal seulement ; un jeu de calques par écran si le multi-écran devient utile
        if (b != bounds || back.px == null) Fit(b);
        back.SetShown(true); front.SetShown(true);
        state = 0; bare = false; fade = 0;
    }
    void Fit(Rectangle b) {
        bounds = b; W = b.Width; H = b.Height;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) s = g.DpiX / 96f;
        col = 3 * s;
        back.Fit(b); front.Fit(b);
        flakes = new Flake[0]; lumps.Clear(); ledges.Clear();
        ground = new Ledge(col, 24 * s);
        ground.Resize(0, W, null);
        ground.y = H;
        lastFront = new RECT();
    }
    void Hide() {
        ledges.Clear(); lumps.Clear(); ground.Shed(null); ground.Resize(0, W, null);
        back.Clear(0, 0, W, H); front.Clear(0, 0, W, H);
        back.Present(true, new RECT()); front.Present(true, new RECT());
        flakes = new Flake[0];
        back.SetShown(false); front.SetShown(false);
        state = 2;
    }

    void Step(float dt) {
        t += dt; frame++;
        if (frame % 60 == 0 && Screen.PrimaryScreen.Bounds != bounds) Fit(Screen.PrimaryScreen.Bounds);
        Track();
        fade = state == 1 ? Math.Max(0, evap / 0.6f) : Math.Min(1, fade + dt * 1.5f);
        if (state == 1) {
            float k = (float)Math.Exp(-9 * dt);
            foreach (var L in all) for (int i = 0; i < L.h.Count; i++) L.h[i] *= k;
            lumps.Clear(); frontDirty = true;
        }
        StepFlakes(dt);
        StepLumps(dt);
        back.Present(true, new RECT());   // shortcut: tout l'écran renvoyé à chaque image ; par zones si les écrans 4K peinent
        if (frontDirty) { DrawFront(); frontDirty = false; }
        if (frame % 20 == 0) {
            float win = 0;
            foreach (var L in ledges.Values) win += L.Total();
            status = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "etat={0} flocons={1} rebords={2} neige_sol={3:0} neige_fenetres={4:0} fond_ok={5} ecran={6}x{7} echelle={8:0.00}",
                state, flakes.Length, ledges.Count, ground.Total(), win, Desk.backOk ? 1 : 0, W, H, s);
        }
    }

    // Suit les fenêtres : où sont leurs bords du haut, quelles parties en sont visibles, lesquelles ont disparu.
    void Track() {
        var wins = Desk.Scan(back.Handle, front.Handle, s);
        if (!Desk.backOk && frame % 20 == 0)   // le fond doit rester juste au-dessus du bureau, sous toutes les fenêtres
            Native.SetWindowPos(back.Handle, Desk.lowest, 0, 0, 0, 0, 0x13);
        int gy = H;
        foreach (var w in wins)   // barre des tâches en bas et sortie (masquée automatiquement, elle ne dépasse que de 2 px)
            if (w.tray && w.r.Width >= W * 0.9f && w.r.Top > H / 2 && w.r.Top < H - 4) gy = w.r.Top;
        if (ground.y != gy) { ground.y = gy; frontDirty = true; }
        stamp++;
        all.Clear();
        float inset = 3 * s;   // coins arrondis des fenêtres
        for (int i = 0; i < wins.Count; i++) {
            var w = wins[i];
            if (!w.ledge || w.r.Top < 8 || w.r.Top > gy - 4) continue;   // agrandie ou hors écran : pas de bord où se poser
            Ledge L;
            if (!ledges.TryGetValue(w.h, out L)) {
                L = new Ledge(col, 14 * s);
                L.Resize(w.r.Left + inset, w.r.Right - inset, null);
                ledges[w.h] = L; frontDirty = true;
            } else if (L.rect != w.r) {
                if (L.rect.Width == w.r.Width) L.Shift(w.r.Left - L.rect.Left);   // déplacée : la neige suit
                else { float y = L.y; L.Resize(w.r.Left + inset, w.r.Right - inset, (x, hh) => AddLump(x, y, hh)); }
                frontDirty = true;
            }
            L.rect = w.r; L.y = w.r.Top; L.stamp = stamp;
            var holes = new List<Seg>();
            for (int j = 0; j < i; j++) {   // fenêtres placées devant celle-ci
                var o = wins[j].r;
                if (o.Top < L.y && o.Bottom > L.y - 3) holes.Add(new Seg(o.Left, o.Right));
            }
            var vis = Segs.Subtract(Math.Max(0, L.left), Math.Min(W, L.right), holes);
            if (!Segs.Same(vis, L.visible)) { L.visible = vis; frontDirty = true; }
            all.Add(L);
        }
        gone.Clear();
        foreach (var kv in ledges) if (kv.Value.stamp != stamp) gone.Add(kv.Key);
        foreach (var h in gone) {   // fermée, réduite ou agrandie : sa neige tombe tout de suite
            var L = ledges[h];
            float y = L.y;
            L.Shed((x, hh) => AddLump(x, y, hh));
            ledges.Remove(h); frontDirty = true;
        }
        var cover = new List<Seg>();
        foreach (var w in wins) if (!w.tray && w.r.Top < gy && w.r.Bottom > gy - 3) cover.Add(new Seg(w.r.Left, w.r.Right));
        var gv = Segs.Subtract(0, W, cover);
        if (!Segs.Same(gv, ground.visible)) { ground.visible = gv; frontDirty = true; }
        all.Add(ground);
    }

    void AddLump(float x, float y, float hh) {
        if (hh < 0.6f || lumps.Count > 3000 || bare) return;
        lumps.Add(new Lump { x = x, y = y - hh / 2, r = Math.Max(1.2f * s, (float)Math.Sqrt(hh * col / 3.14f)), vx = (Rand() - 0.5f) * 30 * s });
    }

    void Spawn(ref Flake f, bool anywhere) {
        f.k = Rand(); f.k *= f.k;                       // beaucoup de petits flocons lointains, peu de gros
        f.r = (0.8f + 2.4f * f.k) * s;
        f.vy = (38 + 95 * f.k) * s;
        f.x = Rand() * W;
        f.y = anywhere ? Rand() * H : -f.r - Rand() * 30 * s;
        f.phase = Rand() * 6.28f; f.w = 0.5f + Rand() * 1.2f;
    }

    void StepFlakes(float dt) {
        int target = Math.Min(2500, (int)((80 + App.cadence * 820) * W * (float)H / (1920f * 1080f)));
        if (target != flakes.Length) {
            int had = flakes.Length;
            for (int i = target; i < had; i++) back.Clear(flakes[i].lx, flakes[i].ly, flakes[i].lx + flakes[i].ls, flakes[i].ly + flakes[i].ls);
            Array.Resize(ref flakes, target);
            for (int i = had; i < target; i++) { Spawn(ref flakes[i], true); flakes[i].y -= H; }   // les nouveaux arrivent par le haut
        }
        float wind = (18 * (float)Math.Sin(t * 0.13f) + 8 * (float)Math.Sin(t * 0.37f + 1)) * s;
        for (int i = 0; i < flakes.Length; i++) back.Clear(flakes[i].lx, flakes[i].ly, flakes[i].lx + flakes[i].ls, flakes[i].ly + flakes[i].ls);
        for (int i = 0; i < flakes.Length; i++) {
            float prev = flakes[i].y;
            flakes[i].y += flakes[i].vy * dt;
            flakes[i].x += (wind * (0.4f + flakes[i].k) + (float)Math.Sin(t * flakes[i].w + flakes[i].phase) * 12 * s * (0.3f + flakes[i].k)) * dt;
            if (flakes[i].x < -5) flakes[i].x += W + 10; else if (flakes[i].x > W + 5) flakes[i].x -= W + 10;
            float x = flakes[i].x, y = flakes[i].y;
            bool landed = false;
            if (!bare && y > 0) foreach (var L in all) {
                if (y < L.y - L.maxH - 1 || prev > L.y || x < L.left || x >= L.right) continue;
                float top = L.y - L.Height(x);
                if (prev <= top && y >= top && L.Covers(x) && L.Deposit(x, 0.55f * flakes[i].r)) { landed = true; frontDirty = true; break; }
            }
            if (landed || y > H + 4) Spawn(ref flakes[i], false);
            float r = flakes[i].r;
            back.Disc(flakes[i].x, flakes[i].y, r, (0.35f + 0.65f * flakes[i].k) * fade);
            flakes[i].lx = (int)(flakes[i].x - r - 1); flakes[i].ly = (int)(flakes[i].y - r - 1); flakes[i].ls = (int)(2 * r + 4);
        }
    }

    void StepLumps(float dt) {
        if (lumps.Count == 0) return;
        frontDirty = true;
        for (int i = lumps.Count - 1; i >= 0; i--) {
            var l = lumps[i];
            l.vy += 1400 * s * dt; l.y += l.vy * dt; l.x += l.vx * dt;
            bool onGround = ground.Covers(l.x);
            float floor = onGround ? ground.y - ground.Height(l.x) : H + 20 * s;
            if (l.y >= floor) {
                if (onGround) ground.Deposit(l.x, l.r * l.r * 3.14f / col * 0.5f);
                lumps.RemoveAt(i);
            } else lumps[i] = l;
        }
    }

    void DrawFront() {
        var before = front.ClearTouched();
        foreach (var L in all) {
            foreach (var seg in L.visible) {
                int x0 = Math.Max(0, (int)Math.Ceiling(seg.a)), x1 = Math.Min(W, (int)seg.b);
                int yb = Math.Min(H, (int)L.y);
                for (int x = x0; x < x1; x++) {
                    float hh = L.Height(x + 0.5f);
                    if (hh < 0.3f) continue;
                    float topY = L.y - hh;
                    int yi = (int)Math.Floor(topY);
                    if (yi >= 0 && yi < yb) {   // rangée du haut : à moitié couverte, pour un contour doux
                        uint a = (uint)((1 - (topY - yi)) * 255);
                        uint* p = front.px + (long)yi * W + x;
                        if (*p >> 24 < a) *p = a * 0x01010101u;
                    }
                    for (int y = Math.Max(0, yi + 1); y < yb; y++) front.px[(long)y * W + x] = 0xFFFFFFFFu;
                }
                front.Touch(x0, (int)(L.y - L.maxH - 2), x1, yb);
            }
        }
        foreach (var l in lumps) {
            front.Disc(l.x, l.y, l.r, 1);
            front.Touch((int)(l.x - l.r - 2), (int)(l.y - l.r - 2), (int)(l.x + l.r + 3), (int)(l.y + l.r + 3));
        }
        front.Present(false, before);
    }
}

// MARK: L'application : icône près de l'horloge, réglages, démarrage

static class App {
    public const string Version = "1.0";
    public static volatile bool enabled = true, locked, quit;
    public static volatile float cadence = 0.6f;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static RegistryKey prefs;
    static NotifyIcon tray;
    static Scene scene;

    [STAThread]
    static int Main(string[] args) {
        if (Array.IndexOf(args, "--selftest") >= 0) return SelfTest();
        int d = Array.IndexOf(args, "--diag");
        if (d >= 0 && d + 1 < args.Length) return Diag(args[d + 1]);
        bool first;
        using (var mutex = new Mutex(true, "Flocon-une-seule-fois", out first)) {
            if (!first) return 0;   // déjà lancée
            Application.EnableVisualStyles();
            prefs = Registry.CurrentUser.CreateSubKey(@"Software\Flocon");
            enabled = (int)prefs.GetValue("mode", 1) != 0;
            cadence = Math.Max(0, Math.Min(100, (int)prefs.GetValue("cadence", 60))) / 100f;
            SystemEvents.SessionSwitch += (o, e) => {   // écran verrouillé : la neige s'évapore, et repart de zéro au retour
                if (e.Reason == SessionSwitchReason.SessionLock) locked = true;
                if (e.Reason == SessionSwitchReason.SessionUnlock) locked = false;
            };
            InstallTray();
            scene = new Scene();
            var thread = new Thread(scene.Run) { IsBackground = true };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            if (Array.IndexOf(args, "--pilote") >= 0) Pilot();
            if ((int)prefs.GetValue("accueilli", 0) == 0) {
                var once = new System.Windows.Forms.Timer { Interval = 400 };
                once.Tick += (o, e) => { once.Stop(); prefs.SetValue("accueilli", 1); Welcome(); };
                once.Start();
            }
            Application.Run();
            quit = true;
            thread.Join(1000);
            tray.Visible = false;
        }
        return 0;
    }

    static void InstallTray() {
        var menu = new ContextMenuStrip();
        var on = new ToolStripMenuItem("Neige activée") { Checked = enabled, CheckOnClick = true };
        on.CheckedChanged += (o, e) => { enabled = on.Checked; prefs.SetValue("mode", enabled ? 1 : 0); };
        var bar = new TrackBar { Minimum = 0, Maximum = 100, Value = (int)(cadence * 100), TickStyle = TickStyle.None, AutoSize = false, Width = 190, Height = 28 };
        bar.ValueChanged += (o, e) => { cadence = bar.Value / 100f; prefs.SetValue("cadence", bar.Value); };
        var start = new ToolStripMenuItem("Ouvrir au démarrage de Windows") { CheckOnClick = true };
        using (var run = Registry.CurrentUser.OpenSubKey(RunKey)) start.Checked = run != null && run.GetValue("Flocon") != null;
        start.CheckedChanged += (o, e) => {
            using (var run = Registry.CurrentUser.CreateSubKey(RunKey)) {
                if (start.Checked) run.SetValue("Flocon", "\"" + Application.ExecutablePath + "\"");
                else run.DeleteValue("Flocon", false);
            }
        };
        menu.Items.Add(on);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripLabel("Cadence de la neige"));
        menu.Items.Add(new ToolStripControlHost(bar));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(start);
        menu.Items.Add("Présentation…", null, (o, e) => Welcome());
        menu.Items.Add("Quitter Flocon", null, (o, e) => Application.Exit());
        menu.Items.Add(new ToolStripLabel("Flocon " + Version) { Enabled = false });
        tray = new NotifyIcon { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath), Text = "Flocon", ContextMenuStrip = menu, Visible = true };
        tray.MouseUp += (o, e) => {   // le clic gauche ouvre le même menu que le clic droit
            if (e.Button != MouseButtons.Left) return;
            var show = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
            if (show != null) show.Invoke(tray, null);
        };
    }

    // shortcut: simple boîte de message ; une vraie fenêtre de présentation comme sur Mac si la version Windows est vendue
    static void Welcome() {
        MessageBox.Show(
            "Il neige sur votre bureau : les flocons tombent derrière vos fenêtres, sans gêner votre travail.\n\n" +
            "La neige se pose sur le dessus des fenêtres et sur la barre des tâches. Rétrécissez, réduisez ou fermez une fenêtre : sa neige tombe.\n\n" +
            "Flocon se met en pause quand l'écran se verrouille, et la neige s'évapore quand vous le désactivez.\n\n" +
            "Flocon n'a pas de fenêtre : il vit dans une icône près de l'horloge, en bas à droite. Si vous ne la voyez pas, cliquez sur la petite flèche ^ à côté de l'horloge. Cliquez sur l'icône pour régler la cadence de la neige, désactiver Flocon ou le quitter.",
            "Bienvenue dans Flocon", MessageBoxButtons.OK, MessageBoxIcon.Information);
        tray.ShowBalloonTip(4000, "Flocon est ici", "Cliquez sur cette icône pour les réglages.", ToolTipIcon.None);
    }

    // Tests automatiques : lancée avec --pilote, l'app obéit aux ordres déposés dans %TEMP%\flocon-ordre.txt (voir windows/tests)
    static void Pilot() {
        string order = Path.Combine(Path.GetTempPath(), "flocon-ordre.txt"), state = Path.Combine(Path.GetTempPath(), "flocon-etat.txt");
        var timer = new System.Windows.Forms.Timer { Interval = 200 };
        timer.Tick += (o, e) => {
            if (!File.Exists(order)) return;
            string what;
            try { what = File.ReadAllText(order).Trim(); File.Delete(order); } catch (IOException) { return; }
            if (what == "off") enabled = false;
            if (what == "on") enabled = true;
            if (what == "verrou") locked = true;
            if (what == "deverrou") locked = false;
            if (what == "etat") File.WriteAllText(state, scene.status);
            if (what == "quitter") Application.Exit();
        };
        timer.Start();
    }

    // Ce que cette machine offre à Flocon. Usage : Flocon.exe --diag fichier.txt
    static int Diag(string path) {
        var sb = new StringBuilder();
        sb.AppendLine(Environment.OSVersion + ", " + (Environment.Is64BitProcess ? "64 bits" : "32 bits") + ", " + RuntimeInformation.ProcessArchitecture);
        float s;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) s = g.DpiX / 96f;
        sb.AppendLine("écran principal : " + Screen.PrimaryScreen.Bounds + ", échelle " + s + ", " + Screen.AllScreens.Length + " écran(s)");
        sb.AppendLine("synchronisation avec l'écran (DwmFlush) : " + (Native.DwmFlush() == 0 ? "disponible" : "indisponible"));
        var wins = Desk.Scan(IntPtr.Zero, IntPtr.Zero, s);
        int ledges = 0;
        foreach (var w in wins) {
            if (w.tray) sb.AppendLine("barre des tâches : " + w.r);
            if (w.ledge) ledges++;
        }
        sb.AppendLine(wins.Count + " fenêtre(s) visibles, dont " + ledges + " où la neige peut se poser");
        File.WriteAllText(path, sb.ToString());
        return 0;
    }

    static int SelfTest() {
        int line = 0;
        Action<bool> check = ok => { line++; if (!ok) throw new Exception("selftest : vérification n° " + line + " fausse"); };
        try {
            var none = new List<Seg>();
            check(Segs.Subtract(0, 100, none).Count == 1);
            var one = Segs.Subtract(0, 100, new List<Seg> { new Seg(40, 60) });
            check(one.Count == 2 && one[0].a == 0 && one[0].b == 40 && one[1].a == 60 && one[1].b == 100);
            check(Segs.Subtract(0, 100, new List<Seg> { new Seg(-10, 30), new Seg(90, 200) }).Count == 1);
            check(Segs.Subtract(0, 100, new List<Seg> { new Seg(0, 100) }).Count == 0);
            check(Segs.Subtract(0, 100, new List<Seg> { new Seg(5, 100) }).Count == 0);   // reste < 8 px : ignoré
            // redimensionnement : la neige reste en place à l'écran, ce qui dépasse tombe
            var l = new Ledge(3, 12);
            l.Resize(0, 30, null);
            check(l.h.Count == 10);
            for (int i = 0; i < 10; i++) l.h[i] = 5;
            int dropped = 0;
            l.Resize(7, 30, (x, hh) => dropped++);    // bord gauche rentré de 7 px : 2 colonnes tombent
            check(dropped == 2 && l.h.Count == 8 && l.origin == 6);
            l.Resize(7, 21, (x, hh) => dropped++);    // bord droit rentré : 3 colonnes tombent
            check(dropped == 5 && l.h.Count == 5);
            l.Resize(2, 21, (x, hh) => dropped++);    // bord gauche ressorti : place vide à gauche, la neige ne bouge pas
            check(dropped == 5 && l.h.Count == 6 && l.h[0] == 0 && l.h[1] == 5 && l.origin == 3);
            l.Shift(10);
            check(l.origin == 13 && l.left == 12 && l.Height(20) > 0);
            check(l.Deposit(14, 2) && l.h[0] == 2);
            check(!l.Deposit(0, 2));                  // hors du bord
        } catch (Exception e) {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "flocon-selftest.txt"), e.Message);
            return 1;
        }
        return 0;
    }
}
