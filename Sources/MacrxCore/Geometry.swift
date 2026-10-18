import Foundation
import CoreGraphics

/// Axis along which a split container lays out its children.
public enum Orientation: String, Sendable, Codable, Equatable {
    case horizontal  // children side by side (left → right)
    case vertical    // children top to bottom

    public var toggled: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}

/// A screen direction. All geometry in MacrxCore uses the Accessibility
/// coordinate space: origin at the top-left of the primary display, y grows downward.
public enum Direction: String, Sendable, CaseIterable, Equatable {
    case left, right, up, down

    public var orientation: Orientation {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// `true` for the direction of increasing coordinate (right / down).
    public var isForward: Bool {
        self == .right || self == .down
    }

    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

extension CGRect {
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Coordinate of the edge of this rect facing `dir`.
    public func edge(_ dir: Direction) -> CGFloat {
        switch dir {
        case .left: return minX
        case .right: return maxX
        case .up: return minY
        case .down: return maxY
        }
    }

    /// Length of the overlap between the two rects along the axis perpendicular to `orientation`.
    /// For a horizontal relationship (left/right neighbors) this is the vertical overlap.
    public func perpendicularOverlap(with other: CGRect, for orientation: Orientation) -> CGFloat {
        switch orientation {
        case .horizontal:
            return max(0, min(maxY, other.maxY) - max(minY, other.minY))
        case .vertical:
            return max(0, min(maxX, other.maxX) - max(minX, other.minX))
        }
    }

    /// Splits the rect along `orientation` into pieces proportional to `weights`.
    /// Pixel-snaps boundaries so adjacent pieces share edges exactly.
    public func split(_ orientation: Orientation, weights: [CGFloat]) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return weights.map { _ in self } }
        let length = orientation == .horizontal ? width : height
        return split(orientation, lengths: weights.map { length * $0 / total })
    }

    /// Splits the rect along `orientation` into pieces of the given absolute lengths.
    /// Boundaries are pixel-snapped; if the lengths add up to the rect's extent the last piece
    /// absorbs the rounding, otherwise the shortfall is left empty at the end.
    public func split(_ orientation: Orientation, lengths: [CGFloat]) -> [CGRect] {
        guard !lengths.isEmpty else { return [] }
        let length = orientation == .horizontal ? width : height
        var result: [CGRect] = []
        var acc: CGFloat = 0
        var start: CGFloat = 0
        for (i, l) in lengths.enumerated() {
            acc += l
            let isLast = i == lengths.count - 1
            let end = (isLast && abs(acc - length) < 1) ? length : min(length, acc.rounded())
            switch orientation {
            case .horizontal:
                result.append(CGRect(x: minX + start, y: minY, width: max(0, end - start), height: height))
            case .vertical:
                result.append(CGRect(x: minX, y: minY + start, width: width, height: max(0, end - start)))
            }
            start = end
        }
        return result
    }
}
