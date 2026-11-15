// Fait glisser la souris de (x0,y) à (x1,y), en points depuis le coin haut gauche, comme une main qui roule une boule.
// Un y négatif se compte depuis le bas de l'écran. Usage : swift ci/souris.swift x0 x1 y
import CoreGraphics
import Foundation
var a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
precondition(a.count == 3, "usage : souris x0 x1 y")
if a[2] < 0 { a[2] += Double(CGDisplayBounds(CGMainDisplayID()).height) }
func post(_ type: CGEventType, _ x: Double) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: a[2]), mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(15_000)
}
post(.mouseMoved, a[0]); usleep(400_000)   // le temps que Flocon commence à capter les clics à cet endroit
post(.leftMouseDown, a[0])
for _ in 0..<3 {   // trois allers-retours dans la neige pour grossir la boule
    for x in stride(from: a[0], through: a[1], by: 12) { post(.leftMouseDragged, x) }
    for x in stride(from: a[1], through: a[0], by: -12) { post(.leftMouseDragged, x) }
}
post(.leftMouseUp, a[0])
