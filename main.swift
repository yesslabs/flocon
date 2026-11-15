import Cocoa
import ServiceManagement
import SpriteKit
import SwiftUI

// Flocon — neige sur le bureau du Mac. Code original ; plusieurs idées de physique (vent, profondeur des flocons,
// neige qui glisse et se décroche des fenêtres, angle de repos, mottes et poudreuse) viennent de l'étude de
// Snowhush de Mykhailo Bezruchko (https://github.com/mbezruchko/Snowhush), sans reprise de son code.

// MARK: - Géométrie

/// Retire de [a, b] les intervalles `cuts` ; renvoie les morceaux restants d'au moins 8 pt.
func subtract(_ a: CGFloat, _ b: CGFloat, _ cuts: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
    var parts = [(a, b)]
    for (c0, c1) in cuts {
        parts = parts.flatMap { (p0, p1) -> [(CGFloat, CGFloat)] in
            if c1 <= p0 || c0 >= p1 { return [(p0, p1)] }
            var r: [(CGFloat, CGFloat)] = []
            if c0 > p0 { r.append((p0, c0)) }
            if c1 < p1 { r.append((c1, p1)) }
            return r
        }
    }
    return parts.filter { $0.1 - $0.0 >= 8 }
}

/// Un rebord où la neige se pose (coordonnées de la scène : origine en bas à gauche).
struct Surface {
    var x0: CGFloat, x1: CGFloat
    var y: CGFloat
    var visible: [(CGFloat, CGFloat)]   // parties non masquées par une autre fenêtre
    var maxH: CGFloat
    var radius: CGFloat = 0             // rayon des coins arrondis du support
    var margin: CGFloat = 0             // marge d'ombre : la fenêtre d'un widget déborde d'autant de son dessin
    func covers(_ x: CGFloat) -> Bool { visible.contains { x >= $0.0 && x <= $0.1 } }
    var shape: [CGFloat] { [x1 - x0, radius] + visible.flatMap { [$0.0 - x0, $0.1 - x0] } }
}

let groundKey = -1, dockKey = -2
let col: CGFloat = 3             // largeur d'une colonne de neige
let minR: CGFloat = 6, keepR: CGFloat = 9, maxR: CGFloat = 22   // rayon d'une boule : départ, seuil de fonte, limite
let gravity: CGFloat = 2500
let repose: CGFloat = 0.8        // pente maximale d'un tas de neige (hauteur sur longueur)
let adhesion: CGFloat = 8000     // la neige colle à sa fenêtre : il faut tirer plus fort que ça pour l'en décoller
let grip: CGFloat = 5, slip: CGFloat = 3.5   // frottement statique et cinétique de la neige sur une fenêtre
let throwWindow: CGFloat = 0.12  // durée sur laquelle on mesure le geste de lancer
let shaking: CGFloat = 4         // agitation (en multiples de la gravité) au-delà de laquelle la neige est projetée
let splatSpeed: CGFloat = 900    // au-delà de cette vitesse d'impact (chute d'environ 160 pt), une boule posée s'écrase
let thrownSplatSpeed: CGFloat = 350   // une boule lancée s'écrase dès qu'elle touche quelque chose avec un peu d'élan

// MARK: - Dessins

func picture(_ size: CGSize, _ draw: @escaping () -> Void) -> NSImage {
    let k: CGFloat = 3  // suréchantillonnage pour rester net sur écran Retina
    return NSImage(size: CGSize(width: size.width * k, height: size.height * k), flipped: false) { _ in
        let t = NSAffineTransform(); t.scale(by: k); t.concat()
        draw()
        return true
    }
}

func texture(_ size: CGSize, _ draw: @escaping () -> Void) -> SKTexture { SKTexture(image: picture(size, draw)) }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawBall(_ c: CGPoint, _ r: CGFloat) {
    let path = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSGradient(starting: .white, ending: rgb(0.78, 0.85, 0.95))?
        .draw(in: path, relativeCenterPosition: CGPoint(x: -0.35, y: 0.45))
    rgb(0.62, 0.72, 0.88, 0.7).setStroke()
    path.lineWidth = 0.6
    path.stroke()
}

func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
}

let flakeTexture = texture(CGSize(width: 8, height: 8)) {
    NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0))?
        .draw(in: NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 8, height: 8)), relativeCenterPosition: .zero)
}

// les images servent aussi telles quelles aux objets affichés dans un bandeau de fenêtre
let ballImage = picture(CGSize(width: 30, height: 30)) { drawBall(CGPoint(x: 15, y: 15), 14) }
let ballTexture = SKTexture(image: ballImage)

let manImage = picture(CGSize(width: 44, height: 70)) {
    rgb(0.36, 0.22, 0.12).setStroke()
    for (a, b) in [(CGPoint(x: 12, y: 37), CGPoint(x: 2, y: 47)), (CGPoint(x: 32, y: 37), CGPoint(x: 42, y: 47))] {
        let arm = NSBezierPath(); arm.move(to: a); arm.line(to: b); arm.lineWidth = 1.6; arm.stroke()
    }
    drawBall(CGPoint(x: 22, y: 15), 14)
    drawBall(CGPoint(x: 22, y: 36), 11.5)
    drawBall(CGPoint(x: 22, y: 54), 9.5)
    rgb(0.85, 0.12, 0.15).setFill()   // écharpe
    NSBezierPath(roundedRect: CGRect(x: 13, y: 43.5, width: 18, height: 4.5), xRadius: 2, yRadius: 2).fill()
    NSBezierPath(roundedRect: CGRect(x: 25, y: 34, width: 4.5, height: 11), xRadius: 2, yRadius: 2).fill()
    dot(18.5, 57, 1.3, .black); dot(25.5, 57, 1.3, .black)
    dot(22, 38, 1.2, .black); dot(22, 31, 1.2, .black); dot(22, 18, 1.2, .black)
    let nose = NSBezierPath()   // carotte
    nose.move(to: CGPoint(x: 21, y: 55)); nose.line(to: CGPoint(x: 31, y: 52.5)); nose.line(to: CGPoint(x: 21, y: 51.5))
    nose.close(); rgb(1, 0.5, 0.1).setFill(); nose.fill()
}
let manTexture = SKTexture(image: manImage)

let ploughSize = CGSize(width: 68, height: 46)
let ploughTexture = texture(ploughSize) {   // tourné vers la gauche, lame en x = 2…13
    let yellow = rgb(0.98, 0.76, 0.12), dark = rgb(0.18, 0.19, 0.22)
    dark.setFill()
    NSBezierPath(rect: CGRect(x: 10, y: 13, width: 12, height: 4)).fill()                                   // bras
    NSBezierPath(roundedRect: CGRect(x: 18, y: 0, width: 48, height: 13), xRadius: 6.5, yRadius: 6.5).fill() // chenille
    for i in 0..<4 { dot(25.5 + CGFloat(i) * 11, 6.5, 3.6, rgb(0.72, 0.74, 0.78)); dot(25.5 + CGFloat(i) * 11, 6.5, 1.3, dark) }
    yellow.setFill()
    NSBezierPath(roundedRect: CGRect(x: 18, y: 11, width: 46, height: 17), xRadius: 4, yRadius: 4).fill()   // caisse
    NSBezierPath(roundedRect: CGRect(x: 32, y: 24, width: 26, height: 18), xRadius: 4, yRadius: 4).fill()   // cabine
    rgb(0.55, 0.8, 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 35.5, y: 28, width: 19, height: 10.5), xRadius: 2, yRadius: 2).fill()
    dot(45, 43.5, 2.2, rgb(1, 0.45, 0.1))                                                                   // gyrophare
    let blade = NSBezierPath()
    blade.move(to: CGPoint(x: 2, y: 0)); blade.curve(to: CGPoint(x: 9, y: 31), controlPoint1: CGPoint(x: 9, y: 9), controlPoint2: CGPoint(x: 10, y: 22))
    blade.line(to: CGPoint(x: 13, y: 31)); blade.line(to: CGPoint(x: 13, y: 0)); blade.close()
    rgb(0.86, 0.88, 0.92).setFill(); blade.fill()
    rgb(0.85, 0.15, 0.15).setFill()
    NSBezierPath(rect: CGRect(x: 11.5, y: 0, width: 1.5, height: 31)).fill()
}

// MARK: - Objets

/// Boule de neige ou bonhomme. `r` est le rayon de la boule (ou de la boule du bas du bonhomme).
final class Item {
    enum Rest { case none, surface(Int, CGFloat), on(Item) }
    let node: SKSpriteNode
    let isMan: Bool
    var r: CGFloat { didSet { resize() } }
    var vx: CGFloat = 0, vy: CGFloat = 0
    var rest: Rest = .none
    var thrown = false   // lâchée avec de l'élan, et pas encore retombée
    var ghost: CALayer?          // posé sur une fenêtre, l'objet est affiché dans le bandeau de neige de celle-ci,
    weak var host: SnowPanel?    // que macOS déplace avec elle : dessiné dans la scène, il tremblait à la traîne
    func unhost() {
        ghost?.removeFromSuperlayer()
        ghost = nil
        host = nil
        node.isHidden = false
    }
    init(r: CGFloat, isMan: Bool) {
        node = SKSpriteNode(texture: isMan ? manTexture : ballTexture)
        node.zPosition = 20
        self.isMan = isMan
        self.r = r
        resize()
    }
    private func resize() {
        node.setScale(1)
        node.size = isMan ? CGSize(width: r * 44 / 14, height: r * 5) : CGSize(width: 2 * r + 2, height: 2 * r + 2)
    }
    var halfH: CGFloat { isMan ? r * 2.5 : r }
    var halfW: CGFloat { isMan ? r * 1.57 : r }
    var x: CGFloat { node.position.x }
    var falling: Bool { if case .none = rest { return true }; return false }
    func hit(_ p: CGPoint) -> Bool {
        abs(p.x - node.position.x) <= halfW + 3 && abs(p.y - node.position.y) <= halfH + 3
    }
}

struct Flake {
    let node: SKSpriteNode
    var vx: CGFloat, vy: CGFloat
    let fall: CGFloat      // vitesse de chute propre au flocon
    let depth: CGFloat     // 0 = lointain (petit, lent, peu sensible au vent), 1 = proche
    let size: CGFloat
    var phase: CGFloat
    let swayRate: CGFloat, swayAmount: CGFloat
    let settles: Bool      // les très gros flocons du premier plan ne se posent jamais
    let lands: Bool        // sinon le flocon continue derrière la fenêtre et ressort dessous
}

/// Neige en vol : poudre détachée d'un tas, ou motte compacte qui éclate en poudreuse à l'atterrissage.
struct Grain {
    let node: SKSpriteNode
    var vx: CGFloat, vy: CGFloat
    let area: CGFloat      // quantité de neige transportée, rendue au tas où elle retombe
    let lump: Bool
}

/// Voile de poudreuse soulevé par un choc ; il flotte un instant puis s'efface.
struct Mote {
    let node: SKSpriteNode
    var vx: CGFloat, vy: CGFloat, age: CGFloat
    let life: CGFloat, alpha: CGFloat
}

/// La neige d'un rebord, et la façon dont elle suit (ou non) le support sur lequel elle repose.
final class Ledge {
    var s: Surface
    var h: [CGFloat]
    var bed: [CGFloat] = []          // creux des coins arrondis sous chaque colonne (≤ 0)
    var mask: [Bool] = []            // colonnes visibles
    var track: CGPoint               // position lissée du support : la neige réagit à ses accélérations
    var trackVel = CGVector.zero
    var slide: CGFloat = 0, slideVel: CGFloat = 0   // glissement le long du support
    var lift: CGFloat = 0, liftVel: CGFloat = 0     // décollement au-dessus du support
    var agitation: CGFloat = 0       // intensité d'une secousse en va-et-vient, en multiples de la gravité
    var swingPeak: CGFloat = 0, lastSwingPeak: CGFloat = 0
    var swingDir = CGVector.zero
    var spill: (l: CGFloat, r: CGFloat) = (0, 0)    // neige qui a débordé aux extrémités
    var lastSeen: TimeInterval
    var hidden = false               // fenêtre toujours ouverte mais recouverte ou collée en haut de l'écran
    var resized: CGFloat = 0         // déplacement du bord gauche par redimensionnement, que le bandeau n'a pas suivi
    var lastChange: TimeInterval = 0 // dernier instant où la fenêtre a bougé ou changé de taille
    var hist: [(t: TimeInterval, x: CGFloat, y: CGFloat)] = []   // derniers relevés d'un déplacement en cours
    var offset = CGVector.zero       // avance donnée à l'affichage pour compenser le retard sur la fenêtre
    init(_ s: Surface, h: [CGFloat], now: TimeInterval) {
        self.s = s
        self.h = h
        track = CGPoint(x: s.x0, y: s.y)
        lastSeen = now
    }
}

// MARK: - Lecture de l'écran

private typealias ConnFn = @convention(c) () -> Int32
private typealias DockFn = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32

