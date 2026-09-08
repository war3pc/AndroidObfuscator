import XCTest
@testable import AndroidObfuscatorCore

final class StackRetracerTests: XCTestCase {
    func testRetracesClassAndMethodNames() throws {
        let mapping = """
        com.example.MainActivity -> a.b:
            10:10:void launchCheckout(java.lang.String):42:42 -> c
        com.example.PaymentRepository -> d.e:
            1:1:void charge():8:8 -> a
        """
        let stack = """
        java.lang.IllegalStateException: failed
            at a.b.c(Unknown Source:42)
            at d.e.a(PaymentRepository.kt:8)
            at java.lang.Thread.run(Thread.java:1012)
        """

        let result = try StackRetracer.retrace(mappingText: mapping, stackTrace: stack)
        XCTAssertTrue(result.text.contains("at com.example.MainActivity.launchCheckout(Unknown Source:42)"))
        XCTAssertTrue(result.text.contains("at com.example.PaymentRepository.charge(PaymentRepository.kt:8)"))
        XCTAssertEqual(result.replacedFrames, 2)
        XCTAssertEqual(result.indexedClasses, 2)
    }

    func testRejectsEmptyMapping() {
        XCTAssertThrowsError(try StackRetracer.retrace(mappingText: "# empty", stackTrace: "at a.b.c(x:1)"))
    }
}

