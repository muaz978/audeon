import XCTest
import CoreGraphics
@testable import Audeon

/// Covers the pure decision rules behind fixes that are otherwise only
/// observable with real audio hardware attached.
final class RestoreOrderTests: XCTestCase {
    private let anything: (String) -> Bool = { _ in true }

    func testRememberedOutputComesFirst() {
        let order = MixerStore.restoreOrder(
            remembered: "usb-headphones",
            plainCardUIDs: ["speakers", "hdmi"],
            groupMemberUIDs: [],
            deviceUIDs: ["speakers"],
            isUsable: anything)
        XCTAssertEqual(order.first, "usb-headphones")
    }

    func testUnusableCandidatesAreExcluded() {
        // The capture sink and a synthetic Output Group uid both resolve to
        // nothing CoreAudio will accept as a default output.
        let usable: (String) -> Bool = { $0 != "BlackHole2ch" && !$0.hasPrefix("group:") }
        let order = MixerStore.restoreOrder(
            remembered: "BlackHole2ch",
            plainCardUIDs: ["group:1234", "speakers"],
            groupMemberUIDs: [],
            deviceUIDs: ["BlackHole2ch", "hdmi"],
            isUsable: usable)
        XCTAssertEqual(order, ["speakers", "hdmi"])
        XCTAssertFalse(order.contains("BlackHole2ch"), "restoring to the capture sink is the silence this guards")
        XCTAssertFalse(order.contains("group:1234"), "a group uid is not a device the system can output to")
    }

    func testAnUnpluggedRememberedOutputFallsThrough() {
        // The exact reported path: remember USB headphones, unplug them, stop
        // capturing. A stale uid must not shadow the working fallbacks.
        let usable: (String) -> Bool = { $0 != "usb-headphones" }
        let order = MixerStore.restoreOrder(
            remembered: "usb-headphones",
            plainCardUIDs: ["speakers"],
            groupMemberUIDs: [],
            deviceUIDs: ["speakers", "hdmi"],
            isUsable: usable)
        XCTAssertEqual(order.first, "speakers")
    }

    func testGroupMembersAreUsedBeforeUnrelatedDevices() {
        let order = MixerStore.restoreOrder(
            remembered: nil,
            plainCardUIDs: [],
            groupMemberUIDs: ["airpods", "speakers"],
            deviceUIDs: ["hdmi"],
            isUsable: anything)
        XCTAssertEqual(order, ["airpods", "speakers", "hdmi"])
    }

    func testNoDuplicates() {
        let order = MixerStore.restoreOrder(
            remembered: "speakers",
            plainCardUIDs: ["speakers"],
            groupMemberUIDs: ["speakers"],
            deviceUIDs: ["speakers"],
            isUsable: anything)
        XCTAssertEqual(order, ["speakers"])
    }

    func testEmptyWhenNothingIsUsable() {
        let order = MixerStore.restoreOrder(
            remembered: "sink", plainCardUIDs: ["sink"], groupMemberUIDs: [],
            deviceUIDs: ["sink"], isUsable: { _ in false })
        XCTAssertTrue(order.isEmpty, "callers must be able to tell that no restore target exists")
    }
}