/// Rectangle du Dock (origine en haut à gauche). API privée de macOS, sans autorisation à demander ;
/// si elle disparaît un jour, on renvoie nil et la neige ne se pose simplement plus sur le Dock.
var dockCallResult: Int32 = 0   // dernier code de retour, pour le diagnostic
func readDockRect() -> CGRect? {
    let lib = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let conn = dlsym(lib, "SLSMainConnectionID"), let get = dlsym(lib, "SLSGetDockRectWithReason") else { return nil }
    var rect = CGRect.zero
    var reason: Int32 = 0
    // On juge au rectangle obtenu, pas au code de retour : sur Mac Intel il n'est pas nul alors que l'appel a réussi.
    dockCallResult = unsafeBitCast(get, to: DockFn.self)(unsafeBitCast(conn, to: ConnFn.self)(), &rect, &reason)
    return rect.width > 0 && rect.height > 0 ? rect : nil
}

/// Amortisseur critique : rapproche `current` de `target` en douceur, sans dépassement.
func smoothDamp(_ current: inout CGPoint, _ velocity: inout CGVector, toward target: CGPoint, time: CGFloat, dt: CGFloat) {
    let omega = 2 / time, x = omega * dt
    let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let cx = current.x - target.x, cy = current.y - target.y
    let tx = (velocity.dx + omega * cx) * dt, ty = (velocity.dy + omega * cy) * dt
    velocity = CGVector(dx: (velocity.dx - omega * tx) * decay, dy: (velocity.dy - omega * ty) * decay)
    current = CGPoint(x: target.x + (cx + tx) * decay, y: target.y + (cy + ty) * decay)
}

func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Bandeaux de neige des fenêtres

private typealias BoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
private typealias MoveFn = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32

