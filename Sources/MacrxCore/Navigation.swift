import Foundation
import CoreGraphics

/// Directional neighbor search over rectangles.
public enum Navigation {
    public struct Candidate<ID> {
        public let id: ID
        public let frame: CGRect
        public init(id: ID, frame: CGRect) { self.id = id; self.frame = frame }
    }

    /// Finds the best candidate lying in direction `dir` from `origin`.
    ///
    /// A candidate qualifies if its near edge is at or beyond `origin`'s far edge
    /// (with 1pt tolerance). Candidates that overlap `origin` on the perpendicular axis
    /// are preferred, ranked by distance then overlap; otherwise the nearest by center distance.
    public static func neighbor<ID>(
        from origin: CGRect, dir: Direction, among candidates: [Candidate<ID>]
    ) -> Candidate<ID>? {
        let tolerance: CGFloat = 1
        let originEdge = origin.edge(dir)

        func distance(_ r: CGRect) -> CGFloat {
            let near = r.edge(dir.opposite)
            return dir.isForward ? near - originEdge : originEdge - near
        }

        let beyond = candidates.filter { distance($0.frame) >= -tolerance }
        guard !beyond.isEmpty else { return nil }

        let overlapping = beyond.filter { origin.perpendicularOverlap(with: $0.frame, for: dir.orientation) > 0 }
        if !overlapping.isEmpty {
            return overlapping.min { a, b in
                let da = distance(a.frame), db = distance(b.frame)
                if abs(da - db) > tolerance { return da < db }
                return origin.perpendicularOverlap(with: a.frame, for: dir.orientation)
                    > origin.perpendicularOverlap(with: b.frame, for: dir.orientation)
            }
        }
        return beyond.min { a, b in
            centerDistance(origin, a.frame) < centerDistance(origin, b.frame)
        }
    }

    private static func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