final class ReorderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// Cards laid out top to bottom at 100pt intervals.
    private func layout(_ ids: [UUID]) -> [UUID: CGFloat] {
        var pins: [UUID: CGFloat] = [:]
        for (i, id) in ids.enumerated() { pins[id] = CGFloat(i) * 100 }
        return pins
    }

    func testDragToTop() {
        let order = [a, b, c]
        let result = MixerStore.reordered(order, moving: c, visible: order,
                                          pinY: layout(order), pointerY: -10)
        XCTAssertEqual(result, [c, a, b])
    }

    func testDragToBottom() {
        let order = [a, b, c]
        let result = MixerStore.reordered(order, moving: a, visible: order,
                                          pinY: layout(order), pointerY: 250)
        XCTAssertEqual(result, [b, c, a])
    }

    func testDragDownwardsWithHiddenCardsInBetween() {
        // b and d are filtered out by "Hide inactive", so they have no pin
        // frame. Counting them is what used to make this drag do nothing.
        let order = [a, b, c, d]
        let visible = [a, c]
        let pins: [UUID: CGFloat] = [a: 0, c: 100]
        let result = MixerStore.reordered(order, moving: a, visible: visible,
                                          pinY: pins, pointerY: 150)
        XCTAssertEqual(result, [b, c, a, d],
                       "the dragged card must land after the last visible card above the pointer")
        XCTAssertEqual(result.count, order.count, "hidden cards must survive the reorder")
    }

    func testHiddenCardsAreNeverDropped() {
        let order = [a, b, c, d]
        let result = MixerStore.reordered(order, moving: c, visible: [c],
                                          pinY: [c: 0], pointerY: -50)
        XCTAssertEqual(Set(result), Set(order))
    }

    func testUnknownDraggedIDIsANoOp() {
        let order = [a, b]
        XCTAssertEqual(MixerStore.reordered(order, moving: d, visible: order,
                                            pinY: layout(order), pointerY: 0), order)
    }
}

final class DefaultColorTests: XCTestCase {
    /// The defect: colours came from `String.hashValue`, which Swift re-seeds
    /// per process, so every un-customized card changed colour on each launch.
    /// These are the values a second process must also produce.
    func testHashIsStableAcrossProcesses() {
        XCTAssertEqual(MixerStore.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(MixerStore.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(MixerStore.stableHash("foobar"), 0x85944171f73967e8)
    }

    func testSameKeyAlwaysGivesTheSameColor() {
        let keys = ["input:BuiltInMic", "output:Speakers", "System Audio", ""]
        for key in keys {
            XCTAssertEqual(MixerStore.defaultColor(for: key), MixerStore.defaultColor(for: key))
        }
    }

    func testColorsSpreadAcrossThePalette() {
        let keys = (0..<200).map { "device-\($0)" }
        let used = Set(keys.map { MixerStore.defaultColor(for: $0) })
        XCTAssertGreaterThan(used.count, 1, "every card taking the same colour would be a broken hash")
    }
}

final class PersistedShapeTests: XCTestCase {
    private func sample(version: Int?) -> MixerStore.Persisted {
        MixerStore.Persisted(
            version: version,
            previousDefaultOutputUID: "usb-headphones",
            inputs: [], outputs: [], connections: [],
            colors: ["output:Speakers": 2],
            deviceNicknames: ["uid": "Nickname"],
            scenes: nil,
            customDeviceIcons: nil)
    }

    func testRoundTripPreservesTheRestoreTarget() throws {
        // This field not being persisted is why a restore after a fresh launch
        // had nothing to aim at.
        let data = try JSONEncoder().encode(sample(version: 1))
        let back = try JSONDecoder().decode(MixerStore.Persisted.self, from: data)
        XCTAssertEqual(back.previousDefaultOutputUID, "usb-headphones")
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.colors["output:Speakers"], 2)
        XCTAssertEqual(back.deviceNicknames?["uid"], "Nickname")
    }

    func testFileFromBeforeVersioningStillDecodes() throws {
        // A 0.10.x graph.json has neither key. Decoding must not throw, or the
        // upgrade path destroys the user's setup.
        let legacy = """
        {"inputs":[],"outputs":[],"connections":[],"colors":{}}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(MixerStore.Persisted.self, from: legacy)
        XCTAssertNil(back.version)
        XCTAssertNil(back.previousDefaultOutputUID)
    }

    func testTruncatedFileIsRejectedRatherThanPartiallyAccepted() {
        let broken = "{\"inputs\":[],\"outputs\":".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MixerStore.Persisted.self, from: broken),
                             "load() relies on this throwing so it can set the file aside instead of overwriting it")
    }
}
