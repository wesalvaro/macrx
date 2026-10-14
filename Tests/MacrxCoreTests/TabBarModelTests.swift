import Testing
import Foundation
@testable import MacrxCore

@Suite struct TitleCleanerTests {
    @Test func stripsChromeProfileAndApp() {
        #expect(TitleCleaner.clean("macross - Google Search - Google Chrome - Wes (google.com)", appName: "Google Chrome") == "macross - Google Search")
        #expect(TitleCleaner.clean("New Tab - Google Chrome - Wes (google.com)", appName: "Google Chrome") == "New Tab")
    }
    @Test func stripsPlainAppSuffixWithVariousDashes() {
        #expect(TitleCleaner.clean("README.md — Code", appName: "Code") == "README.md")
        #expect(TitleCleaner.clean("general | Slack", appName: "Slack") == "general")
        #expect(TitleCleaner.clean("Inbox - Mail", appName: "Mail") == "Inbox")
    }
    @Test func keepsTitlesThatMerelyContainTheAppName() {
        #expect(TitleCleaner.clean("Google Chrome Help", appName: "Google Chrome") == "Google Chrome Help")
        #expect(TitleCleaner.clean("Screen & System Audio Recording", appName: "System Settings") == "Screen & System Audio Recording")
    }
    @Test func fallsBackToAppName() {
        #expect(TitleCleaner.clean("", appName: "Calculator") == "Calculator")
        #expect(TitleCleaner.clean(" - Calculator", appName: "Calculator") == "Calculator")
        #expect(TitleCleaner.clean("", appName: nil) == "Untitled")
    }
}

@Suite struct TabLayoutTests {
    @Test func growsEvenlyUpToMax() {
        let w = TabLayout.widths(natural: [100, 100], available: 1000, minWidth: 80, maxWidth: 280)
        #expect(w == [280, 280])
        let w2 = TabLayout.widths(natural: [100, 200], available: 400, minWidth: 80, maxWidth: 280)
        #expect(w2 == [150, 250])
    }
    @Test func shrinksProportionallyDownToMin() {
        let w = TabLayout.widths(natural: [200, 400], available: 300, minWidth: 80, maxWidth: 280)
        #expect(w.reduce(0, +) <= 301)
        #expect(w[0] < w[1])
        #expect(w.allSatisfy { $0 >= 80 })
    }
    @Test func fallsBackToEqualSplitWhenEvenMinDoesNotFit() {
        let w = TabLayout.widths(natural: [300, 300, 300, 300], available: 200, minWidth: 80, maxWidth: 280)
        #expect(w == [50, 50, 50, 50])
    }
    @Test func rectsAreContiguous() {
        let r = TabLayout.rects(widths: [100, 50], in: CGRect(x: 10, y: 0, width: 150, height: 26))
        #expect(r[0] == CGRect(x: 10, y: 0, width: 100, height: 26))
        #expect(r[1] == CGRect(x: 110, y: 0, width: 50, height: 26))
    }
}
