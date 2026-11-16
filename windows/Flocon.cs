// Flocon pour Windows : il neige sur le bureau, la neige se pose sur les fenêtres et sur la barre des tâches.
// On la balaie avec le curseur, on en fait des boules et un bonhomme, un chasse-neige dégage le sol.
// Un seul fichier. Deux calques transparents plein écran :
//   - « fond », tout en bas de la pile des fenêtres, que les clics traversent : les flocons tombent derrière les fenêtres ;
//   - « avant », toujours au-dessus : la neige posée, celle qui vole, les boules, le bonhomme et le chasse-neige.
//     Les clics le traversent aussi, sauf dans la neige et sur une boule.
// L'icône près de l'horloge porte les réglages. Compiler : dotnet build -c Release (voir LISEZ-MOI à la racine).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
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
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int index, int value);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern IntPtr SetCapture(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
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
    public float moved;                              // déplacement cumulé de la fenêtre : repère des objets posés dessus
    public float vx, vy, agit, peak, lastPeak, sdx, sdy;   // vitesse de la fenêtre et mesure de ses secousses (voir Scene.Shake)
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
    public void Shift(float dx) { origin += dx; left += dx; right += dx; moved += dx; }
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
    public int Index(float x) { return Math.Max(0, Math.Min(h.Count - 1, (int)Math.Floor((x - origin) / col))); }

    static readonly float[] spread = { 0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f };
    /// De la neige retombe en x (quantité en surface), étalée sur cinq colonnes.
    public void Add(float x, float area) {
        int c = (int)Math.Floor((x - origin) / col);
        for (int o = -2; o <= 2; o++) {
            int i = c + o;
            if (i >= 0 && i < h.Count) h[i] = Math.Min(maxH, h[i] + area / col * spread[o + 2]);
        }
    }
    /// Le tas s'affaisse là où sa pente dépasse « limit » (creusé par le curseur, chargé par une retombée). Vrai s'il a bougé.
    public bool Relax(float limit) {
        int n = h.Count;
        bool moved = false;
        for (int pass = 0; pass < 4 && n > 3; pass++) {
            bool shifted = false;
            for (int j = 0; j < n - 1; j++) {
                int i = pass % 2 == 0 ? j : n - 2 - j;
                float diff = h[i] - h[i + 1];
                if (Math.Abs(diff) <= limit + 0.01f) continue;
                float m = (diff > 0 ? diff - limit : diff + limit) * 0.5f;
                h[i] -= m; h[i + 1] += m;
                if (Math.Abs(m) > 0.001f) shifted = true;
            }
            if (!shifted) break;
            moved = true;
        }
        return moved;
    }
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

    public Action<int, int> Down;    // clic gauche dans le calque (position), puis relâchement
    public Action Up;
    public bool Solid;               // le calque capte les clics, là où il n'est pas transparent

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
    /// Capte les clics (dans la neige, sur une boule) ou les laisse tous traverser. Vrai si ça change.
    public bool SetSolid(bool on) {
        if (on == Solid) return false;
        Solid = on;
        Native.SetWindowLong(Handle, -20, 0x80000 | 0x80 | 0x08000000 | (top ? 8 : 0) | (on ? 0 : 0x20));
        return true;
    }
    /// Voile invisible (opacité 1/255) autour du curseur : Windows laisse passer les clics là où le calque est
    /// tout à fait transparent, or le curseur vient souvent de creuser la neige sous sa pointe.
    public void Veil(int cx, int cy, int r) {
        for (int y = Math.Max(0, cy - r); y < Math.Min(H, cy + r + 1); y++) {
            uint* p = px + (long)y * W + Math.Max(0, cx - r);
            for (int x = Math.Max(0, cx - r); x < Math.Min(W, cx + r + 1); x++, p++) if (*p == 0) *p = 0x01000000u;
        }
        Touch(cx - r, cy - r, cx + r + 1, cy + r + 1);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x21) { m.Result = (IntPtr)3; return; }   // un clic dans la neige ne prend jamais la main à l'app en cours
        if (m.Msg == 0x201 || m.Msg == 0x203) {                // bouton gauche enfoncé (ou second clic d'un double-clic)
            long l = m.LParam.ToInt64();
            Native.SetCapture(Handle);                         // la suite du geste nous revient, même hors de la neige
            if (Down != null) Down((short)(l & 0xFFFF), (short)((l >> 16) & 0xFFFF));
            return;
        }
        if (m.Msg == 0x202) { Native.ReleaseCapture(); if (Up != null) Up(); return; }
        if (m.Msg == 0x215 && Up != null) Up();                // geste interrompu par Windows
        base.WndProc(ref m);
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
    /// Colonne de neige d'un pixel de large, de topY jusqu'à yb ; la rangée du haut est à moitié couverte, pour un contour doux.
    public void Column(int x, float topY, int yb) {
        int yi = (int)Math.Floor(topY);
        if (yi >= 0 && yi < yb) {
            uint a = (uint)((1 - (topY - yi)) * 255);
            uint* p = px + (long)yi * W + x;
            if (*p >> 24 < a) *p = a * 0x01010101u;
        }
        for (int y = Math.Max(0, yi + 1); y < yb; y++) px[(long)y * W + x] = 0xFFFFFFFFu;
    }
    /// Recopie une image en couleurs (opacité prémultipliée) par-dessus ce qui est déjà dessiné.
    public void Sprite(uint[] src, int sw, int sh, int x0, int y0) {
        for (int sy = Math.Max(0, -y0); sy < sh && y0 + sy < H; sy++) {
            uint* p = px + (long)(y0 + sy) * W + Math.Max(0, x0);
            for (int sx = Math.Max(0, -x0); sx < sw && x0 + sx < W; sx++, p++) {
                uint c = src[sy * sw + sx], k = 255 - (c >> 24), d = *p;
                if (k == 255) continue;
                *p = k == 0 ? c : c + (((d >> 24) * k / 255) << 24 | ((d >> 16 & 255) * k / 255) << 16 | ((d >> 8 & 255) * k / 255) << 8 | (d & 255) * k / 255);
            }
        }
    }
    /// Boule de neige : blanche en haut à gauche, bleutée vers le bord, cernée d'un trait fin.
    public void Ball(float cx, float cy, float r, float s) {
        int x0 = Math.Max(0, (int)(cx - r - 1)), x1 = Math.Min(W, (int)(cx + r + 2));
        int y0 = Math.Max(0, (int)(cy - r - 1)), y1 = Math.Min(H, (int)(cy + r + 2));
        float hx = cx - 0.35f * r, hy = cy - 0.45f * r;
        for (int y = y0; y < y1; y++) {
            uint* p = px + (long)y * W + x0;
            for (int x = x0; x < x1; x++, p++) {
                float dx = x + 0.5f - cx, dy = y + 0.5f - cy, d = (float)Math.Sqrt(dx * dx + dy * dy);
                float c = r + 0.5f - d;
                if (c <= 0) continue;
                if (c > 1) c = 1;
                float g = Math.Min(1, (float)Math.Sqrt((x + 0.5f - hx) * (x + 0.5f - hx) + (y + 0.5f - hy) * (y + 0.5f - hy)) / (1.5f * r));
                float R = 255 - 56 * g, G = 255 - 38 * g, B = 255 - 13 * g;
                float rim = Math.Min(1, d - (r - 1.2f * s)) * 0.5f;
                if (rim > 0) { R += (158 - R) * rim; G += (184 - G) * rim; B += (224 - B) * rim; }
                uint k = (uint)(255 - c * 255), under = *p;
                *p = ((uint)(c * 255) + (under >> 24) * k / 255) << 24 | ((uint)(R * c) + (under >> 16 & 255) * k / 255) << 16
                    | ((uint)(G * c) + (under >> 8 & 255) * k / 255) << 8 | ((uint)(B * c) + (under & 255) * k / 255);
            }
        }
    }
    /// Disque blanc, centré au pixel près ou entre deux pixels. « soft » : fondu du centre vers le bord, pour la poudreuse.
    public void Disc(float cx, float cy, float r, float alpha, bool soft) {
        int x0 = Math.Max(0, (int)(cx - r - 1)), x1 = Math.Min(W, (int)(cx + r + 2));
        int y0 = Math.Max(0, (int)(cy - r - 1)), y1 = Math.Min(H, (int)(cy + r + 2));
        for (int y = y0; y < y1; y++) {
            float dy = y + 0.5f - cy;
            uint* p = px + (long)y * W + x0;
            for (int x = x0; x < x1; x++, p++) {
                float dx = x + 0.5f - cx;
                float d = (float)Math.Sqrt(dx * dx + dy * dy), c = soft ? 1 - d / r : r + 0.5f - d;
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

// MARK: Dessins en couleurs (bonhomme, chasse-neige) : préparés une fois, puis recopiés dans le calque

static unsafe class Art {
    /// Dessine avec les coordonnées de la version Mac (y vers le haut), agrandies k fois. Rend les pixels, opacité prémultipliée.
    static uint[] Render(int w, int h, float k, Action<Graphics> draw) {
        var px = new uint[w * h];
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb)) {
            using (var g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TranslateTransform(0, h); g.ScaleTransform(k, -k);
                draw(g);
            }
            var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
            fixed (uint* p = px) Buffer.MemoryCopy((void*)d.Scan0, p, (long)w * h * 4, (long)w * h * 4);
            bmp.UnlockBits(d);
        }
        return px;
    }
    static void Fill(Graphics g, Color c, GraphicsPath p) { using (var b = new SolidBrush(c)) g.FillPath(b, p); p.Dispose(); }
    static GraphicsPath Round(float x, float y, float w, float h, float r) {
        var p = new GraphicsPath(); float d = 2 * r;
        p.AddArc(x, y, d, d, 180, 90); p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90); p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    static GraphicsPath Oval(float cx, float cy, float r) { var p = new GraphicsPath(); p.AddEllipse(cx - r, cy - r, 2 * r, 2 * r); return p; }
    static GraphicsPath Box(float x, float y, float w, float h) { var p = new GraphicsPath(); p.AddRectangle(new RectangleF(x, y, w, h)); return p; }
    static void Ball(Graphics g, float cx, float cy, float r) {
        var edge = Color.FromArgb(199, 217, 242);
        Fill(g, edge, Oval(cx, cy, r));
        using (var p = Oval(cx, cy, r)) using (var b = new PathGradientBrush(p)) using (var pen = new Pen(Color.FromArgb(178, 158, 184, 224), 0.6f)) {
            b.CenterPoint = new PointF(cx - 0.35f * r, cy + 0.45f * r); b.CenterColor = Color.White; b.SurroundColors = new[] { edge };
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }
    }

    public static uint[] Man(int w, int h) {
        return Render(w, h, w / 44f, g => {
            using (var pen = new Pen(Color.FromArgb(92, 56, 31), 1.6f)) { g.DrawLine(pen, 12f, 37f, 2f, 47f); g.DrawLine(pen, 32f, 37f, 42f, 47f); }
            Ball(g, 22, 15, 14); Ball(g, 22, 36, 11.5f); Ball(g, 22, 54, 9.5f);
            var red = Color.FromArgb(217, 31, 38);   // écharpe
            Fill(g, red, Round(13, 43.5f, 18, 4.5f, 2)); Fill(g, red, Round(25, 34, 4.5f, 11, 2));
            Fill(g, Color.Black, Oval(18.5f, 57, 1.3f)); Fill(g, Color.Black, Oval(25.5f, 57, 1.3f));
            Fill(g, Color.Black, Oval(22, 38, 1.2f)); Fill(g, Color.Black, Oval(22, 31, 1.2f)); Fill(g, Color.Black, Oval(22, 18, 1.2f));
            var nose = new GraphicsPath();   // carotte
            nose.AddPolygon(new[] { new PointF(21, 55), new PointF(31, 52.5f), new PointF(21, 51.5f) });
            Fill(g, Color.FromArgb(255, 128, 26), nose);
        });
    }

    /// Chasse-neige de 68 × 46, tourné vers la gauche, lame en x = 2…13.
    public static uint[] Plough(int w, int h, float k) {
        return Render(w, h, k, g => {
            Color yellow = Color.FromArgb(250, 194, 31), dark = Color.FromArgb(46, 48, 56);
            Fill(g, dark, Box(10, 13, 12, 4));                 // bras
            Fill(g, dark, Round(18, 0, 48, 13, 6.5f));         // chenille
            for (int i = 0; i < 4; i++) { Fill(g, Color.FromArgb(184, 189, 199), Oval(25.5f + i * 11, 6.5f, 3.6f)); Fill(g, dark, Oval(25.5f + i * 11, 6.5f, 1.3f)); }
            Fill(g, yellow, Round(18, 11, 46, 17, 4));         // caisse
            Fill(g, yellow, Round(32, 24, 26, 18, 4));         // cabine
            Fill(g, Color.FromArgb(140, 204, 255), Round(35.5f, 28, 19, 10.5f, 2));
            Fill(g, Color.FromArgb(255, 115, 26), Oval(45, 43.5f, 2.2f));   // gyrophare
            var blade = new GraphicsPath();
            blade.AddBezier(2f, 0f, 9f, 9f, 10f, 22f, 9f, 31f); blade.AddLine(9f, 31f, 13f, 31f); blade.AddLine(13f, 31f, 13f, 0f); blade.CloseFigure();
            Fill(g, Color.FromArgb(219, 224, 235), blade);
            Fill(g, Color.FromArgb(217, 38, 38), Box(11.5f, 0, 1.5f, 31));
        });
    }
}

// MARK: La scène (tourne sur son propre fil, au rythme de l'écran)

struct Flake { public float x, y, r, vy, k, phase, w; public int lx, ly, ls; }
/// Neige en vol : poudre détachée d'un tas, ou motte compacte qui éclate en poudreuse à l'atterrissage.
struct Grain { public float x, y, vx, vy, area, r; public bool lump; }
/// Voile de poudreuse soulevé par un choc ; il flotte un instant puis s'efface.
struct Mote { public float x, y, vx, vy, age, life, alpha, r; }
struct Trail { public double t; public float x, y; }

/// Boule de neige ou bonhomme. « r » est le rayon de la boule (ou de la boule du bas du bonhomme) ; (x, y) son centre.
sealed class Item {
    public bool man, thrown;       // thrown : lâchée avec de l'élan, et pas encore retombée
    public float r, x, y, vx, vy, dx;
    public int rest;               // 0 = en l'air, 1 = posée sur un bord (à dx de son repère), 2 = posée sur une autre boule
    public Ledge on;
    public Item under;
    public uint[] px; public int pw, ph;   // image du bonhomme
    public float HalfH { get { return man ? r * 2.5f : r; } }
    public float HalfW { get { return man ? r * 1.57f : r; } }
    public bool Hit(float px, float py, float m) { return Math.Abs(px - x) <= HalfW + m && Math.Abs(py - y) <= HalfH + m; }
}

sealed unsafe class Scene {
    Layer back, front;
    Rectangle bounds;
    int W, H, frame, stamp;
    double t;
    float s = 1, col = 3, fade, evap, fps = 60, wind;
    int state = 2;                 // 0 = il neige, 1 = la neige s'évapore, 2 = tout est caché
    bool bare;                     // pendant l'évaporation, plus rien ne se pose
    bool frontDirty;
    Flake[] flakes = new Flake[0];
    readonly List<Grain> grains = new List<Grain>();
    readonly List<Mote> motes = new List<Mote>();
    readonly List<Item> items = new List<Item>();
    readonly Dictionary<IntPtr, Ledge> ledges = new Dictionary<IntPtr, Ledge>();
    readonly List<Ledge> all = new List<Ledge>();   // les bords de fenêtres, puis le sol
    readonly List<IntPtr> gone = new List<IntPtr>();
    Ledge ground;
    Item dragging;                 // boule ou bonhomme tenu par la souris
    readonly List<Trail> trail = new List<Trail>();   // positions récentes de l'objet tenu : elles donnent l'élan du lancer
    float lastDragX, curX, curY, carved;
    int veilX, veilY;
    bool hasCursor, upSeen;
    bool plough; float ploughX, collected, pile;
    uint[] ploughPx; int ploughW, ploughH;
    readonly Random rnd = new Random();
    public volatile string status = "etat=2";

    float Rand() { return (float)rnd.NextDouble(); }
    static float Hyp(float a, float b) { return (float)Math.Sqrt(a * a + b * b); }
    float G { get { return 2500 * s; } }   // pesanteur

    public void Run() {
        back = new Layer(false); front = new Layer(true);
        front.Down = Press; front.Up = () => upSeen = true;
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
        state = 0; bare = false; fade = 0; hasCursor = false;
    }
    void Fit(Rectangle b) {
        bounds = b; W = b.Width; H = b.Height;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) s = g.DpiX / 96f;
        col = 3 * s;
        back.Fit(b); front.Fit(b);
        flakes = new Flake[0]; ledges.Clear(); Empty();
        ground = new Ledge(col, 24 * s);
        ground.Resize(0, W, null);
        ground.y = H;
        ploughW = (int)Math.Ceiling(68 * s); ploughH = (int)Math.Ceiling(46 * s);
        ploughPx = Art.Plough(ploughW, ploughH, s);
    }
    /// Retire tout ce qui bouge au premier plan : neige en vol, boules, bonhomme, chasse-neige.
    void Empty() {
        grains.Clear(); motes.Clear(); items.Clear(); trail.Clear();
        dragging = null; plough = false; App.ploughAsked = false;
        front.SetSolid(false);
    }
    void Hide() {
        ledges.Clear(); Empty(); ground.Shed(null); ground.Resize(0, W, null);
        back.Clear(0, 0, W, H); front.Clear(0, 0, W, H);
        back.Present(true, new RECT()); front.Present(true, new RECT());
        flakes = new Flake[0];
        back.SetShown(false); front.SetShown(false);
        state = 2;
    }

    void Step(float dt) {
        t += dt; frame++;
        if (frame % 60 == 0 && Screen.PrimaryScreen.Bounds != bounds) Fit(Screen.PrimaryScreen.Bounds);
        Track(dt);
        fade = state == 1 ? Math.Max(0, evap / 0.6f) : Math.Min(1, fade + dt * 1.5f);
        wind = (18 * (float)Math.Sin(t * 0.13) + 8 * (float)Math.Sin(t * 0.37 + 1)) * s;
        if (state == 1) {
            float k = (float)Math.Exp(-9 * dt);
            foreach (var L in all) for (int i = 0; i < L.h.Count; i++) L.h[i] *= k;
            Empty(); frontDirty = true;
        } else {
            if (App.fillAsked) {   // tests automatiques : une bonne couche de neige partout, tout de suite
                App.fillAsked = false; frontDirty = true;
                foreach (var L in all) for (int i = 0; i < L.h.Count; i++) L.h[i] = Math.Max(L.h[i], Math.Min(L.maxH, 8 * s));
            }
            Mouse(dt);
            foreach (var L in all) if (L.Relax(0.8f * col * (L.agit > 4 ? 0.35f : 1))) frontDirty = true;   // secoué, un tas s'étale
            StepItems(dt);
            StepPlough(dt);
        }
        StepFlakes(dt);
        StepGrains(dt);
        StepMotes(dt);
        back.Present(true, new RECT());   // shortcut: tout l'écran renvoyé à chaque image ; par zones si les écrans 4K peinent
        if (frontDirty) { DrawFront(); frontDirty = false; }
        fps += (1 / Math.Max(dt, 0.001f) - fps) * 0.05f;
        {
            float win = 0; int men = 0;
            foreach (var L in ledges.Values) win += L.Total();
            foreach (var it in items) if (it.man) men++;
            status = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "etat={0} flocons={1} rebords={2} neige_sol={3:0} neige_fenetres={4:0} fond_ok={5} ecran={6}x{7} echelle={8:0.00} images_par_s={9:0}"
                + " sol={10:0} boules={11} bonhommes={12} en_vol={13} chasse={14} creuse={15:0} clics={16}",
                state, flakes.Length, ledges.Count, ground.Total(), win, Desk.backOk ? 1 : 0, W, H, s, fps,
                ground.y, items.Count - men, men, grains.Count, plough ? 1 : 0, carved, front.Solid ? 1 : 0);
        }
    }

    // Suit les fenêtres : où sont leurs bords du haut, quelles parties en sont visibles, lesquelles ont disparu.
    void Track(float dt) {
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
            float rvx = 0, rvy = 0;   // vitesse de la fenêtre, quand on la déplace
            if (!ledges.TryGetValue(w.h, out L)) {
                L = new Ledge(col, 14 * s);
                L.Resize(w.r.Left + inset, w.r.Right - inset, null);
                ledges[w.h] = L; frontDirty = true;
            } else if (L.rect != w.r) {
                if (L.rect.Width == w.r.Width) {   // déplacée : la neige suit
                    L.Shift(w.r.Left - L.rect.Left);
                    if (dt > 0.001f) { rvx = (w.r.Left - L.rect.Left) / dt; rvy = (w.r.Top - L.rect.Top) / dt; }
                } else { float y = L.y; L.Resize(w.r.Left + inset, w.r.Right - inset, (x, hh) => AddLump(x, y, hh)); }
                frontDirty = true;
            }
            L.rect = w.r; L.y = w.r.Top; L.stamp = stamp;
            Shake(L, rvx, rvy, dt);
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

    /// Fenêtre secouée : l'agitation mesure un va-et-vient (deux à-coups de sens opposés, pas un simple départ ou arrêt),
    /// en multiples de la pesanteur. Au-delà de 4, la neige est projetée en l'air.
    void Shake(Ledge L, float rvx, float rvy, float dt) {
        if (dt <= 0.001f) return;
        float k = Math.Min(1, dt / 0.06f), ovx = L.vx, ovy = L.vy;
        L.vx += (rvx - L.vx) * k; L.vy += (rvy - L.vy) * k;
        float ax = (L.vx - ovx) / dt, ay = (L.vy - ovy) / dt, mag = Hyp(ax, ay);
        L.agit *= (float)Math.Exp(-dt / 0.3f);
        float calm = (float)Math.Exp(-dt / 0.5f);   // deux à-coups éloignés dans le temps ne font pas une secousse
        L.peak *= calm; L.lastPeak *= calm;
        if (mag > 1 && ax * L.sdx + ay * L.sdy < 0) {
            L.agit = Math.Max(L.agit, Math.Min(L.lastPeak, L.peak) / G);
            L.lastPeak = L.peak; L.peak = mag; L.sdx = ax / mag; L.sdy = ay / mag;
        } else {
            L.peak = Math.Max(L.peak, mag);
            if (mag > 1 && L.sdx == 0 && L.sdy == 0) { L.sdx = ax / mag; L.sdy = ay / mag; }
        }
        if (L.agit <= 4 || bare) return;
        int n = L.h.Count, picks = (int)(n * Math.Min(0.8f, 0.06f * (L.agit - 4)) * dt * 2 + Rand());
        for (int p = 0; p < picks && n > 0; p++) {
            int i = rnd.Next(n);
            float h = L.h[i], x = L.origin + (i + 0.5f) * col;
            if (h <= 0.2f * s || !L.Covers(x)) continue;
            L.h[i] = h / 2;
            Release(h / 2 * col, x, L.y - h / 2, L.vx + (Rand() * 160 - 80) * s, L.vy - (50 + Rand() * 150) * s, col / 2, h / 2, 0.25f);
            frontDirty = true;
        }
    }

    // MARK: Flocons

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
            back.Disc(flakes[i].x, flakes[i].y, r, (0.35f + 0.65f * flakes[i].k) * fade, false);
            flakes[i].lx = (int)(flakes[i].x - r - 1); flakes[i].ly = (int)(flakes[i].y - r - 1); flakes[i].ls = (int)(2 * r + 4);
        }
    }

    // MARK: Neige en vol

    void AddGrain(float x, float y, float vx, float vy, float area, float r, bool lump) {
        if (bare) return;
        grains.Add(new Grain { x = x, y = y, vx = vx, vy = vy, area = area, r = r, lump = lump });
    }

    /// La neige d'une colonne qui n'a plus de support (fenêtre rétrécie, fermée, réduite) tombe en paquet.
    void AddLump(float x, float y, float hh) {
        if (hh < 0.6f || grains.Count > 3000) return;
        AddGrain(x, y - hh / 2, (Rand() - 0.5f) * 30 * s, -Rand() * 90 * s,   // petit élan inégal : les paquets ne tombent pas en ligne droite
            hh * col, Math.Max(1.2f * s, (float)Math.Sqrt(hh * col / 3.14f)), false);
    }

    /// Lâche de la neige en poudre. « scatter » fait varier la vitesse de chaque grain, pour qu'une plaque projetée se disloque.
    void Release(float area, float x, float y, float vx, float vy, float sw, float sh, float scatter) {
        if (area <= 0.02f * s * s || bare) return;
        if (grains.Count >= 1500) { ground.Add(x, area); frontDirty = true; return; }
        int count = Math.Max(1, Math.Min(6, (int)(area / (3 * s * s))));
        float share = area / count;
        for (int i = 0; i < count; i++) {
            float f = 1 + (Rand() * 2 - 1) * scatter;
            AddGrain(x + (Rand() * 2 - 1) * sw, y - Rand() * sh,
                vx * f + (Rand() * 24 - 12) * s + 40 * s * scatter * (Rand() * 2 - 1), vy * f + (Rand() * 18 - 8) * s,
                share, Math.Min(5 * s, Math.Max(1.6f * s, (float)Math.Sqrt(share) * 1.05f)) / 2, false);
        }
    }

    /// Une motte tient ensemble en vol, et éclate en poudreuse là où elle retombe.
    void ThrowLump(float area, float x, float y, float vx, float vy) {
        int pieces = (int)(area / (90 * s * s)) + 1;
        for (int i = 0; i < pieces && grains.Count < 1500; i++) {
            float share = area / pieces, f = 0.8f + Rand() * 0.4f;
            AddGrain(x + (Rand() * 4 - 2) * s, y + (Rand() * 2 - 1) * s, vx * f + (Rand() * 50 - 25) * s, vy * f + Rand() * 80 * s,
                share, Math.Min(11 * s, Math.Max(3 * s, (float)Math.Sqrt(share) * 1.05f)) / 2, true);
        }
    }

    /// Nuage de poudreuse qui s'élève d'un point d'impact.
    void Puff(float x, float y, float size, float force, float drift) {
        int n = Math.Max(0, Math.Min(300 - motes.Count, (int)(2 + size / s * 0.6f * force)));
        for (int i = 0; i < n; i++) {
            float angle = 0.15f + Rand() * 2.84f, speed = (25 + Rand() * 85) * force * s;
            motes.Add(new Mote { x = x + (Rand() - 0.5f) * size, y = y - Rand() * size * 0.4f,
                vx = (float)Math.Cos(angle) * speed * 1.4f + drift * 0.2f, vy = -(float)Math.Sin(angle) * speed * 0.6f,
                life = 0.45f + Rand() * 0.45f, alpha = 0.25f + Rand() * 0.25f, r = ((0.3f + Rand() * 0.3f) * size + s) * 1.1f });
        }
        frontDirty = true;
    }

    /// Le bord enneigé le plus haut traversé en tombant de « from » à « to », à la position x.
    Ledge Landing(float x, float from, float to) {
        Ledge hit = null; float best = float.MaxValue;
        foreach (var L in all) {
            if (from > L.y || !L.Covers(x)) continue;
            float top = L.y - L.Height(x);
            if (to >= top && top < best) { best = top; hit = L; }
        }
        return hit;
    }

    void StepGrains(float dt) {
        if (grains.Count == 0) return;
        frontDirty = true;
        float damping = (float)Math.Exp(-0.8 * dt);
        for (int i = grains.Count - 1; i >= 0; i--) {
            var g = grains[i];
            g.vy += G * dt; g.vx *= damping; g.vy *= damping;
            float ny = g.y + g.vy * dt;
            g.x += g.vx * dt;
            bool done = g.x < -10 || g.x > W + 10 || ny > H + 10;
            Ledge L = !done && g.vy >= 0 ? Landing(g.x, g.y, ny) : null;
            g.y = ny;
            if (L != null) {
                done = true;
                if (!g.lump) L.Add(g.x, g.area);   // la neige rejoint le tas
                else {   // l'essentiel se tasse, quelques miettes rebondissent, un voile de poudreuse s'élève
                    float size = 2 * g.r, crumbs = g.area * 0.18f, top = L.y - L.Height(g.x);
                    for (int k = -1; k <= 1; k++) L.Add(g.x + k * 0.3f * size, (g.area - crumbs) / 3);
                    Release(crumbs, g.x, top - s, g.vx * 0.3f, -g.vy * (0.08f + Rand() * 0.08f), size * 0.4f, s, 0.6f);
                    Puff(g.x, top, size, Math.Min(1.3f, Math.Max(0.35f, g.vy / (900 * s))), g.vx);
                }
            }
            if (done) { grains[i] = grains[grains.Count - 1]; grains.RemoveAt(grains.Count - 1); }   // retrait par échange avec le dernier
            else grains[i] = g;
        }
    }

    void StepMotes(float dt) {
        if (motes.Count == 0) return;
        frontDirty = true;
        float damping = (float)Math.Exp(-3.2 * dt);
        for (int i = motes.Count - 1; i >= 0; i--) {
            var m = motes[i];
            m.age += dt;
            if (m.age >= m.life) { motes[i] = motes[motes.Count - 1]; motes.RemoveAt(motes.Count - 1); continue; }
            m.vy += 35 * s * dt; m.vx *= damping; m.vy *= damping;
            m.x += (m.vx + wind * 0.4f) * dt; m.y += m.vy * dt;
            motes[i] = m;
        }
    }

    // MARK: Boules et bonhomme

    /// Un objet tient sur un bord si celui-ci le porte des deux côtés de son centre. Au ras du bord, il bascule dans le vide.
    bool Supports(Ledge L, float x, Item it) {
        float m = Math.Max(it.r * 0.5f, 3 * s);
        return L.Covers(x - m) && L.Covers(x + m);
    }

    void Remove(Item it) {
        items.Remove(it);
        if (dragging == it) dragging = null;
        frontDirty = true;
    }

    /// La boule s'écrase : sa neige part en poudre et en mottes, puis retombe en tas.
    void Splat(Item it, float vx) {
        Remove(it);
        float bas = it.y + it.HalfH, area = 3.14f * it.r * it.r * 0.5f * (it.man ? 2.2f : 1);
        int sprays = Math.Max(3, (int)(it.r / (2 * s)));
        for (int i = 0; i < sprays; i++)
            Release(area * 0.6f / sprays, it.x + (Rand() * 2 - 1) * it.HalfW, bas - s - Rand() * it.HalfH,
                vx + (Rand() * 520 - 260) * s, -(120 + Rand() * 400) * s, 2 * s, 2 * s, 0.3f);
        ThrowLump(area * 0.4f, it.x, bas - it.r * 0.6f, vx, -(180 + Rand() * 180) * s);
        Puff(it.x, bas, it.r, 1.2f, vx);
    }

    void StepItems(float dt) {
        if (items.Count == 0) return;
        foreach (var it in items.ToArray()) {
            if (it == dragging || !items.Contains(it)) continue;
            if (it.rest == 1) {
                var L = it.on;
                if (L != ground && L.stamp != stamp) { it.rest = 0; continue; }   // fenêtre fermée, réduite ou agrandie
                if (L.agit > 4) {   // fenêtre secouée : l'objet est éjecté
                    it.rest = 0; it.vx = L.vx * 0.8f; it.vy = Math.Min(L.vy, 0) * 0.8f - 220 * s;
                    continue;
                }
                if (Math.Abs(it.vx) > 10 * s) {   // la boule roule encore un peu avant de s'arrêter
                    it.dx += it.vx * dt; it.vx *= (float)Math.Exp(-2.5 * dt); frontDirty = true;
                } else it.vx = 0;
                float x = Math.Max(it.HalfW, Math.Min(W - it.HalfW, L.moved + it.dx));
                it.dx = x - L.moved;
                if (Supports(L, x, it)) { it.x = x; it.y = L.y - it.HalfH; }
                else {   // bord atteint ou fenêtre recouverte : l'objet bascule du côté du vide et tombe
                    it.rest = 0;
                    if (Math.Abs(it.vx) < 40 * s) it.vx = L.Covers(x - it.r) ? 70 * s : -70 * s;
                }
            } else if (it.rest == 2) {
                var b = it.under;
                if (b != dragging && b.rest != 0 && items.Contains(b)) { it.x = b.x; it.y = b.y - (b.r + it.r) * 0.8f; }
                else it.rest = 0;
            } else Fall(it, dt);
        }
    }

    void Fall(Item it, float dt) {
        frontDirty = true;
        it.vy += G * dt;
        it.vx *= 1 - Math.Min(1, 0.15f * dt);
        float nx = it.x + it.vx * dt;
        if (nx < it.HalfW) { nx = it.HalfW; it.vx = Math.Abs(it.vx) * 0.5f; }               // rebond sur les bords de l'écran
        else if (nx > W - it.HalfW) { nx = W - it.HalfW; it.vx = -Math.Abs(it.vx) * 0.5f; }
        float oldB = it.y + it.HalfH, newB = oldB + it.vy * dt, bestY = float.MaxValue, bestX = nx;
        Ledge onL = null; Item onB = null;
        if (it.vy >= 0) {
            foreach (var L in all)
                if (L.y < bestY && oldB <= L.y + 1 && newB >= L.y && Supports(L, nx, it)) { bestY = L.y; onL = L; }
            if (!it.man) foreach (var b in items) {
                if (b == it || b == dragging || b.man || b.rest == 0 || Math.Abs(b.x - nx) >= (b.r + it.r) * 0.6f) continue;
                float yb = b.y - (b.r + it.r) * 0.8f + it.r;
                if (yb < bestY && oldB <= yb + 1 && newB >= yb) { bestY = yb; bestX = b.x; onB = b; onL = null; }
            }
        }
        if (onL == null && onB == null) {
            it.x = nx; it.y += it.vy * dt;
            if (it.y - it.HalfH > H) Remove(it);   // tombée sous l'écran
            return;
        }
        it.x = nx; it.y = bestY - it.HalfH;
        if (Hyp(it.vx, it.vy) > (it.thrown ? 350 : 900) * s) { Splat(it, it.vx * 0.3f); return; }   // une boule lancée s'écrase au premier choc
        it.thrown = false;
        if (it.vy > 260 * s) {   // choc moyen : rebond amorti et un peu de poudreuse
            Puff(nx, bestY, it.r * 0.5f, 0.5f, 0);
            it.vy = -it.vy * 0.3f; it.vx *= 0.75f;
            return;
        }
        it.vy = 0; it.x = bestX;
        if (onB == null) { it.rest = 1; it.on = onL; it.dx = bestX - onL.moved; if (it.man) it.vx = 0; return; }
        it.rest = 2; it.under = onB; it.vx = 0;
        if (onB.rest != 2) return;
        // trois boules empilées deviennent un bonhomme de neige
        var bas = onB.under;
        var man = new Item { man = true, r = Math.Max(10 * s, Math.Min(22 * s, bas.r)), rest = bas.rest, on = bas.on, dx = bas.dx, under = bas.under, x = bas.x };
        man.y = bas.y + bas.r - man.HalfH;
        man.pw = (int)Math.Ceiling(man.r * 44 / 14); man.ph = (int)Math.Ceiling(man.r * 5);
        man.px = Art.Man(man.pw, man.ph);
        Remove(it); Remove(onB); Remove(bas);
        items.Add(man);
    }

    // MARK: Souris

    /// Le bord (sol ou fenêtre) dont la neige se trouve sous le point ou tout près, s'il y en a assez.
    Ledge SnowAt(float x, float y, float minH) {
        foreach (var L in all) {
            if (L.h.Count == 0 || !L.Covers(x)) continue;
            // le curseur vient de creuser la neige juste sous lui : on regarde celle qui reste tout autour
            float h = 0;
            for (int i = L.Index(x - 30 * s); i <= L.Index(x + 30 * s); i++) if (L.h[i] > h) h = L.h[i];
            if (h >= minH && y <= L.y + 2 * s && y >= L.y - Math.Max(h, 4 * s) - 8 * s) return L;
        }
        return null;
    }

    /// Clic dans le calque du premier plan : on attrape l'objet visé, ou une petite boule naît dans la neige.
    void Press(int x, int y) {
        if (state != 0) return;
        Item found = null;
        for (int i = items.Count - 1; i >= 0 && found == null; i--) if (items[i].Hit(x, y, 3 * s)) found = items[i];
        if (found == null && SnowAt(x, y, 3 * s) != null) found = new Item { r = 6 * s };   // à faire rouler dans la neige pour la grossir
        if (found == null) return;
        items.Remove(found); items.Add(found);   // dessinée par-dessus les autres
        dragging = found; upSeen = false;
        found.rest = 0; found.vx = found.vy = 0; found.thrown = false;
        found.x = x; found.y = Math.Min(y, ground.y - found.HalfH);
        lastDragX = x;
        trail.Clear(); trail.Add(new Trail { t = t, x = found.x, y = found.y });
        frontDirty = true;
    }

    void Mouse(float dt) {
        POINT q;
        if (!Native.GetCursorPos(out q)) return;
        float mx = q.X - bounds.X, my = q.Y - bounds.Y;
        bool pressed = (Native.GetAsyncKeyState(1) & 0x8000) != 0 || (Native.GetAsyncKeyState(2) & 0x8000) != 0;
        var it = dragging;
        if (it != null && (upSeen || !pressed)) Drop();
        else if (it != null) {
            it.x = mx; it.y = Math.Min(my, ground.y - it.HalfH);   // une boule tenue ne passe pas sous le sol
            trail.Add(new Trail { t = t, x = it.x, y = it.y });
            while (trail.Count > 1 && trail[0].t < t - 0.12) trail.RemoveAt(0);
            if (!it.man) {   // glisser une boule dans la neige la fait grossir
                var L = SnowAt(it.x, it.y + it.r, 0);
                if (L != null) Grow(it, Math.Abs(it.x - lastDragX), L);
            }
            lastDragX = it.x;
            frontDirty = true;
        }
        upSeen = false;
        Sweep(mx, my, dt);
        // Le calque ne capte les clics que sur un objet ou dans de la neige, là où une boule peut naître.
        // On ne change rien pendant un glisser-déposer d'une autre app.
        if (dragging == null && pressed) return;
        bool want = dragging != null || SnowAt(mx, my, 3 * s) != null;
        for (int i = 0; i < items.Count && !want; i++) want = items[i].Hit(mx, my, 3 * s);
        if (front.SetSolid(want) || (want && ((int)mx != veilX || (int)my != veilY))) frontDirty = true;
        veilX = (int)mx; veilY = (int)my;
    }

    /// La boule ramasse la neige du bord sur la distance parcourue d, jusqu'à la taille limite.
    void Grow(Item b, float d, Ledge L) {
        float max = 22 * s, h = L.h[L.Index(b.x)], floor = (L == ground ? 1 : 0.3f) * s;   // floor : ce qui reste après son passage
        if (b.r >= max || d <= 0 || h <= floor + 0.2f * s) return;
        float dr = Math.Min(d * 0.035f * Math.Min(1, h / (4 * s)), max - b.r);
        b.r += dr;
        for (int i = L.Index(b.x - b.r); i <= L.Index(b.x + b.r); i++) L.h[i] = Math.Max(Math.Min(L.h[i], floor), L.h[i] - dr * 0.8f);
    }

    /// La souris lâche l'objet. Pas assez roulée pour tenir, une boule fond ; sinon elle part avec l'élan du geste.
    void Drop() {
        var it = dragging;
        dragging = null; frontDirty = true;
        if (!it.man && it.r < 9 * s) { Remove(it); Puff(it.x, it.y, it.r, 0.4f, 0); return; }
        // L'élan vient du chemin parcouru sur le dernier dixième de seconde, divisé par cette durée fixe :
        // un petit à-coup ne couvre presque pas de distance et ne donne donc presque pas de vitesse.
        float vx = (it.x - trail[0].x) / 0.12f * 0.75f, vy = (it.y - trail[0].y) / 0.12f * 0.75f, speed = Hyp(vx, vy);
        if (speed > 1700 * s) { vx *= 1700 * s / speed; vy *= 1700 * s / speed; }
        it.vx = vx; it.vy = vy;
        it.thrown = speed > 200 * s;
    }

    /// Le curseur écarte la neige partout : il creuse son passage, pousse une partie de la neige sur le côté et,
    /// s'il va vite, en projette en l'air.
    void Sweep(float mx, float my, float dt) {
        float cx = mx + 4 * s, cy = my + 8 * s, px = curX, py = curY;   // milieu de la flèche plutôt que sa pointe
        bool had = hasCursor;
        curX = cx; curY = cy; hasCursor = true;
        if (!had || dt <= 0.001f || dragging != null) return;
        float dx = cx - px, dy = cy - py, dist = Hyp(dx, dy);
        if (dist <= 0.3f || dist >= 400 * s) return;
        float vx = dx / dt, vy = dy / dt, speed = Hyp(vx, vy), r = 10 * s;
        if (speed > 3000 * s) { vx *= 3000 * s / speed; vy *= 3000 * s / speed; }
        int steps = (int)(dist / (r * 0.5f)) + 1;
        foreach (var L in all) {
            if (Math.Min(cy, py) - r > L.y || Math.Max(cy, py) + r < L.y - L.maxH - 8 * s || Math.Max(cx, px) + r < L.left || Math.Min(cx, px) - r > L.right) continue;
            for (int k = 1; k <= steps; k++) Carve(L, px + dx * k / steps, py + dy * k / steps, vx, vy, dist / steps, r);
        }
    }

    void Carve(Ledge L, float px, float py, float vx, float vy, float travel, float r) {
        int lo = Math.Max(0, (int)Math.Floor((px - r - L.origin) / col)), hi = Math.Min(L.h.Count - 1, (int)Math.Floor((px + r - L.origin) / col));
        float local = L.y - py, speed = Hyp(vx, vy), left = 0, right = 0;
        float spray = Math.Max(0, Math.Min(1, (speed - 60 * s) / (360 * s)));
        spray = spray * spray * (3 - 2 * spray);
        for (int i = lo; i <= hi; i++) {
            float x = L.origin + (i + 0.5f) * col, off = x - px, reach = r * r - off * off;
            if (reach <= 0 || !L.Covers(x)) continue;
            float half = (float)Math.Sqrt(reach), bottom = Math.Max(0, local - half), top = local + half, h = L.h[i];
            if (top <= bottom || h <= bottom + 0.01f) continue;
            // curseur enfoui sous la neige : il ne déplace que ce qu'il traverse, le reste repose dessus
            float removed = h > top ? (top - bottom) * Math.Min(1, travel / (2 * r)) : h - bottom;
            if (removed <= 0.001f) continue;
            L.h[i] = h - removed; frontDirty = true;
            float area = removed * col;
            carved += area;
            if (spray > 0 && area * spray > 0.6f * s * s && grains.Count < 1500) {   // projeté en l'air dans le sens du geste
                float flung = area * spray, oy = L.y - h - py, len = Hyp(off, oy);
                float ox = len > 0.001f ? off / len : 0;
                oy = len > 0.001f ? oy / len : -1;
                float f = 0.55f + Rand() * 0.7f, o = speed * (0.05f + Rand() * 0.2f);
                AddGrain(x + (Rand() * 2 - 1) * s, L.y - (h - removed) - Rand() * 2 * s,
                    vx * f + ox * o + (Rand() * 60 - 30) * s, vy * f + oy * o - speed * (0.02f + Rand() * 0.18f) - (Rand() * 60 - 20) * s,
                    flung, Math.Min(4.2f * s, Math.Max(1.6f * s, (float)Math.Sqrt(flung) * 1.05f)) / 2, false);
                area -= flung;
            }
            if ((Math.Abs(vx) > 40 * s ? vx : off) < 0) left += area; else right += area;
        }
        Push(L, left, px - r - col * 3, vx); Push(L, right, px + r + col * 3, vx);
    }
    /// La neige écartée forme un bourrelet sur le côté, ou tombe du bord.
    void Push(Ledge L, float area, float x, float vx) {
        if (area <= 0) return;
        if (x > L.left && x < L.right && L.Covers(x)) L.Add(x, area);
        else Release(area, x, L.y, vx * 0.5f, 0, s, s, 0);
    }

    // MARK: Chasse-neige

    void StepPlough(float dt) {
        if (App.ploughAsked) {
            App.ploughAsked = false;
            if (!plough) { plough = true; ploughX = W + 60 * s; collected = 0; pile = 0.01f; }
        }
        if (!plough) return;
        frontDirty = true;
        float oldX = ploughX - ploughW / 2f;   // la lame est à l'avant, c'est-à-dire à gauche
        ploughX -= 130 * s * dt;
        float newX = ploughX - ploughW / 2f;
        if (newX < W && oldX > 0)
            for (int i = ground.Index(newX); i <= ground.Index(oldX); i++)
                if (ground.h[i] > 1.5f * s) { collected += ground.h[i] - 1.5f * s; ground.h[i] = 1.5f * s; }
        foreach (var it in items.ToArray())   // la lame percute ce qui est posé au sol : ça éclate vers l'avant
            if (it != dragging && it.rest == 1 && it.on == ground && it.x >= newX - it.HalfW && it.x <= oldX + 4 * s) { collected += it.r * 5; Splat(it, -260 * s); }
        // Le tas devant la lame grossit en douceur, à la mesure de ce qui a été ramassé :
        // il n'est plein qu'après avoir traversé tout un écran de neige épaisse.
        float target = Math.Max(0.01f, Math.Min(1, (float)Math.Sqrt(collected * col / (W * 10f * s))));
        pile += (target - pile) * Math.Min(1, dt * 4);
        if (ploughX < -140 * s) plough = false;
    }

    // MARK: Dessin du premier plan

    void DrawFront() {
        var before = front.ClearTouched();
        foreach (var L in all) {
            foreach (var seg in L.visible) {
                int x0 = Math.Max(0, (int)Math.Ceiling(seg.a)), x1 = Math.Min(W, (int)seg.b);
                int yb = Math.Min(H, (int)L.y);
                for (int x = x0; x < x1; x++) {
                    float hh = L.Height(x + 0.5f);
                    if (hh >= 0.3f) front.Column(x, L.y - hh, yb);
                }
                front.Touch(x0, (int)(L.y - L.maxH - 2), x1, yb);
            }
        }
        foreach (var g in grains) {
            front.Disc(g.x, g.y, g.r, 1, false);
            front.Touch((int)(g.x - g.r - 2), (int)(g.y - g.r - 2), (int)(g.x + g.r + 3), (int)(g.y + g.r + 3));
        }
        foreach (var m in motes) {
            front.Disc(m.x, m.y, m.r, m.alpha * (1 - m.age / m.life), true);
            front.Touch((int)(m.x - m.r - 2), (int)(m.y - m.r - 2), (int)(m.x + m.r + 3), (int)(m.y + m.r + 3));
        }
        if (plough) {
            int left = (int)(ploughX - ploughW / 2f), yb = Math.Min(H, (int)ground.y);
            float ox = left + 6 * s, unit = s * pile;   // tas de neige poussé devant la lame, de 84 × 40 à pleine taille
            int x0 = Math.Max(0, (int)(ox - 78 * unit)), x1 = Math.Min(W, (int)(ox + 6 * unit));
            for (int x = x0; x < x1; x++) {
                float u = (x + 0.5f - ox) / unit;
                float hh = u > -22 ? 1 - (u + 22) * (u + 22) / 784 : (float)Math.Sin((u + 78) / 56 * 1.5708f);
                if (hh > 0) front.Column(x, yb - hh * 40 * unit, yb);
            }
            front.Touch(x0, (int)(yb - 40 * unit - 2), x1, yb);
            front.Sprite(ploughPx, ploughW, ploughH, left, yb - ploughH);
            front.Touch(left, yb - ploughH, left + ploughW, yb);
        }
        foreach (var it in items) {
            if (it.man) front.Sprite(it.px, it.pw, it.ph, (int)(it.x - it.pw / 2f), (int)(it.y + it.HalfH) - it.ph);
            else front.Ball(it.x, it.y, it.r, s);
            front.Touch((int)(it.x - it.HalfW - 3), (int)(it.y - it.HalfH - 3), (int)(it.x + it.HalfW + 4), (int)(it.y + it.HalfH + 4));
        }
        if (front.Solid) front.Veil(veilX, veilY, (int)(6 * s));
        front.Present(false, before);
    }
}

