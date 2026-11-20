import XCTest
@testable import Hamaster

final class SupportTests: XCTestCase {
    func testScrollAccumulatorCarriesFractionsAndResets() {
        let accumulator = ScrollAccumulator()

        XCTAssertNil(accumulator.take(dx: 0.4, dy: 0.4))
        XCTAssertEqual(accumulator.take(dx: 0.7, dy: 0.7)?.dx, 1)
        accumulator.reset()
        XCTAssertNil(accumulator.take(dx: 0.4, dy: 0.4))
    }

    func testDeviceKeyNormalizesUnsafeSerialCharacters() {
        XCTAssertEqual(
            DeviceKey.make(vendorID: 0x05ac, productID: 0x030d, serialNumber: "AA:BB/CC"),
            "05ac-030d-aa-bb-cc"
        )
    }

    func testHardwareAddressNormalization() {
        XCTAssertEqual(MultitouchPairing.normalize(serialNumber: "AA-BB-CC-DD-EE-FF"), "aabbccddeeff")
        XCTAssertNil(MultitouchPairing.normalize(serialNumber: "too-short"))
    }
}