func overlayPanel(_ level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.level = level
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

/// Bandeau transparent qui porte la neige d'une fenêtre. C'est une vraie fenêtre : macOS la déplace d'un simple
/// ordre, sans attendre qu'on redessine, ce qui la garde collée à la fenêtre qu'on fait glisser (redessinée dans
/// le calque plein écran, la neige avait deux à trois images de retard).
final class SnowPanel {
    static let padX: CGFloat = 40, above: CGFloat = 130, below: CGFloat = 32   // marges autour du rebord (un bonhomme tient au-dessus)
    static let height = above + below
    let panel = overlayPanel(.statusBar)
    let shape = CAShapeLayer()
    var inset = SnowPanel.padX   // abscisse du bord gauche de la fenêtre dans le bandeau, au dernier cadrage

    init() {
        let view = NSView()
        view.wantsLayer = true
        shape.anchorPoint = .zero
        shape.fillColor = CGColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)
        shape.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2
        view.layer?.addSublayer(shape)
        panel.contentView = view
    }

    /// Un tas qui apparaît monte en douceur au lieu de surgir.
    func rise() {
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity"), grow = CABasicAnimation(keyPath: "transform.scale.y")
        fade.fromValue = 0
        grow.fromValue = 0.2
        group.animations = [fade, grow]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(group, forKey: "rise")
    }

    func fadeOut(then done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [shape] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.removeAnimation(forKey: "fade")   // elle figeait le calque à zéro
            shape.path = nil
            shape.opacity = 1
            CATransaction.commit()
            done()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        shape.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

/// Fait suivre sa fenêtre à chaque bandeau, depuis un fil à part qui relit la position des fenêtres jusqu'à 2000 fois
/// par seconde pendant un déplacement (une lecture coûte 8 µs). API privées de macOS, sans autorisation à demander ;
/// si elles disparaissent, `available` est faux et la scène replace elle-même les bandeaux, avec un peu de retard.
final class Follower {
    private struct State { var win: CGRect; var panel: CGPoint; let panelID: UInt32; let margin: CGFloat; var hotUntil: TimeInterval }

    /// Rectangle du dessin de la fenêtre (origine en haut à gauche), sa marge d'ombre retirée.
    private func read(_ window: UInt32, _ margin: CGFloat) -> CGRect? {
        var b = CGRect.zero
        guard let getBounds, getBounds(cid, window, &b) == 0 else { return nil }
        return CGRect(x: b.minX + margin, y: b.minY + margin, width: b.width - 2 * margin, height: b.height - 2 * margin)
    }
    private let lock = NSLock()
    private var states: [UInt32: State] = [:]
    private var beat: TimeInterval = 0
    private var cid: Int32 = 0
    private var getBounds: BoundsFn?, move: MoveFn?
    var available: Bool { getBounds != nil && move != nil }

    init() {
        let lib = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let conn = dlsym(lib, "SLSMainConnectionID"), let get = dlsym(lib, "SLSGetWindowBounds"),
              let mv = dlsym(lib, "SLSMoveWindow") else { return }
        cid = unsafeBitCast(conn, to: ConnFn.self)()
        getBounds = unsafeBitCast(get, to: BoundsFn.self)
        move = unsafeBitCast(mv, to: MoveFn.self)
        Thread.detachNewThread { self.run() }   // le fil garde le suiveur en vie : il ne s'arrête jamais
    }

    /// À appeler à chaque image : sans nouvelles de la scène (pause, veille), le fil cesse de relever les fenêtres.
    func heartbeat() { lock.lock(); beat = CACurrentMediaTime(); lock.unlock() }

    func detach(_ window: UInt32) { lock.lock(); states[window] = nil; lock.unlock() }

    /// Où est le bord gauche de la fenêtre dans son bandeau, et sa largeur, au dernier relevé.
    func edge(_ window: UInt32) -> (inset: CGFloat, width: CGFloat)? {
        lock.lock(); defer { lock.unlock() }
        return states[window].map { ($0.win.minX - $0.panel.x, $0.win.width) }
    }

    /// Cadre le bandeau sur sa fenêtre telle qu'elle est à l'instant. S'il la couvre déjà à gauche, il ne bouge pas,
    /// seule sa largeur change : rien ne saute à l'écran. Renvoie l'abscisse du bord gauche de la fenêtre dedans.
    func frame(_ panel: NSPanel, on window: UInt32, margin: CGFloat) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let move, let b = read(window, margin) else { return nil }
        var o = CGPoint(x: b.minX - SnowPanel.padX, y: b.minY - SnowPanel.above)   // origine en haut à gauche
        if let st = states[window], b.minX - st.panel.x >= SnowPanel.padX { o.x = st.panel.x }
        let inset = b.minX - o.x
        let size = CGSize(width: inset + b.width + SnowPanel.padX, height: SnowPanel.height)
        let top = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(CGRect(x: o.x, y: top - o.y - size.height, width: size.width, height: size.height), display: false)
        _ = move(cid, UInt32(panel.windowNumber), &o)   // AppKit peut ignorer une origine qu'il croit déjà en place
        states[window] = State(win: b, panel: o, panelID: UInt32(panel.windowNumber), margin: margin, hotUntil: 0)
        return inset
    }

    private func run() {
        guard let move else { return }
        var n = 0
        while true {
            let now = CACurrentMediaTime()
            lock.lock()
            let idle = now - beat > 0.5 || states.isEmpty
            let anyHot = !idle && states.values.contains { now < $0.hotUntil }
            if !idle {
                // les fenêtres en mouvement sont relevées à chaque tour, les autres un tour sur huit pendant ce temps
                for (wid, var st) in states where !anyHot || now < st.hotUntil || n % 8 == 0 {
                    guard let b = read(wid, st.margin), b != st.win else { continue }
                    var o = st.panel
                    // déplacement : le bandeau suit. Redimensionnement : la neige reste où elle est à l'écran.
                    if b.size == st.win.size { o.x += b.minX - st.win.minX }
                    o.y = b.minY - SnowPanel.above
                    if o != st.panel { _ = move(cid, st.panelID, &o) }
                    st.win = b
                    st.panel = o
                    st.hotUntil = now + 0.3
                    states[wid] = st
                }
            }
            lock.unlock()
            n &+= 1
            usleep(idle ? 100_000 : anyHot ? 500 : CGEventSource.buttonState(.combinedSessionState, button: .left) ? 2000 : 8000)
        }
    }
}

// MARK: - Scène

/// Calque secondaire : son `update` fait avancer ce qu'il affiche, au rythme de sa propre vue.
final class LayerScene: SKScene {
    var step: ((TimeInterval) -> Void)?
    override func update(_ currentTime: TimeInterval) { step?(currentTime) }
}

final class SnowScene: SKScene {
    let back = LayerScene()           // flocons, affichés derrière toutes les fenêtres
    let dockLayer = SKScene()         // neige du Dock, affichée juste sous lui : ses icônes passent devant
    var menuBarH: CGFloat = 0
    var dockTop: CGFloat = 0          // hauteur réservée au Dock en bas de l'écran (0 = Dock masqué ou sur le côté)
    var spaceChanged = false          // levé par l'app quand on change de bureau
    var resumed = false               // levé par l'app à la sortie d'une pause : les fenêtres ont pu bouger entre-temps
    private var surfaces: [Int: Surface] = [:]   // rebords visibles en ce moment
    private var ledges: [Int: Ledge] = [:]       // leur neige (y compris celle des fenêtres momentanément cachées)
    private var shapes: [Int: SKShapeNode] = [:]      // neige du sol et du Dock
    private var snowPanels: [Int: SnowPanel] = [:]    // neige des fenêtres
    private let follower = Follower()
    private var dirty: Set<Int> = []
    var bare = false                             // évaporation en cours : plus rien ne se dépose
    private var urgent: Set<Int> = []
    private let listLock = NSLock()
    private var pendingList: ([[String: Any]], TimeInterval)?
    private var fetching = false
    private let listReady = DispatchSemaphore(value: 0)
    private var listTime: TimeInterval = 0
    private static let listQueue = DispatchQueue(label: "flocon.fenetres", qos: .userInteractive)            // rebords qui ont changé de forme : redessinés dès cette image
    private var flakes: [Flake] = []
    private var grains: [Grain] = []
    private var motes: [Mote] = []
    private var items: [Item] = []
    private var dragging: Item?
    private var lastDragPos = CGPoint.zero
    private var dragTrail: [(t: TimeInterval, p: CGPoint)] = []   // positions récentes de l'objet tenu
    private var cursor: CGPoint?
    private var cursorVel = CGVector.zero
    private var plough: SKSpriteNode?
    private var pile: SKShapeNode?
    private var collected: CGFloat = 0
    private var dockRect: CGRect?
    private var clock: TimeInterval = 0
    private var lastSpaceChange: TimeInterval = -10
    private var tick = 0
    private let seed = CGFloat.random(in: 0...1000)
    private let windowRadius: CGFloat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 16 : 18
    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }

    private func mousePoint() -> CGPoint { NSEvent.mouseLocation }   // le calque couvre l'écran principal, d'origine (0, 0)

    override func didMove(to view: SKView) {
        var last: TimeInterval = 0
        // les flocons avancent au rythme de la vue qui les affiche : pilotés depuis une autre vue, ils saccadaient
        back.step = { [unowned self] t in
            let dt = CGFloat(min(max(t - last, 0), 0.05))
            last = t
            if self.W > 0, self.H > 0, dt > 0.001 { self.stepFlakes(dt) }
        }
    }

    /// Relève les fenêtres sur un fil d'arrière-plan et attend le résultat 3 ms au plus : d'ordinaire il arrive dans
    /// l'image même, et quand WindowServer est occupé (fenêtre qu'on déplace) l'animation ne se fige plus à l'attendre.
    private func fetchWindowList() -> ([[String: Any]], TimeInterval)? {
        listLock.lock()
        let busy = fetching
        fetching = true
        listLock.unlock()
        if !busy {
            Self.listQueue.async { [weak self] in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let t = CACurrentMediaTime()
                guard let self else { return }
                self.listLock.lock()
                self.pendingList = (list, t)
                self.fetching = false
                self.listLock.unlock()
                self.listReady.signal()
            }
        }
        _ = listReady.wait(timeout: .now() + 0.003)
        listLock.lock()
        defer { listLock.unlock() }
        let result = pendingList
        pendingList = nil
        return result
    }

    // MARK: Flocons

    /// Brise lente et irrégulière : trois ondes de périodes différentes qui ne se répètent jamais vraiment.
    private func breeze() -> CGFloat {
        let t = CGFloat(clock)
        return 10 * sin(t * 0.07) + 6 * sin(t * 0.19 + 1.7) + 3 * sin(t * 0.43 + 4.1)
    }

    func setFlakeCount(_ n: Int) {
        while flakes.count > n { flakes.removeLast().node.removeFromParent() }
        while flakes.count < n { flakes.append(makeFlake(y: .random(in: 0...max(H, 1)))) }
    }

    private func makeFlake(y: CGFloat) -> Flake {
        let near = Int.random(in: 0..<50) == 0   // de rares gros flocons flous au premier plan
        let depth = near ? 1 : pow(CGFloat.random(in: 0...1), 1.6)
        let size = near ? CGFloat.random(in: 8...13) : 2 + depth * 4.4 + .random(in: 0...1)
        let fall = near ? CGFloat.random(in: 75...100) : 16 + depth * 50 + .random(in: 0...10)
        let node = SKSpriteNode(texture: flakeTexture, size: CGSize(width: size, height: size))
        node.alpha = near ? 0.28 : 0.4 + depth * 0.5
        node.position = CGPoint(x: .random(in: -30...(max(W, 1) + 30)), y: y)
        back.addChild(node)
        return Flake(node: node, vx: breeze() * (0.35 + 0.65 * depth), vy: -fall, fall: fall, depth: depth, size: size,
                     phase: .random(in: 0...60), swayRate: .random(in: 0.5...1.4),
                     swayAmount: near ? .random(in: 10...20) : .random(in: 4...9) + depth * 10,
                     settles: !near, lands: Bool.random())
    }

    private func stepFlakes(_ dt: CGFloat) {
        let wind = breeze()
        let follow = min(1, dt * 1.2), ease = min(1, dt * 1.6)
        let speed = hypot(cursorVel.dx, cursorVel.dy)
        // l'air que la souris entraîne quand elle bouge emporte les flocons proches
        let wake: (c: CGPoint, v: CGVector)? = cursor.flatMap { c in
            speed > 20 ? (c, speed > 500 ? CGVector(dx: cursorVel.dx * 500 / speed, dy: cursorVel.dy * 500 / speed) : cursorVel) : nil
        }
        let surf: [(Int, Surface, Ledge)] = surfaces.compactMap { k, s in ledges[k].map { (k, s, $0) } }
        for i in flakes.indices {
            var f = flakes[i]
            let p = f.node.position
            f.vx += (wind * (0.35 + 0.65 * f.depth) - f.vx) * follow   // les flocons proches prennent plus le vent
            f.vy += (-f.fall - f.vy) * ease
            if let wake {
                let d = hypot(p.x - wake.c.x, p.y - wake.c.y)
                if d < 80 {
                    let pull = min(1, (1 - d / 80) * (1 - d / 80) * 4 * dt)
                    f.vx += (wake.v.dx - f.vx) * pull
                    f.vy += (wake.v.dy - f.vy) * pull
                }
            }
            f.phase += f.swayRate * dt
            let sway = (cos(f.phase) + 0.3 * cos(f.phase * 2.3)) * f.swayAmount   // balancement à deux harmoniques
            var nx = p.x + (f.vx + sway) * dt
            let ny = p.y + f.vy * (1 + 0.12 * sin(f.phase * 1.3)) * dt
            if nx < -30 { nx += W + 60 } else if nx > W + 30 { nx -= W + 60 }
            var landed = false
            if f.settles {
                for (k, s, l) in surf where (f.lands || k == groundKey)
                    && ny < s.y + l.lift + s.maxH + 6 && p.y >= s.y + l.lift - s.radius - 1 && s.covers(nx) {
                    let c = column(s, nx, l.h.count)
                    let top = s.y + l.lift + l.bed[c] + l.h[c]
                    if p.y >= top && ny < top {
                        // plus le tas approche de sa hauteur limite, moins la neige y tient
                        deposit(k, nx, f.size * f.size * max(0, 1 - l.h[c] / cap(k, s, c)))
                        landed = true
                        break
                    }
                }
            }
            if landed || ny < -f.size * 2 {
                f.node.position = CGPoint(x: .random(in: -30...(W + 30)), y: H + .random(in: 0...20))
                f.vx = wind * (0.35 + 0.65 * f.depth)
                f.vy = -f.fall
            } else {
                f.node.position = CGPoint(x: nx, y: ny)
            }
            flakes[i] = f
        }
    }

    // MARK: Neige accumulée

    private func column(_ s: Surface, _ x: CGFloat, _ count: Int) -> Int {
        min(count - 1, max(0, Int((x - s.x0) / col)))
    }

    private func columnX(_ s: Surface, _ i: Int) -> CGFloat { s.x0 + (CGFloat(i) + 0.5) * col }

    /// Relief propre à chaque endroit (0…1) : grandes congères, bosses moyennes et petites irrégularités.
    private func relief(_ k: Int, _ i: Int) -> CGFloat {
        let x = CGFloat(i) * col + seed + CGFloat(abs(k) % 97) * 53
        let n = 0.5 + 0.27 * sin(x / 97) + 0.15 * sin(x / 31 + 1.7) + 0.08 * sin(x / 11 + 0.4)
        return min(1, max(0, n))
    }

    /// Hauteur limite de neige dans une colonne : très variable au sol, plus régulière sur les fenêtres.
    private func cap(_ k: Int, _ s: Surface, _ i: Int) -> CGFloat {
        let n = relief(k, i)
        return s.maxH * (k == groundKey ? 0.12 + 0.88 * n * n : 0.55 + 0.45 * n)
    }

    /// Ajoute une quantité de neige (en pt²) centrée sur `x`, étalée en cloche sur cinq colonnes.
    private func deposit(_ k: Int, _ x: CGFloat, _ area: CGFloat) {
        guard !bare, let l = ledges[k], !l.h.isEmpty, area > 0 else { return }
        let c = Int(((x - l.s.x0) / col).rounded(.down))
        for (o, w) in [(-2, 0.0625), (-1, 0.25), (0, 0.375), (1, 0.25), (2, 0.0625)] as [(Int, CGFloat)] {
            let i = c + o
            if i >= 0 && i < l.h.count && l.mask[i] { l.h[i] += area / col * w }
        }
        dirty.insert(k)
    }

    /// Le tas s'affaisse là où sa pente dépasse l'angle de repos, et ses crêtes s'arrondissent. Sur une fenêtre,
    /// la neige suit le creux des coins arrondis et ce qui dépasse aux extrémités tombe.
    private func relax(_ k: Int, _ l: Ledge) {
        let n = l.h.count
        guard n > 3 else { return }
        // secoué plus fort que la gravité, un tas de grains se fluidifie et s'étale
        let limit = repose * col * (l.agitation > shaking ? 0.35 : 1), steepest = 1.4 * col
        var moved = false
        for pass in 0..<4 {
            var shifted = false
            for j in 0..<(n - 1) {
                let i = pass % 2 == 0 ? j : n - 2 - j
                guard l.mask[i], l.mask[i + 1] else { continue }
                let diff = (l.bed[i] + l.h[i]) - (l.bed[i + 1] + l.h[i + 1])
                let drop = l.bed[i] - l.bed[i + 1]
                let ahead = limit + min(max(drop, 0), steepest), behind = limit + min(max(-drop, 0), steepest)
                if diff > ahead + 0.01 {
                    let t = min((diff - ahead) * 0.5, l.h[i])
                    l.h[i] -= t; l.h[i + 1] += t
                    if t > 0.001 { shifted = true }
                } else if diff < -behind - 0.01 {
                    let t = min((-diff - behind) * 0.5, l.h[i + 1])
                    l.h[i + 1] -= t; l.h[i] += t
                    if t > 0.001 { shifted = true }
                }
            }
            if k != groundKey {
                if l.mask[0], l.h[0] > limit + 0.01 {
                    let t = (l.h[0] - limit) * 0.5
                    l.h[0] -= t; l.spill.l += t * col; shifted = true
                }
                if l.mask[n - 1], l.h[n - 1] > limit + 0.01 {
                    let t = (l.h[n - 1] - limit) * 0.5
                    l.h[n - 1] -= t; l.spill.r += t * col; shifted = true
                }
            }
            if !shifted { break }
            moved = true
        }
        for i in 1..<(n - 2) where l.mask[i - 1] && l.mask[i] && l.mask[i + 1] && l.mask[i + 2] {
            let s0 = l.bed[i - 1] + l.h[i - 1], s1 = l.bed[i] + l.h[i], s2 = l.bed[i + 1] + l.h[i + 1], s3 = l.bed[i + 2] + l.h[i + 2]
            let kink = (s1 - s2) - 0.5 * ((s0 - s1) + (s2 - s3))
            guard abs(kink) > 0.02 else { continue }
            let t = kink > 0 ? min(kink * 0.15, l.h[i]) : max(kink * 0.15, -l.h[i + 1])
            l.h[i] -= t; l.h[i + 1] += t
            if abs(t) > 0.003 { moved = true }
        }
        if moved { dirty.insert(k) }
        // ce qui a débordé tombe en poudre le long du bord
        let v = CGVector(dx: l.trackVel.dx, dy: l.trackVel.dy - 15)
        if l.spill.l > 1.5 {
            release(l.spill.l, at: CGPoint(x: l.s.x0 + 1, y: l.s.y + l.bed[0]), v: CGVector(dx: v.dx - 6, dy: v.dy), spread: CGSize(width: 0.5, height: 1))
            l.spill.l = 0
        }
        if l.spill.r > 1.5 {
            release(l.spill.r, at: CGPoint(x: l.s.x1 - 1, y: l.s.y + l.bed[n - 1]), v: CGVector(dx: v.dx + 6, dy: v.dy), spread: CGSize(width: 0.5, height: 1))
            l.spill.r = 0
        }
    }

    /// Recalcule le creux des coins arrondis (superellipse, comme les coins de macOS) et les colonnes visibles.
    private func reshape(_ l: Ledge) {
        let s = l.s, w = s.x1 - s.x0
        l.bed = l.h.indices.map { i in
            guard s.radius > 0 else { return 0 }
            let x = (CGFloat(i) + 0.5) * col, inset = max(min(x, w - x), 0)
            guard inset < s.radius else { return 0 }
            return -s.radius * (1 - pow(max(0, 1 - pow(1 - inset / s.radius, 2.5)), 0.4))
        }
        l.mask = l.h.indices.map { s.covers(columnX(s, $0)) }
    }

    private func readSurfaces(_ info: [[String: Any]]) -> (surfaces: [Int: Surface], open: Set<Int>) {
        var out: [Int: Surface] = [:]
        var open: Set<Int> = []   // toutes les fenêtres ouvertes, même celles sans rebord visible
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var found: [(id: Int, r: CGRect, widget: Bool)] = []   // de la plus en avant à la plus en arrière
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer <= 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > (layer < 0 ? 0.05 : 0.9),   // une fenêtre qui s'efface (fermeture) ne porte plus rien
                  let id = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  var r = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  r.width >= 120, r.height >= 60 else { continue }
            // Sous le niveau des fenêtres, seuls les widgets du bureau comptent : le fond d'écran, le bureau du Finder
            // et nos propres calques occupent tout l'écran et sont écartés par leur taille.
            let widget = layer < 0
            if widget {
                guard r.width < W * 0.9, r.height < H * 0.9, (w[kCGWindowOwnerPID as String] as? Int) != me else { continue }
                // la fenêtre d'un widget déborde de son dessin (marge pour l'ombre) : mesuré sur capture d'écran
                r = CGRect(x: r.minX + 8, y: r.minY + 8, width: r.width - 16, height: r.height - 17)
            }
            open.insert(id)
            found.append((id, r, widget))
        }
        let front = found.filter { !$0.widget }.map(\.r)   // les fenêtres seules, dans le même ordre
        for (i, (id, r, widget)) in found.enumerated() {
            // on ignore les fenêtres collées sous la barre des menus ou presque hors écran
            guard r.minY > menuBarH + 2, r.minY < H - 20 else { continue }
            var cuts: [(CGFloat, CGFloat)] = []
            for (j, other) in found.enumerated() where j != i && !other.widget {
                let o = other.r
                // une fenêtre de devant masque le rebord, et aussi la bande de neige juste au-dessus
                if j < i && o.minY <= r.minY && o.maxY > r.minY - 14 { cuts.append((o.minX, o.maxX)) }
                // une fenêtre de derrière qui dépasse juste au-dessus du rebord fait écran : les flocons tombent
                // derrière elle, ils ne peuvent donc pas se poser là
                if j > i && o.minY < r.minY - 2 && o.maxY > r.minY - 2 { cuts.append((o.minX, o.maxX)) }
            }
            let vis = subtract(max(r.minX, 0), min(r.maxX, W), cuts)
            if !vis.isEmpty {
                out[id] = Surface(x0: r.minX, x1: r.maxX, y: H - r.minY, visible: vis, maxH: 12,
                                  radius: min(widget ? 28 : windowRadius, r.width / 2, r.height / 2), margin: widget ? 8 : 0)
            }
        }
        // le sol disparaît derrière les fenêtres qui descendent jusqu'en bas de l'écran, et ne passe pas devant le Dock
        var low = front.filter { $0.maxY > H - 12 }.map { ($0.minX, $0.maxX) }
        if let d = dockRect, dockTop > 20, d.width > d.height, d.width > 60 {   // Dock visible en bas
            // la tablette visible flotte quelques points au-dessus du bord de l'écran, à l'intérieur de la zone réservée
            let a = max(d.minX, 0), b = min(d.maxX, W)
            if b - a > 40 {
                out[dockKey] = Surface(x0: d.minX, x1: d.maxX, y: H - d.minY - 1, visible: [(a, b)], maxH: 12,
                                       radius: (d.height - 7) * 0.42)
            }
            low.append((d.minX, d.maxX))
        }
        out[groundKey] = Surface(x0: 0, x1: W, y: 0, visible: subtract(0, W, low), maxH: 30)
        return (out, open)
    }

    private func refreshSurfaces(_ list: [[String: Any]], _ dt: CGFloat) {
        let (new, open) = readSurfaces(list)
        for (k, s) in new {
            guard let l = ledges[k] else {
                let n = max(1, Int(ceil((s.x1 - s.x0) / col)))
                let l = Ledge(s, h: [CGFloat](repeating: 0, count: n), now: clock)
                ledges[k] = l
                reshape(l)
                dirty.insert(k)
                continue
            }
            let old = l.s
            if s.x0 != old.x0 || s.x1 != old.x1 || s.y != old.y { l.lastChange = clock }
            if k >= 0 {
                // un redimensionnement ne déplace qu'un bord : seul le bord le plus immobile compte comme déplacement
                let jump = hypot(min(abs(s.x0 - old.x0), abs(s.x1 - old.x1)), s.y - old.y)
                if jump / max(dt, 1 / 120) > 6000 && !l.hidden {
                    // la fenêtre a disparu de sous la neige pour réapparaître ailleurs : rien n'a emporté la neige
                    shed(k, l, share: 1, v: .zero)
                    l.track = CGPoint(x: s.x0, y: s.y)
                    l.trackVel = .zero
                    l.hidden = true   // pas de vitesse à déduire d'un saut
                }
            }
            // vitesse du déplacement (les deux bords bougent ensemble ; un redimensionnement n'en est pas un)
            // trajectoire récente du déplacement (les deux bords bougent ensemble ; un redimensionnement n'en est pas un)
            if l.hidden || abs((s.x0 - old.x0) - (s.x1 - old.x1)) >= 0.5 { l.hist.removeAll() }
            l.hist.append((listTime, s.x0, s.y))
            if l.hist.count > 4 { l.hist.removeFirst() }
            // Une fenêtre qui change de largeur sans qu'on tienne la souris est animée par macOS : réduction dans le
            // Dock (son rectangle se déforme 0,5 s avant de disparaître de la liste), zoom, rangement. Sa neige tombe
            // dès le début, au lieu de rester suspendue jusqu'à la fin de l'animation.
            if k >= 0, !l.hidden, abs((s.x1 - s.x0) - (old.x1 - old.x0)) > 0.5, NSEvent.pressedMouseButtons == 0 {
                shed(k, l, share: 1, v: .zero)
                for it in items { if case .surface(k, _) = it.rest { it.rest = .none } }
            }
            resize(k, l, to: s)
            if l.bed.count != l.h.count || old.shape != s.shape || l.hidden {
                reshape(l)
                dirty.insert(k)
                urgent.insert(k)
            }
            if l.hidden {   // elle revient après avoir été cachée : pas de secousse
                l.hidden = false
                l.track = CGPoint(x: s.x0, y: s.y)
                l.trackVel = .zero
            }
            l.lastSeen = clock
        }
        // Une seule fenêtre disparaît : elle vient d'être fermée ou réduite, sa neige tombe tout de suite. Plusieurs
        // d'un coup : sans doute un changement de bureau, on attend d'en avoir la confirmation.
        let closing = ledges.filter { $0.key >= 0 && new[$0.key] == nil && !open.contains($0.key) && !$0.value.hidden }.count == 1
        for (k, l) in ledges where new[k] == nil {
            shapes.removeValue(forKey: k)?.removeFromParent()
            removeSnowPanel(k)
            if open.contains(k) {   // toujours ouverte, seulement recouverte : sa neige l'attend
                l.hidden = true
                l.lastSeen = clock
                continue
            }
            guard closing || clock - l.lastSeen > 0.3 else { continue }   // on laisse le temps d'apprendre un changement de bureau
            if !l.hidden && k >= 0 && clock - lastSpaceChange > 1.5 {
                // fenêtre fermée ou réduite : sa neige tombe en mottes
                shed(k, l, share: 1, v: .zero)
            }
            ledges[k] = nil
        }
        surfaces = new
    }

    /// Applique la nouvelle géométrie d'un rebord. Redimensionnée par la gauche, la fenêtre glisse sous la neige, qui
    /// reste en place à l'écran (au point près, grâce au décalage `slide`) ; ce qui dépasse d'un bord tombe.
    func resize(_ k: Int, _ l: Ledge, to s: Surface) {
        let old = l.s, n = max(1, Int(ceil((s.x1 - s.x0) / col)))
        // largeur changée : ce n'est pas un déplacement, la neige ne suit pas le bord gauche (même règle que Follower)
        let fromLeft = abs((s.x1 - s.x0) - (old.x1 - old.x0)) > 0.01 && abs(s.x0 - old.x0) > 0.01
        l.s = s
        if fromLeft {
            let d = s.x0 - old.x0
            l.slide -= d
            l.resized += d
            l.track.x += d   // pas un déplacement : la neige ne doit ressentir aucun à-coup
            for it in items { if case .surface(k, let dx) = it.rest { it.rest = .surface(k, dx - d) } }
        }
        guard fromLeft || l.h.count != n else { return }
        // Dock : on retient le dessus de la neige plutôt que son épaisseur. Sinon, la neige logée dans le creux d'un
        // coin arrondi remonterait d'un coup quand ce coin s'éloigne, et le tas aurait l'air de grossir.
        let keepTop = k == dockKey && l.bed.count == l.h.count
        let empty: CGFloat = keepTop ? -1000 : 0
        if keepTop { for i in l.h.indices { l.h[i] = l.h[i] > 0.01 ? l.h[i] + l.bed[i] : empty } }
        let v = CGVector(dx: l.trackVel.dx, dy: l.trackVel.dy - 15)
        var puffed: Set<CGFloat> = []
        // La neige qui perd son appui bascule vers l'extérieur : poudre dispersée, mottes là où elle est épaisse,
        // et un petit voile de poudreuse au bord.
        func fall(_ h: CGFloat, _ x: CGFloat) {
            guard h > 0.01 else { return }
            let out: CGFloat = x < (s.x0 + s.x1) / 2 ? -1 : 1
            let lump: CGFloat = h > 4 ? 0.4 : 0
            release(h * col * (1 - lump), at: CGPoint(x: x, y: s.y + l.lift),
                    v: CGVector(dx: v.dx + out * .random(in: 20...70), dy: v.dy + .random(in: 20...90)),
                    spread: CGSize(width: col / 2, height: h), scatter: 0.35)
            if lump > 0 {
                throwLump(h * col * lump, at: CGPoint(x: x, y: s.y + l.lift + h / 2),
                          v: CGVector(dx: v.dx + out * .random(in: 15...45), dy: v.dy + .random(in: 0...40)))
            }
            if puffed.insert(out).inserted {
                puff(at: CGPoint(x: out < 0 ? s.x0 : s.x1, y: s.y + l.lift), size: 6, force: 0.4, drift: out * 60)
            }
        }
        // abscisse à l'écran de la colonne i : s.x0 + slide + (i + 0.5) * col
        while l.slide >= col { l.h.insert(empty, at: 0); l.slide -= col }   // le bord gauche s'est écarté
        while l.slide <= -col && !l.h.isEmpty {                         // il est passé sous la neige : elle tombe
            fall(l.h.removeFirst(), s.x0 + l.slide + col / 2)
            l.slide += col
        }
        if l.slide <= -col { l.slide = 0 }
        while l.h.count > n {
            let x = s.x0 + l.slide + (CGFloat(l.h.count) - 0.5) * col
            let h = l.h.removeLast()
            if x > s.x1 || keepTop { fall(h, x) } else { l.h[l.h.count - 1] += h }   // simple arrondi de largeur : rien ne tombe
        }
        if l.h.count < n { l.h += [CGFloat](repeating: empty, count: n - l.h.count) }
        if keepTop {
            reshape(l)
            for i in l.h.indices { l.h[i] = max(0, l.h[i] - l.bed[i]) }
        }
        dirty.insert(k)
        urgent.insert(k)
    }

    /// La neige d'une fenêtre est un corps posé dessus : elle subit la gravité et l'inertie des accélérations de la
    /// fenêtre, tient par frottement, glisse quand il est dépassé, et décolle si la fenêtre se dérobe plus vite
    /// qu'elle ne tombe.
    private func carry(_ k: Int, _ l: Ledge, _ dt: CGFloat) {
        let s = l.s, n = l.h.count
        let before = l.trackVel
        smoothDamp(&l.track, &l.trackVel, toward: CGPoint(x: s.x0, y: s.y), time: 0.06, dt: dt)
        let ax = (l.trackVel.dx - before.dx) / dt, ay = (l.trackVel.dy - before.dy) / dt
        // l'agitation mesure un va-et-vient : deux à-coups de sens opposés, pas un simple départ ou arrêt
        l.agitation *= exp(-dt / 0.3)
        let mag = hypot(ax, ay)
        if mag > 1, ax * l.swingDir.dx + ay * l.swingDir.dy < 0 {
            l.agitation = max(l.agitation, min(l.lastSwingPeak, l.swingPeak) / gravity)
            l.lastSwingPeak = l.swingPeak
            l.swingPeak = mag
            l.swingDir = CGVector(dx: ax / mag, dy: ay / mag)
        } else {
            l.swingPeak = max(l.swingPeak, mag)
            if mag > 1, l.swingDir == .zero { l.swingDir = CGVector(dx: ax / mag, dy: ay / mag) }
        }
        guard (l.h.max() ?? 0) > 0.05 else {
            l.slide = 0; l.slideVel = 0; l.lift = 0; l.liftVel = 0
            return
        }
        // décollement : la fenêtre descend plus vite que la neige ne peut la suivre, malgré son adhérence
        let rise = -gravity - ay
        if l.lift > 0 || rise > adhesion {
            l.liftVel += rise * dt
            l.lift += l.liftVel * dt
            if l.lift <= 0 { l.lift = 0; l.liftVel = 0 }
        }
        // glissement : frottement statique puis cinétique, proportionnels à l'appui sur la fenêtre
        let pressure = l.lift > 0 ? 0 : max(0, gravity + adhesion + ay)
        let drive = -ax
        if !(l.slideVel == 0 && abs(drive) <= grip * pressure) {
            let dir: CGFloat = l.slideVel != 0 ? (l.slideVel > 0 ? 1 : -1) : (drive > 0 ? 1 : -1)
            let next = l.slideVel + (drive - dir * slip * pressure) * dt
            l.slideVel = pressure > 0 && next * dir <= 0 ? 0 : next
        }
        l.slide += l.slideVel * dt
        let carried = CGVector(dx: l.trackVel.dx + l.slideVel, dy: l.trackVel.dy + l.liftVel)
        var guardCount = 0
        while abs(l.slide) >= col && guardCount < n {   // la neige avance d'une colonne ; celle du bout tombe
            guardCount += 1
            let right = l.slide > 0
            let dropped = right ? l.h.removeLast() : l.h.removeFirst()
            if right { l.h.insert(0, at: 0) } else { l.h.append(0) }
            l.slide -= right ? col : -col
            if dropped > 0.01 {
                release(dropped * col, at: CGPoint(x: right ? s.x1 + col : s.x0 - col, y: s.y + l.lift), v: carried,
                        spread: CGSize(width: col / 2, height: dropped))
            }
            dirty.insert(k)
        }
        if l.lift > 10 {   // complètement décollée : tout part d'un bloc, en mottes et en poudre
            shed(k, l, share: 1, v: carried)
            l.slide = 0; l.slideVel = 0; l.lift = 0; l.liftVel = 0
        } else if l.agitation > shaking {
            // un lit de grains secoué bien au-delà de la gravité projette des grains depuis sa surface
            let picks = Int(CGFloat(n) * min(0.8, 0.06 * (l.agitation - shaking)) * dt * 2 + .random(in: 0...1))
            for _ in 0..<picks {
                let i = Int.random(in: 0..<n)
                let h = l.h[i]
                guard h > 0.2, l.mask[i] else { continue }
                l.h[i] = h / 2
                release(h / 2 * col, at: CGPoint(x: columnX(s, i), y: s.y + l.lift + l.bed[i] + h / 2),
                        v: CGVector(dx: carried.dx + .random(in: -80...80), dy: carried.dy + .random(in: 50...200)),
                        spread: CGSize(width: col / 2, height: h / 2), scatter: 0.25)
                dirty.insert(k)
            }
        }
    }

    /// Fait tomber une part de la neige d'un rebord : en poudre, et en mottes là où il y en a assez pour tenir ensemble.
    private func shed(_ k: Int, _ l: Ledge, share: CGFloat, v: CGVector) {
        let s = l.s, n = l.h.count
        guard l.mask.count == n, l.bed.count == n else { return }
        var start = 0
        while start < n {
            let end = min(n, start + Int.random(in: 2...6))
            var snow: CGFloat = 0
            for i in start..<end where l.mask[i] && l.h[i] > 0.05 { snow += l.h[i] * share * col }
            let cohesion: CGFloat = snow > 14 ? .random(in: 0.4...0.7) : 0
            for i in start..<end where l.h[i] > 0.05 {
                let amount = l.h[i] * share
                l.h[i] -= amount
                guard l.mask[i] else { continue }
                release(amount * col * (1 - cohesion), at: CGPoint(x: columnX(s, i), y: s.y + l.lift + l.bed[i] + l.h[i]),
                        v: v, spread: CGSize(width: col / 2, height: amount), scatter: 0.25)
            }
            if cohesion > 0 {
                throwLump(snow * cohesion, at: CGPoint(x: (columnX(s, start) + columnX(s, end - 1)) / 2, y: s.y + l.lift + 2), v: v)
            }
            start = end
        }
        dirty.insert(k)
    }

    private func redrawSnow(_ keys: Set<Int>) {
        for k in keys {
            guard let s = surfaces[k], let l = ledges[k], l.bed.count == l.h.count else { continue }
            let n = l.h.count
            let path = CGMutablePath()
            for (a, b) in s.visible {
                let i0 = column(s, a - l.slide, n), i1 = column(s, b - 0.01 - l.slide, n)
                guard i1 >= i0 else { continue }
                var top: [CGPoint] = [], bottom: [CGPoint] = []
                for i in i0...i1 {
                    let x = min(max(columnX(s, i) + l.slide, a), b)   // à l'écran, bornée au morceau visible
                    // là où un morceau est coupé net (bord du Dock, fenêtre de devant), la neige s'amincit
                    let edge = min(1, a <= s.x0 + 0.5 ? 1 : (x - a) / 12, b >= s.x1 - 0.5 ? 1 : (b - x) / 12)
                    let h = (l.h[max(i - 1, 0)] + 2 * l.h[i] + l.h[min(i + 1, n - 1)]) / 4 * max(0, edge)
                    let lx = x - s.x0 - l.slide   // le nœud est déjà décalé de `slide`
                    top.append(CGPoint(x: lx, y: l.bed[i] + h))
                    bottom.append(CGPoint(x: lx, y: l.bed[i] - min(1.5, h)))   // pas de liseré là où il n'y a plus de neige
                }
                path.addLines(between: top + bottom.reversed())
                path.closeSubpath()
            }
            if k >= 0 {
                let p = snowPanels[k] ?? makeSnowPanel(k, l)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                p.shape.path = path
                CATransaction.commit()
                continue
            }
            let node = shapes[k] ?? {
                let node = SKShapeNode()
                node.fillColor = SKColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)
                node.strokeColor = .clear
                node.zPosition = 5
                // un tas qui apparaît (déverrouillage, fenêtre découverte) monte en douceur au lieu de surgir
                node.alpha = 0
                node.yScale = 0.2
                let rise = SKAction.group([.fadeIn(withDuration: 0.6), .scaleY(to: 1, duration: 0.6)])
                rise.timingMode = .easeOut
                node.run(rise)
                (k == dockKey ? dockLayer : self).addChild(node)
                shapes[k] = node
                return node
            }()
            node.path = path
        }
        dirty.subtract(keys)
        urgent.subtract(keys)
    }

    private func makeSnowPanel(_ k: Int, _ l: Ledge) -> SnowPanel {
        let p = SnowPanel()
        l.resized = 0
        if let inset = follower.frame(p.panel, on: UInt32(k), margin: l.s.margin) { p.inset = inset }
        p.rise()
        if let front = view?.window { p.panel.order(.below, relativeTo: front.windowNumber) }   // sous les boules et la neige en vol
        else { p.panel.orderFrontRegardless() }
        snowPanels[k] = p
        return p
    }

    private func removeSnowPanel(_ k: Int) {
        guard let p = snowPanels.removeValue(forKey: k) else { return }
        follower.detach(UInt32(k))
        p.panel.orderOut(nil)
    }

    func removeSnowPanels() { for k in Array(snowPanels.keys) { removeSnowPanel(k) } }

    /// Place la neige dans chaque bandeau (glissement, décollement) et recadre un bandeau qui ne couvre plus sa
    /// fenêtre. Le recadrage attend que la fenêtre soit immobile : pendant un geste, seul Follower touche au bandeau.
    private func placeSnowPanels() {
        let pad = SnowPanel.padX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, p) in snowPanels {
            guard let s = surfaces[k], let l = ledges[k] else { continue }
            if !follower.available {
                p.panel.setFrame(CGRect(x: s.x0 - pad, y: s.y - SnowPanel.below, width: s.x1 - s.x0 + 2 * pad, height: SnowPanel.height), display: false)
                l.resized = 0
            } else if clock - l.lastChange > 0.25, let e = follower.edge(UInt32(k)) {
                let width = p.panel.frame.width, need = e.inset + e.width + pad
                if abs(p.inset + l.resized - e.inset) > 0.5 || e.inset < pad - 0.5 || need > width + 0.5 || width > need + 300,
                   let inset = follower.frame(p.panel, on: UInt32(k), margin: l.s.margin) {
                    p.inset = inset
                    l.resized = 0
                }
            }
            let pos = CGPoint(x: p.inset + l.slide + l.resized, y: SnowPanel.below + l.lift)
            if p.shape.position != pos { p.shape.position = pos }
        }
        CATransaction.commit()
    }

    /// Verrouillage : toute la neige posée s'évapore (elle s'élève en voile et s'efface), on repart d'un écran nu.
    func evaporate(animated: Bool) {
        bare = true   // sinon les flocons encore en vol reposent des bouts de neige pendant l'animation
        for it in items { melt(it) }
        for g in grains { g.node.removeFromParent() }
        grains.removeAll()
        for (k, l) in ledges {
            if animated, let s = surfaces[k], l.mask.count == l.h.count, l.bed.count == l.h.count {
                for i in stride(from: 0, to: l.h.count, by: 3) where l.mask[i] && l.h[i] > 0.5 && motes.count < 900 {
                    let d = CGFloat.random(in: 4...9)
                    let node = SKSpriteNode(texture: flakeTexture, size: CGSize(width: d, height: d))
                    node.position = CGPoint(x: columnX(s, i), y: s.y + l.bed[i] + .random(in: 0...l.h[i]))
                    node.zPosition = 27
                    let alpha = CGFloat.random(in: 0.35...0.7)
                    node.alpha = alpha
                    addChild(node)
                    motes.append(Mote(node: node, vx: .random(in: -25...25), vy: .random(in: 90...260), age: 0,
                                      life: .random(in: 0.3...0.6), alpha: alpha))
                }
            }
            l.h = [CGFloat](repeating: 0, count: l.h.count)
            l.slide = 0; l.slideVel = 0; l.lift = 0; l.liftVel = 0
            if let p = snowPanels[k] {
                if animated { p.fadeOut { [weak self] in self?.dirty.insert(k) } }
                else { p.shape.removeAllAnimations(); p.shape.opacity = 1; dirty.insert(k) }
                continue
            }
            guard let node = shapes[k] else { continue }
            node.removeAllActions()
            if animated {
                node.run(.sequence([.fadeOut(withDuration: 0.3), .run { [weak self] in
                    self?.dirty.insert(k)
                    node.alpha = 1
                }]))
            } else {
                node.alpha = 1; node.yScale = 1
                dirty.insert(k)
            }
        }
        if !animated { redrawSnow(dirty) }
    }

    // MARK: Neige en vol

    /// La plus haute surface de neige traversée en tombant de `from` à `to` à l'abscisse `x`.
    private func landing(_ x: CGFloat, from: CGFloat, to: CGFloat) -> (k: Int, l: Ledge, c: Int)? {
        var hit: (k: Int, l: Ledge, c: Int)?
        var highest = -CGFloat.greatestFiniteMagnitude
        for (k, s) in surfaces where s.covers(x) {
            guard let l = ledges[k], l.bed.count == l.h.count, !l.h.isEmpty else { continue }
            let c = column(s, x, l.h.count)
            let surface = s.y + l.lift + l.bed[c] + l.h[c]
            if from >= s.y + l.lift + l.bed[c] && to <= surface && surface > highest {
                hit = (k, l, c)
                highest = surface
            }
        }
        return hit
    }

    private func addGrain(_ p: CGPoint, _ v: CGVector, area: CGFloat, size: CGFloat, lump: Bool) {
        let node = SKSpriteNode(texture: ballTexture, size: CGSize(width: size, height: size))
        node.position = p
        node.zPosition = lump ? 26 : 25
        addChild(node)
        grains.append(Grain(node: node, vx: v.dx, vy: v.dy, area: area, lump: lump))
    }

    /// Lâche de la neige en poudre. `scatter` fait varier la vitesse de chaque grain, pour qu'une plaque projetée
    /// se disloque au lieu de voler d'un seul bloc.
    private func release(_ area: CGFloat, at p: CGPoint, v: CGVector, spread: CGSize = CGSize(width: 1, height: 1), scatter: CGFloat = 0) {
        guard area > 0.02 else { return }
        guard grains.count < 1500 else { deposit(groundKey, p.x, area); return }
        let count = max(1, min(6, Int(area / 3)))
        let share = area / CGFloat(count)
        for _ in 0..<count {
            let f = 1 + CGFloat.random(in: -1...1) * scatter
            addGrain(CGPoint(x: p.x + .random(in: -spread.width...spread.width), y: p.y + .random(in: 0...max(spread.height, 0.01))),
                     CGVector(dx: v.dx * f + .random(in: -12...12) + 40 * scatter * .random(in: -1...1), dy: v.dy * f + .random(in: -10...8)),
                     area: share, size: min(5, max(1.6, share.squareRoot() * 1.05)), lump: false)
        }
    }

    /// Une motte tient ensemble en vol et part un instant avant la poudre autour d'elle.
    private func throwLump(_ area: CGFloat, at p: CGPoint, v: CGVector) {
        let pieces = Int(area / 90) + 1
        for _ in 0..<pieces where grains.count < 1500 {
            let share = area / CGFloat(pieces), f = 1 + CGFloat.random(in: -0.2...0.2)
            addGrain(CGPoint(x: p.x + .random(in: -2...2), y: p.y + .random(in: -1...1)),
                     CGVector(dx: v.dx * f + .random(in: -25...25), dy: v.dy * f + .random(in: -80...0)),
                     area: share, size: min(11, max(3, share.squareRoot() * 1.05)), lump: true)
        }
    }

    /// Nuage de poudreuse qui s'élève d'un point d'impact.
    private func puff(at p: CGPoint, size: CGFloat, force: CGFloat, drift: CGFloat = 0) {
        for _ in 0..<max(0, min(300 - motes.count, Int(2 + size * 0.6 * force))) {
            let angle = CGFloat.random(in: 0.15...(.pi - 0.15)), speed = CGFloat.random(in: 25...110) * force
            let d = (CGFloat.random(in: 0.3...0.6) * size + 1) * 2.2
            let node = SKSpriteNode(texture: flakeTexture, size: CGSize(width: d, height: d))
            node.position = CGPoint(x: p.x + .random(in: -0.5...0.5) * size, y: p.y + .random(in: 0...max(size * 0.4, 0.01)))
            node.zPosition = 27
            let alpha = CGFloat.random(in: 0.25...0.5)
            node.alpha = alpha
            addChild(node)
            motes.append(Mote(node: node, vx: cos(angle) * speed * 1.4 + drift * 0.2, vy: sin(angle) * speed * 0.6, age: 0,
                              life: .random(in: 0.45...0.9), alpha: alpha))
        }
    }

    /// Une motte touche la neige : l'essentiel s'y tasse, quelques miettes rebondissent, un voile de poudreuse s'élève.
    private func burst(_ g: Grain, on k: Int, _ l: Ledge, _ c: Int) {
        let p = g.node.position, size = g.node.size.width
        let impact = max(0, -g.vy), crumbs = g.area * 0.18
        for spot: CGFloat in [-0.3, 0, 0.3] { deposit(k, p.x + spot * size, (g.area - crumbs) / 3) }
        let surface = l.s.y + l.lift + l.bed[c] + l.h[c]
        release(crumbs, at: CGPoint(x: p.x, y: surface + 1), v: CGVector(dx: g.vx * 0.3, dy: impact * .random(in: 0.08...0.16)),
                spread: CGSize(width: size * 0.4, height: 1), scatter: 0.6)
        puff(at: CGPoint(x: p.x, y: surface), size: size, force: min(max(impact / 900, 0.35), 1.3), drift: g.vx)
    }

    private func stepGrains(_ dt: CGFloat) {
        let damping = exp(-0.8 * dt)
        for i in grains.indices.reversed() {
            var g = grains[i]
            g.vy -= gravity * dt
            g.vx *= damping
            g.vy *= damping
            let p = g.node.position
            let np = CGPoint(x: p.x + g.vx * dt, y: p.y + g.vy * dt)
            var gone = np.x < -10 || np.x > W + 10 || np.y < -10
            if !gone, g.vy <= 0, let hit = landing(np.x, from: p.y, to: np.y) {
                g.node.position = np
                if g.lump { burst(g, on: hit.k, hit.l, hit.c) } else { deposit(hit.k, np.x, g.area) }   // la neige rejoint le tas
                gone = true
            }
            if gone {   // retrait par échange avec le dernier : l'ordre ne compte pas, et c'est instantané
                g.node.removeFromParent()
                grains.swapAt(i, grains.count - 1)
                grains.removeLast()
            } else {
                g.node.position = np
                grains[i] = g
            }
        }
    }

    private func stepMotes(_ dt: CGFloat) {
        let damping = exp(-3.2 * dt), drift = breeze() * 0.4
        for i in motes.indices.reversed() {
            var m = motes[i]
            m.age += dt
            if m.age >= m.life {
                m.node.removeFromParent()
                motes.swapAt(i, motes.count - 1)
                motes.removeLast()
                continue
            }
            m.vy -= 35 * dt
            m.vx *= damping
            m.vy *= damping
            m.node.position.x += (m.vx + drift) * dt
            m.node.position.y += m.vy * dt
            m.node.alpha = m.alpha * (1 - m.age / m.life)
            motes[i] = m
        }
    }

    // MARK: Boules et bonhomme

    /// Affiche l'objet dans le bandeau `p`, à la position `pos` (coordonnées du bandeau), à la place de son nœud.
    private func host(_ it: Item, in p: SnowPanel, at pos: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if it.host !== p {
            it.unhost()
            let g = CALayer()
            g.contents = it.isMan ? manImage : ballImage   // pas SKTexture.cgImage() : couleurs et transparence faussées
            g.zPosition = 1
            p.panel.contentView?.layer?.addSublayer(g)
            it.ghost = g
            it.host = p
            it.node.isHidden = true
        }
        it.ghost?.bounds = CGRect(origin: .zero, size: it.node.size)
        it.ghost?.position = pos
        it.ghost?.setAffineTransform(CGAffineTransform(rotationAngle: it.node.zRotation))
        CATransaction.commit()
    }

    private func detach(_ it: Item) {
        it.unhost()
        items.removeAll { $0 === it }
        if dragging === it { dragging = nil }
    }

    /// La boule s'écrase : elle s'aplatit, sa neige part en poudre et en mottes, puis retombe en tas.
    private func splat(_ it: Item, vx: CGFloat) {
        detach(it)
        let p = it.node.position, base = p.y - it.halfH
        let area = .pi * it.r * it.r * 0.5 * (it.isMan ? 2.2 : 1)
        let sprays = max(3, Int(it.r / 2))
        for _ in 0..<sprays {
            release(area * 0.6 / CGFloat(sprays), at: CGPoint(x: p.x + .random(in: -it.halfW...it.halfW), y: base + .random(in: 1...it.halfH)),
                    v: CGVector(dx: vx + .random(in: -260...260), dy: .random(in: 120...520)), spread: CGSize(width: 2, height: 2), scatter: 0.3)
        }
        throwLump(area * 0.4, at: CGPoint(x: p.x, y: base + it.r * 0.6), v: CGVector(dx: vx, dy: .random(in: 180...360)))
        puff(at: CGPoint(x: p.x, y: base), size: it.r, force: 1.2, drift: vx)
        it.node.run(.sequence([.group([.scaleX(to: 1.7, y: 0.25, duration: 0.09),
                                       .moveBy(x: 0, y: -it.halfH * 0.75, duration: 0.09),
                                       .fadeOut(withDuration: 0.16)]), .removeFromParent()]))
    }

    private func melt(_ it: Item) {
        detach(it)
        it.node.run(.sequence([.group([.scale(to: 0.1, duration: 0.25), .fadeOut(withDuration: 0.25)]), .removeFromParent()]))
    }

    /// Un objet tient sur un rebord si celui-ci le porte des deux côtés de son centre. Au ras d'un bord, ou sur
    /// l'arrondi d'un coin, il est en porte-à-faux : il doit basculer, pas rester suspendu dans le vide.
    private func supports(_ s: Surface, _ x: CGFloat, _ it: Item) -> Bool {
        let m = max(it.r * 0.5, s.radius)   // le centre doit être au-delà de l'arrondi du coin
        return s.covers(x - m) && s.covers(x + m)
    }

    private func stepItems(_ dt: CGFloat) {
        var hosted: Set<ObjectIdentifier> = []
        defer { for it in items where it.ghost != nil && !hosted.contains(ObjectIdentifier(it)) { it.unhost() } }
        for it in items where it !== dragging {
            switch it.rest {
            case .surface(let k, var dx):
                guard let s = surfaces[k] else { it.rest = .none; continue }
                if k >= 0, let l = ledges[k], l.lift > 2 || l.agitation > shaking {   // fenêtre secouée : l'objet est éjecté
                    it.rest = .none
                    it.vx = l.trackVel.dx * 0.8
                    it.vy = max(l.trackVel.dy, 0) * 0.8 + 220
                    continue
                }
                if abs(it.vx) > 10 {   // la boule roule encore un peu avant de s'arrêter
                    dx += it.vx * dt
                    if !it.isMan { it.node.zRotation -= it.vx * dt / it.r }
                    it.vx *= exp(-2.5 * dt)
                    dx = min(max(dx, it.halfW - s.x0), W - it.halfW - s.x0)
                } else { it.vx = 0 }
                if supports(s, s.x0 + dx, it) {
                    it.rest = .surface(k, dx)
                    let lead = ledges[k]?.offset ?? .zero
                    it.node.position = CGPoint(x: s.x0 + dx + lead.dx, y: s.y + it.halfH + lead.dy)
                    if let p = snowPanels[k], let l = ledges[k] {
                        host(it, in: p, at: CGPoint(x: p.inset + l.resized + dx, y: SnowPanel.below + it.halfH))
                        hosted.insert(ObjectIdentifier(it))
                    }
                } else {   // bord atteint, fenêtre fermée ou recouverte : l'objet bascule du côté du vide et tombe
                    it.rest = .none
                    if abs(it.vx) < 40 { it.vx = s.covers(s.x0 + dx - it.r) ? 70 : -70 }
                }
            case .on(let b):
                if b !== dragging, !b.falling, items.contains(where: { $0 === b }) {
                    it.node.position = CGPoint(x: b.x, y: b.node.position.y + (b.r + it.r) * 0.8)
                    if let p = b.host, let g = b.ghost {   // empilée sur une boule elle-même portée par un bandeau
                        host(it, in: p, at: CGPoint(x: g.position.x, y: g.position.y + (b.r + it.r) * 0.8))
                        hosted.insert(ObjectIdentifier(it))
                    }
                } else { it.rest = .none }
            case .none:
                fall(it, dt)
            }
        }
    }

    private func fall(_ it: Item, _ dt: CGFloat) {
        it.vy -= gravity * dt
        it.vx *= 1 - min(1, 0.15 * dt)
        let p = it.node.position
        var nx = p.x + it.vx * dt
        if nx < it.halfW { nx = it.halfW; it.vx = abs(it.vx) * 0.5 }               // rebond sur les bords de l'écran
        else if nx > W - it.halfW { nx = W - it.halfW; it.vx = -abs(it.vx) * 0.5 }
        let oldB = p.y - it.halfH, newB = oldB + it.vy * dt
        var best: (y: CGFloat, x: CGFloat, rest: Item.Rest)?
        if it.vy <= 0 {
            for (k, s) in surfaces where supports(s, nx, it) && oldB >= s.y - 1 && newB <= s.y && s.y > (best?.y ?? -1) {
                best = (s.y, nx, .surface(k, nx - s.x0))
            }
            if !it.isMan {
                for b in items where b !== it && b !== dragging && !b.isMan && !b.falling
                    && abs(b.x - nx) < (b.r + it.r) * 0.6 {
                    let y = b.node.position.y + (b.r + it.r) * 0.8 - it.r
                    if oldB >= y - 1 && newB <= y && y > (best?.y ?? -1) { best = (y, b.x, .on(b)) }
                }
            }
            if best == nil && newB <= 0 { best = (0, nx, .surface(groundKey, nx)) }   // filet de sécurité : le sol
        }
        guard let hit = best else {
            it.node.position = CGPoint(x: nx, y: p.y + it.vy * dt)
            if !it.isMan { it.node.zRotation -= it.vx * dt / it.r }
            return
        }
        it.node.position = CGPoint(x: nx, y: hit.y + it.halfH)
        if hypot(it.vx, it.vy) > (it.thrown ? thrownSplatSpeed : splatSpeed) { splat(it, vx: it.vx * 0.3); return }
        it.thrown = false
        if -it.vy > 260 {   // choc moyen : rebond amorti, petit écrasement et un peu de poudreuse
            puff(at: CGPoint(x: nx, y: hit.y), size: it.r * 0.5, force: 0.5)
            it.vy = -it.vy * 0.3
            it.vx *= 0.75
            it.node.run(.sequence([.scaleX(to: 1.18, y: 0.8, duration: 0.06), .scaleX(to: 1, y: 1, duration: 0.12)]))
            return
        }
        it.vy = 0
        it.rest = hit.rest
        it.node.position.x = hit.x
        if it.isMan { it.vx = 0 }
        // trois boules empilées deviennent un bonhomme de neige
        if case .on(let mid) = it.rest, case .on(let base) = mid.rest {
            it.vx = 0
            let man = Item(r: min(max(base.r, 10), maxR), isMan: true)
            man.rest = base.rest
            man.node.position = CGPoint(x: base.x, y: base.node.position.y - base.r + man.halfH)
            for b in [it, mid, base] { detach(b); b.node.removeFromParent() }
            items.append(man)
            addChild(man.node)
        } else if case .on = it.rest { it.vx = 0 }
    }

    // MARK: Souris

    /// Le rebord (sol, fenêtre ou Dock) dont la neige se trouve sous le point ou tout près, s'il y en a assez.
    private func snowAt(_ p: CGPoint, minHeight: CGFloat) -> Int? {
        for (k, s) in surfaces where s.covers(p.x) {
            guard let l = ledges[k], !l.h.isEmpty else { continue }
            // le curseur vient de creuser la neige juste sous lui : on regarde celle qui reste tout autour
            let h = l.h[column(s, p.x - 30, l.h.count)...column(s, p.x + 30, l.h.count)].max() ?? 0
            let base = s.y + l.lift
            if h >= minHeight && p.y >= base - 2 && p.y <= base + max(h, 4) + 8 { return k }
        }
        return nil
    }

    /// La boule ramasse la neige du rebord `k` sur la distance parcourue `d`, jusqu'à la taille limite.
    private func grow(_ b: Item, _ d: CGFloat, at x: CGFloat, on k: Int) {
        guard let l = ledges[k], !l.h.isEmpty, b.r < maxR, d > 0 else { return }
        let h = l.h[column(l.s, x, l.h.count)]
        let floor: CGFloat = k == groundKey ? 1 : 0.3   // ce qui reste après le passage de la boule
        guard h > floor + 0.2 else { return }
        let dr = min(d * 0.035 * min(1, h / 4), maxR - b.r)
        b.r += dr
        for i in column(l.s, x - b.r, l.h.count)...column(l.s, x + b.r, l.h.count) {   // la neige ramassée disparaît
            l.h[i] = max(min(l.h[i], floor), l.h[i] - dr * 0.8)
        }
        dirty.insert(k)
    }

    private func stepDrag(_ dt: CGFloat) {
        guard let it = dragging, dt > 0.001 else { return }
        let p = it.node.position
        dragTrail.append((clock, p))
        dragTrail.removeAll { $0.t < clock - throwWindow }
        if !it.isMan, let k = snowAt(CGPoint(x: p.x, y: p.y - it.r), minHeight: 0) {
            grow(it, abs(p.x - lastDragPos.x), at: p.x, on: k)   // glisser une boule dans la neige la fait grossir
        }
        lastDragPos = p
    }

    /// Le curseur écarte la neige partout (sol, fenêtres, Dock) : il creuse son passage, pousse une partie de la
    /// neige sur le côté et, s'il va vite, en projette en l'air.
    private func sweep(_ mouse: CGPoint, _ dt: CGFloat) {
        let c = CGPoint(x: mouse.x + 4, y: mouse.y - 8)   // milieu de la flèche plutôt que sa pointe
        defer { cursor = c }
        guard let prev = cursor, dt > 0.001 else { return }
        let dx = c.x - prev.x, dy = c.y - prev.y, dist = hypot(dx, dy)
        var v = CGVector(dx: dx / dt, dy: dy / dt)
        let speed = hypot(v.dx, v.dy)
        if speed > 3000 { v = CGVector(dx: v.dx * 3000 / speed, dy: v.dy * 3000 / speed) }
        cursorVel = CGVector(dx: cursorVel.dx + (v.dx - cursorVel.dx) * 0.5, dy: cursorVel.dy + (v.dy - cursorVel.dy) * 0.5)
        guard dist > 0.3, dist < 400, dragging == nil else { return }
        let r: CGFloat = 10
        let steps = Int(dist / (r * 0.5)) + 1
        for (k, s) in surfaces {
            guard let l = ledges[k], l.bed.count == l.h.count,
                  max(c.y, prev.y) + r >= s.y + l.lift - s.radius, min(c.y, prev.y) - r <= s.y + l.lift + s.maxH + 8,
                  max(c.x, prev.x) + r >= s.x0, min(c.x, prev.x) - r <= s.x1 else { continue }
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                carve(k, l, at: CGPoint(x: prev.x + dx * t, y: prev.y + dy * t), v: v, travel: dist / CGFloat(steps), r: r)
            }
        }
    }

    private func carve(_ k: Int, _ l: Ledge, at p: CGPoint, v: CGVector, travel: CGFloat, r: CGFloat) {
        let s = l.s, n = l.h.count
        let lo = max(0, Int(((p.x - r - s.x0) / col).rounded(.down))), hi = min(n - 1, Int(((p.x + r - s.x0) / col).rounded(.down)))
        guard lo <= hi else { return }
        let local = p.y - (s.y + l.lift), speed = hypot(v.dx, v.dy)
        let spray = smoothstep(60, 420, speed)
        var pushedLeft: CGFloat = 0, pushedRight: CGFloat = 0
        for i in lo...hi where l.mask[i] {
            let x = columnX(s, i), off = x - p.x
            let reach = r * r - off * off
            guard reach > 0 else { continue }
            let half = reach.squareRoot()
            let bottom = max(0, local - half - l.bed[i]), top = local + half - l.bed[i]
            let h = l.h[i]
            guard top > bottom, h > bottom + 0.01 else { continue }
            // curseur enfoui sous la neige : il ne déplace que ce qu'il traverse, le reste repose dessus
            let removed = h > top ? (top - bottom) * min(1, travel / (2 * r)) : h - bottom
            guard removed > 0.001 else { continue }
            l.h[i] = h - removed
            dirty.insert(k)
            var area = removed * col
            if spray > 0, area * spray > 0.6, grains.count < 1500 {   // projeté en l'air dans le sens du geste
                let flung = area * spray
                let len = hypot(off, s.y + l.lift + l.bed[i] + h - p.y)
                let out = len > 0.001 ? CGVector(dx: off / len, dy: (s.y + l.lift + l.bed[i] + h - p.y) / len) : CGVector(dx: 0, dy: 1)
                let f = CGFloat.random(in: 0.55...1.25), o = speed * .random(in: 0.05...0.25)
                addGrain(CGPoint(x: x + .random(in: -1...1), y: s.y + l.lift + l.bed[i] + h - removed + .random(in: 0...2)),
                         CGVector(dx: v.dx * f + out.dx * o + .random(in: -30...30),
                                  dy: v.dy * f + out.dy * o + speed * .random(in: 0.02...0.2) + .random(in: -20...40)),
                         area: flung, size: min(4.2, max(1.6, flung.squareRoot() * 1.05)), lump: false)
                area -= flung
            }
            if (abs(v.dx) > 40 ? v.dx : off) < 0 { pushedLeft += area } else { pushedRight += area }
        }
        for (area, x) in [(pushedLeft, p.x - r - col * 3), (pushedRight, p.x + r + col * 3)] where area > 0 {
            if x > s.x0 && x < s.x1 { deposit(k, x, area) }   // le reste forme un bourrelet sur le côté
            else { release(area, at: CGPoint(x: x, y: s.y + l.lift), v: CGVector(dx: v.dx * 0.5, dy: 0)) }   // ou tombe du bord
        }
    }

    private func updateMouseCapture(_ p: CGPoint) {
        guard let window = view?.window else { return }
        // ne rien changer pendant un glisser-déposer d'une autre app
        if dragging == nil && NSEvent.pressedMouseButtons != 0 { return }
        // on ne capte les clics que sur un objet ou dans de la neige, là où une boule peut naître
        let want = dragging != nil || items.contains { $0.hit(p) } || snowAt(p, minHeight: 3) != nil
        if window.ignoresMouseEvents == want { window.ignoresMouseEvents = !want }
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        var found = items.last { $0.hit(p) }
        if found == nil, snowAt(p, minHeight: 3) != nil {
            // clic dans la neige (sol, fenêtre ou Dock) : une petite boule naît, à faire rouler dedans pour la grossir
            let ball = Item(r: minR, isMan: false)
            items.append(ball)
            addChild(ball.node)
            found = ball
        }
        guard let it = found else { return }
        dragging = it
        it.rest = .none
        it.vx = 0
        it.vy = 0
        it.node.zPosition = 30
        it.node.position = p
        lastDragPos = p
        it.thrown = false
        dragTrail = [(clock, p)]
    }

    override func mouseDragged(with event: NSEvent) {
        dragging?.node.position = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) { releaseDrag() }

    func releaseDrag() {
        guard let it = dragging else { return }
        dragging = nil
        it.node.zPosition = 20
        if !it.isMan, it.r < keepR { melt(it); return }   // pas assez roulée pour tenir : elle fond
        // L'élan vient du chemin parcouru par la main sur le dernier dixième de seconde, divisé par cette durée fixe :
        // un petit à-coup ne couvre presque pas de distance et ne donne donc presque pas de vitesse.
        guard let first = dragTrail.first else { return }
        let p = it.node.position
        var vx = (p.x - first.p.x) / throwWindow * 0.75, vy = (p.y - first.p.y) / throwWindow * 0.75
        let speed = hypot(vx, vy)
        if speed > 1700 { vx *= 1700 / speed; vy *= 1700 / speed }
        it.vx = vx
        it.vy = vy
        it.thrown = speed > 200
    }

    // MARK: Chasse-neige

    func sendPlough() {
        guard plough == nil else { return }
        let p = SKSpriteNode(texture: ploughTexture, size: ploughSize)
        p.position = CGPoint(x: W + 60, y: ploughSize.height / 2)
        p.zPosition = 15
        let path = CGMutablePath()   // tas de neige poussé devant la lame
        path.move(to: CGPoint(x: 6, y: 0))
        path.addQuadCurve(to: CGPoint(x: -22, y: 40), control: CGPoint(x: -2, y: 36))
        path.addQuadCurve(to: CGPoint(x: -78, y: 0), control: CGPoint(x: -40, y: 34))
        path.closeSubpath()
        let heap = SKShapeNode(path: path)
        heap.fillColor = SKColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)
        heap.strokeColor = .clear
        heap.position = CGPoint(x: -ploughSize.width / 2 + 6, y: -ploughSize.height / 2)
        heap.zPosition = -1
        heap.setScale(0.01)
        p.addChild(heap)
        addChild(p)
        plough = p
        pile = heap
        collected = 0
    }

    private func stepPlough(_ dt: CGFloat) {
        guard let p = plough else { return }
        let oldX = p.position.x - ploughSize.width / 2
        // Vitesse constante à l'écran : on avance d'un nombre entier d'images (une, ou plusieurs si certaines ont
        // sauté), pas du temps mesuré, qui varie de quelques ms d'une image à l'autre et faisait saccader.
        let frame = 1 / CGFloat(max(view?.preferredFramesPerSecond ?? 60, 30))
        p.position.x -= 130 * max(1, (dt / frame).rounded()) * frame
        let newX = p.position.x - ploughSize.width / 2
        if let l = ledges[groundKey], !l.h.isEmpty, newX < W, oldX > 0 {
            for i in column(l.s, newX, l.h.count)...column(l.s, oldX, l.h.count) where l.h[i] > 1.5 {
                collected += l.h[i] - 1.5
                l.h[i] = 1.5
            }
            dirty.insert(groundKey)
            urgent.insert(groundKey)   // redessiné à chaque image : au rythme habituel (une sur trois), la neige s'effaçait par à-coups derrière la lame
        }
        for it in items where it !== dragging {   // la lame percute ce qui est posé au sol : ça éclate vers l'avant
            if case .surface(groundKey, _) = it.rest, it.x >= newX - it.halfW, it.x <= oldX + 4 {
                collected += it.r * 5
                splat(it, vx: -260)
            }
        }
        // Le tas ne fait que grossir, à la mesure de ce qui a été ramassé : il n'est plein qu'après avoir traversé
        // tout un écran de neige épaisse (environ 10 pt), et reste petit s'il n'y en avait qu'une fine couche.
        if let pile {   // le tas grossit en douceur, sans saut quand la lame avale une congère ou une boule
            let target = max(0.01, min(1, sqrt(collected * col / (W * 10))))
            pile.setScale(pile.xScale + (target - pile.xScale) * min(1, dt * 4))
        }
        if p.position.x < -140 {
            p.removeFromParent()
            plough = nil
            pile = nil
        }
    }

    // MARK: Boucle

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(max(currentTime - clock, 0), 0.05))
        clock = currentTime
        guard W > 0, H > 0, dt > 0.001 else { return }
        tick += 1
        if spaceChanged { spaceChanged = false; lastSpaceChange = currentTime }
        if resumed {   // on reprend là où sont les fenêtres maintenant, sans y voir une secousse
            resumed = false
            bare = false
            for l in ledges.values { l.hidden = true }
        }
        if tick % 2 == 1 { dockRect = readDockRect() }   // assez souvent pour suivre l'animation du Dock
        if let (list, t) = fetchWindowList() {
            let gap = listTime > 0 ? CGFloat(t - listTime) : dt
            listTime = t
            refreshSurfaces(list, gap)
        }
        // La neige est dessinée là où la fenêtre sera à l'affichage de cette image, pas là où elle était au relevé :
        // sans cette avance, elle traînait d'une à deux images derrière une fenêtre qu'on déplace.
        // macOS ne publie pas la position d'une fenêtre à intervalles réguliers (un relevé sans mouvement, puis un
        // double) : on prolonge donc la droite qui passe par les 4 derniers relevés, pas le dernier écart, qui tremble.
        let now = CACurrentMediaTime()
        for l in ledges.values {
            l.offset = .zero
            guard l.hist.count >= 3, let a = l.hist.first, let b = l.hist.last, now - b.t < 0.1, b.t - a.t > 0.01 else { continue }
            let still = l.hist.suffix(3).allSatisfy { $0.x == b.x && $0.y == b.y }   // arrêtée : on se cale dessus
            if still { continue }
            let n = CGFloat(l.hist.count), span = CGFloat(b.t - a.t)
            let mt = l.hist.reduce(0) { $0 + $1.t } / Double(n)
            let ahead = CGFloat(now - mt) + 2 * dt   // jusqu'à l'affichage : rendu de cette image, puis composition par macOS
            let px = l.hist.reduce(0) { $0 + $1.x } / n + (b.x - a.x) / span * ahead
            let py = l.hist.reduce(0) { $0 + $1.y } / n + (b.y - a.y) / span * ahead
            l.offset = CGVector(dx: min(max(px - b.x, -40), 40), dy: min(max(py - b.y, -40), 40))
        }
        let mouse = mousePoint()
        sweep(mouse, dt)
        stepDrag(dt)
        for (k, l) in ledges where surfaces[k] != nil {
            if k >= 0 { carry(k, l, dt) }
            relax(k, l)
        }
        stepItems(dt)
        stepGrains(dt)
        stepMotes(dt)
        stepPlough(dt)
        redrawSnow(tick % 3 == 0 ? dirty : urgent)
        for (k, node) in shapes {   // la neige suit son support, décalée de son glissement et de son décollement
            if let s = surfaces[k], let l = ledges[k] { node.position = CGPoint(x: s.x0 + l.slide + l.offset.dx, y: s.y + l.lift + l.offset.dy) }
        }
        placeSnowPanels()
        follower.heartbeat()
        updateMouseCapture(mouse)
    }
}

