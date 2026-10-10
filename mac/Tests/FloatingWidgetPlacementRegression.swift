import Foundation

@main
struct FloatingWidgetPlacementRegression {
    static func main() {
        let laptop = CGRect(x: 0, y: 40, width: 1440, height: 820)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let valid = CGRect(x: 150, y: 200, width: 300, height: 200)
        expect(FloatingWidgetPlacement.frame(valid, visibleScreens: [laptop]) == valid, "valid saved position remains unchanged")
        let unplugged = CGRect(x: 2700, y: 100, width: 300, height: 200)
        let restored = FloatingWidgetPlacement.frame(unplugged, visibleScreens: [laptop])
        expect(laptop.contains(restored), "removed external display restores onto laptop")
        expect(FloatingWidgetPlacement.frame(unplugged, visibleScreens: [laptop, external]) == unplugged, "connected external display preserves saved position")
        let offEdge = CGRect(x: 1350, y: 800, width: 300, height: 200)
        expect(laptop.contains(FloatingWidgetPlacement.frame(offEdge, visibleScreens: [laptop])), "title bar and controls remain reachable at screen edge")
        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftFrame = CGRect(x: -900, y: 150, width: 300, height: 200)
        expect(FloatingWidgetPlacement.frame(leftFrame, visibleScreens: [laptop, leftDisplay]) == leftFrame, "negative display coordinates remain valid")
        expect(FloatingWidgetPlacement.frame(valid, visibleScreens: []) == valid, "temporary display enumeration loss is harmless")
        let corrupt = CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: 300, height: 200)
        expect(laptop.contains(FloatingWidgetPlacement.frame(corrupt, visibleScreens: [laptop])), "non-finite restored origin is repaired")
        print("Floating widget placement: 7 checks passed")
    }

    private static func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
}
