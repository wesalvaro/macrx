import Testing
import Foundation
@testable import MacrxCore

@Suite struct NavigationTests {
    typealias C = Navigation.Candidate<String>

    @Test func PicksOverlappingNeighborOverCloserNonOverlapping() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cands = [
            C(id: "far-overlap", frame: CGRect(x: 300, y: 0, width: 100, height: 100)),
            C(id: "near-nooverlap", frame: CGRect(x: 100, y: 200, width: 100, height: 100)),
        ]
        #expect(Navigation.neighbor(from: origin, dir: .right, among: cands)?.id == "far-overlap")
    }

    @Test func PrefersNearestThenMostOverlap() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cands = [
            C(id: "a", frame: CGRect(x: 100, y: 0, width: 100, height: 30)),
            C(id: "b", frame: CGRect(x: 100, y: 30, width: 100, height: 70)),
            C(id: "c", frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
        ]
        #expect(Navigation.neighbor(from: origin, dir: .right, among: cands)?.id == "b")
    }

    @Test func IgnoresCandidatesBehind() {
        let origin = CGRect(x: 100, y: 0, width: 100, height: 100)
        let cands = [C(id: "left", frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        #expect(Navigation.neighbor(from: origin, dir: .right, among: cands) == nil)
        #expect(Navigation.neighbor(from: origin, dir: .left, among: cands)?.id == "left")
    }

    @Test func VerticalAndFallbackToNearestCenter() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cands = [
            C(id: "below-offset", frame: CGRect(x: 500, y: 100, width: 100, height: 100)),
            C(id: "below-closer", frame: CGRect(x: 150, y: 100, width: 100, height: 100)),
        ]
        #expect(Navigation.neighbor(from: origin, dir: .down, among: cands)?.id == "below-closer")
    }

    @Test func AcrossDisplays() {
        // Two displays side by side; focus on right edge of left display.
        let origin = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let cands = [C(id: "second", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))]
        #expect(Navigation.neighbor(from: origin, dir: .right, among: cands)?.id == "second")
    }
}