// MARK: - Application

final class OverlayView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Fenêtre d'accueil du premier lancement : ce que fait Flocon, puis l'installation dans la barre des menus.
struct WelcomeView: View {
    let done: (Bool) -> Void   // appelé avec le choix « ouvrir au démarrage »
    @State private var page = 0
    @State private var atLogin = true
    private let features: [(symbol: String, title: String, text: String)] = [
        ("snowflake", "Il neige sur votre bureau", "Les flocons tombent derrière vos fenêtres, portés par le vent, sans jamais gêner votre travail."),
        ("macwindow", "La neige se pose partout", "Elle s'accumule sur vos fenêtres, vos widgets, le Dock et le bas de l'écran."),
        ("hand.draw", "Elle réagit à vos gestes", "Balayez-la avec le curseur, secouez une fenêtre pour la faire tomber, rétrécissez-la et la neige bascule dans le vide."),
        ("circle.circle", "Boules et bonhomme de neige", "Cliquez dans la neige pour former une boule, faites-la rouler pour la grossir, lancez-la. Trois boules empilées deviennent un bonhomme."),
        ("truck.box", "Le chasse-neige", "Trop de neige ? Envoyez le chasse-neige : il traverse l'écran et dégage le sol."),
        ("moon.zzz", "Discret", "Flocon se met en pause quand l'écran dort ou se verrouille, et la neige s'évapore quand vous le désactivez."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            if page == 0 {
                Text("Bienvenue dans Flocon").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(features, id: \.title) { f in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: f.symbol).font(.title2).foregroundStyle(.blue).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.headline)
                                Text(f.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                Button("Continuer") { page = 1 }.keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Text("Flocon se range dans la barre des menus").font(.title.bold()).multilineTextAlignment(.center)
                Text("Pas d'icône dans le Dock ni de fenêtre ouverte : juste un flocon ❄ en haut à droite de l'écran. Cliquez dessus pour choisir Neige ou Forte neige, envoyer le chasse-neige, désactiver Flocon ou le quitter.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Toggle("Ouvrir Flocon au démarrage du Mac", isOn: $atLogin).padding(.vertical, 6)
                Button("Ajouter à la barre des menus") { done(atLogin) }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 540)
    }
}

final class Settings: ObservableObject {
    @Published var enabled = true
    @Published var intensity = 0.6   // cadence de la neige, de 0 (quelques flocons) à 1 (tempête)
    @Published var atLogin = false
    @Published var loginPending = false   // inscrit, mais macOS attend l'accord de l'utilisateur dans Réglages Système
}

/// Interrupteur dessiné à la main : dans un menu, celui du système reste gris même allumé (fenêtre jugée inactive).
struct SnowSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color(red: 0.2, green: 0.55, blue: 1) : Color.gray.opacity(0.45))
            .frame(width: 46, height: 26)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(radius: 1, y: 1).padding(3)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "activé" : "désactivé")
    }
}

