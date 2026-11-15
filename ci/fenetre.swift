// Fenêtre de test qui obéit à des ordres (ci/ordre.sh flocon.test.fenetre "…"), sans aucune autorisation à demander :
//   "x haut largeur hauteur" la déplace (haut compté depuis le haut de l'écran), "nouvelle" en ouvre une 2e, "ferme" ferme la 1re.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
func open(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "Fenêtre de test"
    win.isReleasedWhenClosed = false
    windows.append(win)
    place(win, x, top, w, h)
    win.orderFrontRegardless()
}
func place(_ win: NSWindow, _ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    win.setFrame(CGRect(x: x, y: NSScreen.screens[0].frame.height - top - h, width: w, height: h), display: true)
}
open(200, 150, 500, 350)
DistributedNotificationCenter.default().addObserver(forName: .init("flocon.test.fenetre"), object: nil, queue: .main) { note in
    let order = note.object as? String ?? ""
    let n = order.split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
    if order == "nouvelle" { open(620, 300, 300, 250) }
    else if order == "ferme", !windows.isEmpty { windows.removeFirst().close() }   // la suivante devient la 1re
    else if n.count == 4, let win = windows.first { place(win, n[0], n[1], n[2], n[3]) }
}
app.run()