// MARK: L'application : icône près de l'horloge, réglages, démarrage

static class App {
    public const string Version = "1.0";
    public static volatile bool enabled = true, locked, quit;
    public static volatile bool ploughAsked;   // le menu demande le chasse-neige ; la scène le fait partir
    public static volatile bool fillAsked;     // tests automatiques seulement
    public static volatile float cadence = 0.6f;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static RegistryKey prefs;
    static NotifyIcon tray;
    static Scene scene;
    static ToolStripMenuItem startItem;
    static Form welcome;

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
                once.Tick += (o, e) => { once.Stop(); prefs.SetValue("accueilli", 1); Welcome(true); };
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
        var send = new ToolStripMenuItem("Envoyer le chasse-neige", null, (o, e) => ploughAsked = true) { Enabled = enabled };
        on.CheckedChanged += (o, e) => { enabled = send.Enabled = on.Checked; prefs.SetValue("mode", enabled ? 1 : 0); };
        var bar = new TrackBar { Minimum = 0, Maximum = 100, Value = (int)(cadence * 100), TickStyle = TickStyle.None, AutoSize = false, Width = 190, Height = 28 };
        bar.ValueChanged += (o, e) => { cadence = bar.Value / 100f; prefs.SetValue("cadence", bar.Value); };
        var start = startItem = new ToolStripMenuItem("Ouvrir au démarrage de Windows") { CheckOnClick = true };
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
        menu.Items.Add(send);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(start);
        menu.Items.Add("Présentation…", null, (o, e) => Welcome(false));
        menu.Items.Add("Quitter Flocon", null, (o, e) => Application.Exit());
        menu.Items.Add(new ToolStripLabel("Flocon " + Version) { Enabled = false });
        tray = new NotifyIcon { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath), Text = "Flocon", ContextMenuStrip = menu, Visible = true };
        tray.MouseUp += (o, e) => {   // le clic gauche ouvre le même menu que le clic droit
            if (e.Button != MouseButtons.Left) return;
            var show = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
            if (show != null) show.Invoke(tray, null);
        };
    }

    /// Fenêtre de présentation : ce que fait Flocon, puis où le trouver. « first » : premier lancement.
    static void Welcome(bool first) {
        if (welcome != null) { welcome.Activate(); return; }
        float z;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) z = g.DpiX / 96f;
        int width = (int)(430 * z);
        Color grey = Color.FromArgb(96, 96, 96), blue = Color.FromArgb(0, 120, 215);
        var f = welcome = new Form {
            Text = "Bienvenue dans Flocon", Icon = tray.Icon, Font = new Font("Segoe UI", 10), BackColor = Color.White,
            FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen,
            AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        };
        Func<FlowLayoutPanel> column = () => new FlowLayoutPanel {
            FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty };
        Func<string, float, FontStyle, Color, Label> text = (words, size, style, color) => new Label {
            Text = words, Font = new Font("Segoe UI", size, style), ForeColor = color, AutoSize = true, MaximumSize = new Size(width, 0),
            Margin = new Padding(0, 0, 0, (int)(3 * z)), UseMnemonic = false };
        Func<string, Button> button = words => new Button {
            Text = words, AutoSize = true, Anchor = AnchorStyles.None, FlatStyle = FlatStyle.System,
            Padding = new Padding((int)(18 * z), (int)(4 * z), (int)(18 * z), (int)(4 * z)), Margin = new Padding(0, (int)(14 * z), 0, 0) };

        Bitmap logo;
        try { using (var st = typeof(App).Assembly.GetManifestResourceStream("Flocon.ico")) using (var ic = new Icon(st, 256, 256)) logo = ic.ToBitmap(); }
        catch (Exception) { logo = tray.Icon.ToBitmap(); }
        var root = column(); var page1 = column(); var page2 = column();
        root.Padding = new Padding((int)(26 * z));
        page1.Anchor = page2.Anchor = AnchorStyles.None;
        root.Controls.Add(new PictureBox { Image = logo, SizeMode = PictureBoxSizeMode.Zoom, Size = new Size((int)(88 * z), (int)(88 * z)), Anchor = AnchorStyles.None, Margin = new Padding(0, 0, 0, (int)(10 * z)) });
        root.Controls.Add(page1); root.Controls.Add(page2);

        var title = text("Bienvenue dans Flocon", 19, FontStyle.Bold, Color.Black);
        title.Anchor = AnchorStyles.None; title.Margin = new Padding(0, 0, 0, (int)(12 * z));
        page1.Controls.Add(title);
        var table = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 48 * z));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        string[] features = {
            "\u2744", "Il neige sur votre bureau", "Les flocons tombent derrière vos fenêtres, portés par le vent, sans jamais gêner votre travail.",
            "\uD83D\uDDA5", "La neige se pose partout", "Elle s'accumule sur vos fenêtres, sur la barre des tâches et en bas de l'écran.",
            "\uD83D\uDDB1", "Elle réagit à vos gestes", "Balayez-la avec le curseur, secouez une fenêtre pour la faire tomber, rétrécissez-la et la neige bascule dans le vide.",
            "\u26C4", "Boules et bonhomme de neige", "Cliquez dans la neige pour former une boule, faites-la rouler pour la grossir, lancez-la. Trois boules empilées deviennent un bonhomme.",
            "\uD83D\uDE9C", "Le chasse-neige", "Trop de neige ? Envoyez le chasse-neige : il traverse l'écran et dégage le sol.",
            "\uD83C\uDF19", "Discret", "Flocon se met en pause quand l'écran se verrouille, et la neige s'évapore quand vous le désactivez.",
        };
        for (int i = 0; i < features.Length; i += 3) {
            var glyph = new Label { Text = features[i], Font = new Font("Segoe UI Emoji", 16), ForeColor = blue, AutoSize = true, UseMnemonic = false, Margin = new Padding(0, (int)(2 * z), 0, 0) };
            var words = text(features[i + 2], 10, FontStyle.Regular, grey);
            words.MaximumSize = new Size(width - (int)(48 * z), 0); words.Margin = new Padding(0, 0, 0, (int)(10 * z));
            table.Controls.Add(glyph, 0, i / 3 * 2);
            table.SetRowSpan(glyph, 2);
            table.Controls.Add(text(features[i + 1], 10.5f, FontStyle.Bold, Color.Black), 1, i / 3 * 2);
            table.Controls.Add(words, 1, i / 3 * 2 + 1);
        }
        page1.Controls.Add(table);
        var next = button("Continuer");
        page1.Controls.Add(next);

        var place = text("Flocon se range près de l'horloge", 16, FontStyle.Bold, Color.Black);
        place.Anchor = AnchorStyles.None; place.Margin = new Padding(0, 0, 0, (int)(10 * z));
        page2.Controls.Add(place);
        page2.Controls.Add(text("Pas de fenêtre ouverte : juste une icône en bas à droite de l'écran, près de l'horloge. Si vous ne la voyez pas, cliquez sur la petite flèche ^ ; vous pouvez ensuite faire glisser l'icône à côté de l'horloge pour la garder sous les yeux.", 10, FontStyle.Regular, grey));
        page2.Controls.Add(text("Cliquez sur l'icône pour régler la cadence de la neige, envoyer le chasse-neige, désactiver Flocon ou le quitter.", 10, FontStyle.Regular, grey));
        var atStart = new CheckBox { Text = "Ouvrir Flocon au démarrage de Windows", AutoSize = true, Checked = first || startItem.Checked, Margin = new Padding(0, (int)(12 * z), 0, 0) };
        page2.Controls.Add(atStart);
        var done = button("C'est parti");
        page2.Controls.Add(done);
        page2.Visible = false;

        next.Click += (o, e) => { page1.Visible = false; page2.Visible = true; f.AcceptButton = done; done.Focus(); };
        done.Click += (o, e) => { startItem.Checked = atStart.Checked; f.Close(); };
        f.FormClosed += (o, e) => {
            welcome = null; logo.Dispose();
            tray.ShowBalloonTip(4000, "Flocon est ici", "Cliquez sur cette icône pour les réglages.", ToolTipIcon.None);
        };
        f.Controls.Add(root);
        f.AcceptButton = next;
        f.Show();
        f.Activate();
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
            if (what == "chasse") ploughAsked = true;
            if (what == "neige") fillAsked = true;
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
            // retombée étalée sur cinq colonnes, puis tas trop raide qui s'affaisse sans rien perdre
            var m = new Ledge(3, 12);
            m.Resize(0, 30, null);
            m.Add(16, 30);
            check(Math.Abs(m.Total() - 10) < 0.01f && m.h[5] > m.h[4] && m.h[4] > m.h[3] && m.h[2] == 0);
            check(!m.Relax(2.4f));
            m.h[5] = 12;
            float total = m.Total();
            check(m.Relax(2.4f) && m.h[5] < 12 && m.h[4] > 2.5f && Math.Abs(m.Total() - total) < 0.01f);
            check(m.Index(-50) == 0 && m.Index(500) == 9 && m.Index(16) == 5);
        } catch (Exception e) {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "flocon-selftest.txt"), e.Message);
            return 1;
        }
        return 0;
    }
}