/// Panneau de réglages qui s'ouvre sous le flocon de la barre des menus.
struct MenuView: View {
    @ObservedObject var settings: Settings
    let setEnabled: (Bool) -> Void, setIntensity: (Double) -> Void, setLogin: (Bool) -> Void
    let plough: () -> Void, about: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Flocon").font(.headline)
                Spacer()
                Toggle("Neige", isOn: Binding(get: { settings.enabled }, set: setEnabled)).toggleStyle(SnowSwitch()).labelsHidden()
            }
            Group {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cadence de la neige").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "snowflake").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { settings.intensity }, set: setIntensity), in: 0...1)
                            .accessibilityLabel("Cadence de la neige")
                        Image(systemName: "snowflake").font(.title3).foregroundStyle(.blue)
                    }
                }
                Button(action: plough) {
                    // fond peint à la main : dans un menu, le bouton coloré du système vire au gris
                    Label("Envoyer le chasse-neige", systemImage: "truck.box.fill")
                        .font(.body.weight(.medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color(red: 0.96, green: 0.6, blue: 0.2), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.45)
            Divider()
            Toggle("Ouvrir au démarrage du Mac", isOn: Binding(get: { settings.atLogin }, set: setLogin))
            if settings.loginPending {
                Text("macOS attend votre accord : activez Flocon dans Réglages Système › Général › Ouverture.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Présentation…", action: about)
                Spacer()
                Button("Quitter Flocon") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            Text("Flocon \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 290)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let menu = NSMenu()
    private var menuHost: NSView?
    private var welcome: NSWindow?
    private var statusItem: NSStatusItem!
    private var panels: [NSPanel] = []     // [arrière : flocons, sous le Dock : sa neige, avant : neige posée et objets]
    private var views: [SKView] = []
    private let scene = SnowScene()
    private var mode = 1           // 0 = désactivé, 1 = il neige
    private var revealed = false   // les calques ont été montrés une première fois
    private var flakeCount: Int { Int(80 + settings.intensity * 820) }
    private var asleep = false     // écran en veille
    private var inactive = false   // session passée à un autre utilisateur
    private var locked = false     // écran verrouillé
    private var locking = false    // évaporation en cours avant l'arrêt

    private func makePanel(_ level: NSWindow.Level, _ view: SKView, _ content: SKScene) {
        let panel = overlayPanel(level)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        content.backgroundColor = .clear
        content.scaleMode = .resizeFill
        panel.contentView = view
        panels.append(panel)
        views.append(view)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ouverte depuis Téléchargements, une app non vérifiée tourne dans une copie temporaire en lecture seule :
        // l'ouverture au démarrage n'y fonctionne pas et rien n'est retrouvé au lancement suivant.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Déplacez Flocon dans le dossier Applications"
            alert.informativeText = "Glissez Flocon dans votre dossier Applications, puis ouvrez-le depuis là."
            alert.addButton(withTitle: "Quitter")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // flocons juste au-dessus du fond d'écran, donc derrière toutes les fenêtres, le Dock et les icônes du bureau
        makePanel(NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1), SKView(), scene.back)
        // neige posée, boules et chasse-neige au-dessus des fenêtres, sous les menus déroulants
        // neige du Dock : au-dessus des fenêtres mais sous le Dock, pour que ses icônes restent au premier plan
        makePanel(NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1), SKView(), scene.dockLayer)
        makePanel(.statusBar, OverlayView(), scene)
        for panel in panels { panel.alphaValue = 0 }   // invisibles tant que rien n'y est dessiné, voir setMode
        layout()
        views[0].presentScene(scene.back)
        views[1].presentScene(scene.dockLayer)
        views[2].presentScene(scene)

        settings.intensity = UserDefaults.standard.object(forKey: "cadence") as? Double ?? 0.6
        // un menu dont l'unique élément est le panneau : il s'accroche sous le flocon comme un menu ordinaire
        let host = NSHostingView(rootView: MenuView(
            settings: settings,
            setEnabled: { [weak self] in self?.setMode($0 ? 1 : 0) },
            setIntensity: { [weak self] value in
                guard let self else { return }
                self.settings.intensity = value
                UserDefaults.standard.set(value, forKey: "cadence")
                if self.mode != 0 { self.scene.setFlakeCount(self.flakeCount) }
            },
            setLogin: { [weak self] on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSAlert(error: error).runModal()
                }
                self?.refreshLogin()
                if on, SMAppService.mainApp.status == .requiresApproval {   // macOS veut l'accord de l'utilisateur
                    self?.menu.cancelTracking()
                    SMAppService.openSystemSettingsLoginItems()
                }
            },
            plough: { [weak self] in self?.menu.cancelTracking(); self?.scene.sendPlough() },
            about: { [weak self] in self?.menu.cancelTracking(); self?.showWelcome() }))
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        menu.delegate = self
        menuHost = host
        // premier lancement : on accueille d'abord, l'icône de la barre des menus arrive à la fin de la présentation
        if UserDefaults.standard.bool(forKey: "accueilli") { installStatusItem() } else { showWelcome() }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scene.spaceChanged = true
        }
        // rien à montrer quand l'écran dort ou que la session n'est plus à l'écran : on arrête tout calcul et tout dessin
        for (name, change) in [(NSWorkspace.screensDidSleepNotification, { (d: AppDelegate) in d.asleep = true }),
                               (NSWorkspace.screensDidWakeNotification, { d in d.asleep = false }),
                               (NSWorkspace.sessionDidResignActiveNotification, { d in d.inactive = true }),
                               (NSWorkspace.sessionDidBecomeActiveNotification, { d in d.inactive = false })] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                change(self)
                if self.asleep || self.inactive { self.scene.evaporate(animated: false) }   // au retour : pas de neige
                self.applyPause()
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.locked, !self.locking else { return }
            self.locking = true
            self.scene.evaporate(animated: true)
            // on laisse l'évaporation se jouer avant de tout arrêter
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard self.locking else { return }   // déverrouillé entre-temps
                self.locking = false
                self.scene.evaporate(animated: false)
                self.locked = true
                self.applyPause()
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.scene.bare = false
            self?.locking = false
            self?.locked = false
            self?.applyPause()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
        setMode(UserDefaults.standard.object(forKey: "mode") as? Int ?? 1)
        // Tests automatiques : lancée avec --pilote, l'app obéit à des ordres envoyés de l'extérieur (voir .github/workflows)
        if CommandLine.arguments.contains("--pilote") {
            distributed.addObserver(forName: .init("com.yessen.flocon.pilote"), object: nil, queue: .main) { [weak self] note in
                switch note.object as? String {
                case "chasse": self?.scene.sendPlough()
                case "off": self?.setMode(0)
                case "on": self?.setMode(1)
                default: break
                }
            }
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Flocon")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        if statusItem.button?.image == nil { statusItem.button?.title = "❄" }
        statusItem.menu = menu
    }

    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        settings.atLogin = status == .enabled
        settings.loginPending = status == .requiresApproval
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLogin()
        menuHost?.layoutSubtreeIfNeeded()
        if let size = menuHost?.fittingSize { menuHost?.setFrameSize(size) }
    }

    @objc private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView { [weak self] atLogin in
                if atLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
                self?.welcome?.close()
                // macOS veut souvent l'accord de l'utilisateur : on l'amène au bon réglage plutôt que d'échouer en silence
                if atLogin, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }))
            window.styleMask = [.titled, .closable]
            window.title = "Flocon"
            window.isReleasedWhenClosed = false
            window.delegate = self
            welcome = window
        }
        // Au centre exact de l'écran. La fenêtre n'a pas encore de taille tant qu'elle n'est pas affichée : on lui donne
        // d'abord celle de son contenu, sinon elle était centrée vide puis grandissait vers le bas et finissait en haut.
        if let window = welcome, let screen = NSScreen.main ?? NSScreen.screens.first {
            if let size = window.contentViewController?.view.fittingSize { window.setContentSize(size) }
            let area = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        welcome?.makeKeyAndOrderFront(nil)
    }

    /// Présentation terminée ou fenêtre fermée : dans tous les cas l'icône s'installe, sinon l'app serait injoignable.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "accueilli")
        installStatusItem()
        welcome = nil
    }

    // shortcut: neige sur l'écran principal seulement ; un calque par écran si le multi-écran devient utile
    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        for panel in panels { panel.setFrame(screen.frame, display: true) }
        scene.size = screen.frame.size
        scene.back.size = screen.frame.size
        scene.dockLayer.size = screen.frame.size
        scene.menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        scene.dockTop = screen.visibleFrame.minY - screen.frame.minY
    }

    private func setMode(_ mode: Int) {
        let mode = mode == 0 ? 0 : 1
        self.mode = mode
        UserDefaults.standard.set(mode, forKey: "mode")
        settings.enabled = mode != 0
        if mode == 0 {
            // la neige posée s'évapore et les flocons s'effacent, puis seulement on arrête tout
            scene.releaseDrag()
            scene.evaporate(animated: true)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.5; panels[0].animator().alphaValue = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                guard self.mode == 0 else { return }   // réactivée entre-temps
                scene.evaporate(animated: false)       // au retour : aucun tas, la neige repart de zéro
                scene.removeSnowPanels()
                panels[2].ignoresMouseEvents = true
                for view in views { view.isPaused = true }
                for panel in panels { panel.orderOut(nil) }
                panels[0].alphaValue = 1
            }
        } else {
            scene.bare = false
            if revealed { panels[0].alphaValue = 1 }
            layout()
            scene.setFlakeCount(flakeCount)
            applyPause()
            for panel in panels { panel.orderFrontRegardless() }
            if !revealed {
                // Au lancement, une vue SpriteKit affiche un fond blanc le temps de produire sa première image :
                // les calques restent invisibles pendant ce temps, puis apparaissent en fondu.
                revealed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.5; for panel in panels { panel.animator().alphaValue = 1 } }
                }
            }
        }
    }

    private func applyPause() {
        let paused = mode == 0 || asleep || inactive || locked
        if paused {
            scene.releaseDrag()
            panels[2].ignoresMouseEvents = true
        } else if views.contains(where: { $0.isPaused }) {
            scene.resumed = true
        }
        for view in views { view.isPaused = paused }
    }

}

