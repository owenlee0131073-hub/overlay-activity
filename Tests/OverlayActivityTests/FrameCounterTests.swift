import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import OverlayActivity

final class FrameCounterTests: XCTestCase {
    func testCountsOnlyNewFramesFromSyntheticMetadata() throws {
        let counter = FrameCounter()
        XCTAssertNil(counter.sample(at: 10))

        let complete = try sampleBuffer(status: .complete)
        let idle = try sampleBuffer(status: .idle)
        let missingStatus = try sampleBuffer(status: nil)
        for _ in 0..<60 {
            counter.recordCompletedFrame(in: complete)
            counter.recordCompletedFrame(in: idle)
            counter.recordCompletedFrame(in: missingStatus)
        }

        XCTAssertEqual(counter.sample(at: 10.5), 120)
        XCTAssertEqual(counter.sample(at: 11), 0)
    }

    private func sampleBuffer(status: SCFrameStatus?) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        XCTAssertEqual(result, noErr)
        let buffer = try XCTUnwrap(sample)
        if let status {
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
            let metadata = try XCTUnwrap((attachments as NSArray).firstObject as? NSMutableDictionary)
            metadata[SCStreamFrameInfo.status.rawValue] = NSNumber(value: status.rawValue)
        }
        return buffer
    }
}
