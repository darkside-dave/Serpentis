import Foundation

final class ReportRecorder {
    var sent: [[UInt8]] = []
    var replies: [[UInt8]?] = []
    var waits: [UInt32] = []
    var sendSucceeds = true
    private(set) var reads = 0

    func mouse(productID: Int = 0x00E7) -> RazerMouse {
        RazerMouse(productID: productID, transport: RazerReportTransport(
            send: { [self] in sent.append($0); return sendSucceeds },
            receive: { [self] in
                reads += 1
                return replies.isEmpty ? nil : replies.removeFirst()
            },
            wait: { [self] in waits.append($0) }
        ))
    }

    static func reply(status: UInt8 = 0x02, reportClass: UInt8 = 0x02, command: UInt8 = 0x0C, args: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 90)
        report[0] = status
        report[6] = reportClass
        report[7] = command
        report.replaceSubrange(8..<(8 + args.count), with: args)
        return report
    }
}

struct HardwareRemappingTests {
    func keyboardAssignmentsRequireAnExactEcho() throws {
        for slot in SerpentisModel.slots {
            for modifiers: UInt8 in [0, 1, 2, 4, 8, 3, 15, 0xF0] {
                let args = RazerMouse.keyArgs(slot.id, mod: modifiers, key: 0x1E)
                let recorder = ReportRecorder()
                recorder.replies = [ReportRecorder.reply(args: args)]

                try expect(recorder.mouse().setButton(args), "\(slot.name), modifiers \(modifiers)")
                try expect(recorder.sent.count == 1)
                try expect(Array(recorder.sent[0][8..<18]) == args)

                var different = args
                different[6] = 0x1F
                recorder.replies = [ReportRecorder.reply(args: different)]
                try expect(!recorder.mouse().setButton(args))
            }
        }
    }

    func factoryAssignmentsCanBeRestored() throws {
        for slot in SerpentisModel.slots {
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(args: slot.factory)]
            try expect(recorder.mouse().setButton(slot.factory), slot.name)
            try expect(Array(recorder.sent[0][8..<18]) == slot.factory)
        }
    }

    func mouseAssignmentsAreSentUnchanged() throws {
        for slot in SerpentisModel.slots {
            for button: UInt8 in [1, 2, 3, 4, 5] {
                let args = RazerMouse.mouseArgs(slot.id, button: button)
                let recorder = ReportRecorder()
                recorder.replies = [ReportRecorder.reply(args: args)]
                try expect(recorder.mouse().setButton(args))
                try expect(Array(recorder.sent[0][8..<18]) == args)
            }
        }
    }

    func buttonReadsReturnTheRequestedAssignment() throws {
        for slot in SerpentisModel.slots {
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(command: 0x8C, args: slot.factory)]
            try expect(recorder.mouse().button(slot.id) == slot.factory)
            try expect(Array(recorder.sent[0][8..<11]) == Array(slot.factory.prefix(3)))
        }
    }

    func busyAndUnrelatedRepliesDoNotResendTheWrite() throws {
        let args = RazerMouse.keyArgs(0x40, mod: 3, key: 0x1E)
        let recorder = ReportRecorder()
        recorder.replies = [
            ReportRecorder.reply(status: 0x01, args: args),
            ReportRecorder.reply(command: 0x8C, args: args),
            ReportRecorder.reply(args: args),
        ]
        try expect(recorder.mouse().setButton(args))
        try expect(recorder.sent.count == 1)
        try expect(recorder.reads == 3)
        try expect(recorder.waits == [45_000, 25_000, 25_000])
    }

    func retriesAreBounded() throws {
        let args = RazerMouse.defaultArgs(0)
        let recorder = ReportRecorder()
        recorder.replies = Array(repeating: ReportRecorder.reply(status: 0x01, args: args), count: 21)
        try expect(!recorder.mouse().setButton(args))
        try expect(recorder.sent.count == 1)
        try expect(recorder.reads == 20)
    }

    func deviceFailuresAreNotSuccessfulWrites() throws {
        let args = RazerMouse.defaultArgs(0)
        for status: UInt8 in [0x03, 0x04, 0x05] {
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(status: status, args: args)]
            try expect(!recorder.mouse().setButton(args))
            try expect(recorder.reads == 1)
        }
        let sendFailure = ReportRecorder()
        sendFailure.sendSucceeds = false
        try expect(!sendFailure.mouse().setButton(args))
        try expect(sendFailure.reads == 0)
        try expect(sendFailure.waits.isEmpty)

        let readFailure = ReportRecorder()
        try expect(!readFailure.mouse().setButton(args))
        try expect(readFailure.reads == 1)
    }

    func invalidAssignmentLengthsAreNotSent() throws {
        for count in [0, 3, 9, 11] {
            let recorder = ReportRecorder()
            let args = [UInt8](repeating: 0, count: count)
            try expect(!recorder.mouse().setButton(args))
            try expect(recorder.sent.isEmpty)
        }
    }

    func commandsHaveAValidChecksumAndNoExtraPayload() throws {
        let args = RazerMouse.keyArgs(0x40, mod: 8, key: 0x1E)
        let recorder = ReportRecorder()
        recorder.replies = [ReportRecorder.reply(args: args)]
        try expect(recorder.mouse().setButton(args))
        let report = recorder.sent[0]
        try expect(report.count == 90)
        try expect(report[88] == report[2..<88].reduce(0, ^))
        try expect(report[18..<88].allSatisfy { $0 == 0 })
    }
}
