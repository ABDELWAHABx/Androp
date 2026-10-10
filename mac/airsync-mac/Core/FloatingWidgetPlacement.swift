import Foundation

/// Keeps the widget reachable when a saved display is unplugged or rearranged.
enum FloatingWidgetPlacement {
    static func frame(_ frame: CGRect, visibleScreens: [CGRect]) -> CGRect {
        let screens = visibleScreens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let fallback = screens.first else { return frame }
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return frame }
        let target = screens.max { intersectionArea(frame, $0) < intersectionArea(frame, $1) } ?? fallback
        let screen = intersectionArea(frame, target) > 0 ? target : fallback
        var origin = frame.origin
        if !origin.x.isFinite || !origin.y.isFinite || intersectionArea(frame, screen) == 0 {
            origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - frame.width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - frame.height))
        return CGRect(origin: origin, size: frame.size)
    }

    private static func intersectionArea(_ frame: CGRect, _ screen: CGRect) -> CGFloat {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { return 0 }
        let overlap = frame.intersection(screen)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
