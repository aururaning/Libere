import Foundation

/// Admission to the view hierarchy only; document frames, anchors and ink stay intact.
public enum CanvasVisibility {
    public static func region(around viewport: Rect) -> Rect? {
        guard [viewport.x, viewport.y, viewport.width, viewport.height].allSatisfy(\.isFinite),
              viewport.width > 0, viewport.height > 0 else { return nil }
        let horizontal = max(256, viewport.width * 0.75)
        let vertical = max(256, viewport.height * 0.75)
        return Rect(viewport.x - horizontal, viewport.y - vertical,
                    viewport.width + 2 * horizontal, viewport.height + 2 * vertical)
    }

    public static func blocks(_ blocks: [Block], in region: Rect, retaining ids: Set<UUID> = []) -> [Block] {
        blocks.filter { ids.contains($0.id) || $0.visibleFrame.intersects(region, gap: 44) }
    }
}