// Diagnostic pour tester sur d'autres Mac : ce que cette machine offre à Flocon. Usage : Flocon --diag
if CommandLine.arguments.contains("--diag") {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
    let chip = "puce Apple"
    #else
    let chip = "Intel"
    #endif
    print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion), \(chip)")
    _ = NSApplication.shared   // ouvre la connexion au serveur de fenêtres
    for name in ["SLSMainConnectionID", "SLSGetDockRectWithReason", "SLSGetWindowBounds", "SLSMoveWindow"] {
        print(name, dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil ? "présente" : "ABSENTE")
    }
    print("rectangle du Dock :", readDockRect().map { "\($0)" } ?? "indisponible", "(code de retour \(dockCallResult))")
    print("suivi direct des fenêtres :", Follower().available ? "disponible" : "indisponible (repli plus lent)")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    func same(_ a: [(CGFloat, CGFloat)], _ b: [(CGFloat, CGFloat)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
    precondition(same(subtract(0, 100, []), [(0, 100)]))
    precondition(same(subtract(0, 100, [(40, 60)]), [(0, 40), (60, 100)]))
    precondition(same(subtract(0, 100, [(-10, 30), (90, 200)]), [(30, 90)]))
    precondition(same(subtract(0, 100, [(0, 100)]), []))
    precondition(same(subtract(0, 100, [(5, 100)]), []))          // reste < 8 pt : ignoré
    precondition(same(subtract(50, 10, []), []))                  // fenêtre hors écran

    // redimensionnement : la neige reste en place à l'écran, ce qui dépasse tombe
    let sc = SnowScene()
    sc.size = CGSize(width: 100, height: 100)
    func surf(_ a: CGFloat, _ b: CGFloat) -> Surface { Surface(x0: a, x1: b, y: 50, visible: [(a, b)], maxH: 12) }
    let l = Ledge(surf(0, 30), h: [CGFloat](repeating: 5, count: 10), now: 0)
    sc.resize(0, l, to: surf(7, 30))       // bord gauche rentré de 7 pt : 2 colonnes tombent, 1 pt de décalage reste
    precondition(l.h.count == 8 && l.h.allSatisfy { $0 == 5 } && abs(l.slide + 1) < 1e-9)
    sc.resize(0, l, to: surf(7, 21))       // bord droit rentré : 3 colonnes tombent
    precondition(l.h.count == 5 && l.h.allSatisfy { $0 == 5 })
    sc.resize(0, l, to: surf(2, 21))       // bord gauche ressorti : place vide à gauche, la neige ne bouge pas
    precondition(l.h == [0, 5, 5, 5, 5, 5, 0] && abs(l.slide - 1) < 1e-9)
    print("selftest ok")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
