import Testing
@testable import KosmosIPC

@Suite struct FramingTests {
    @Test func prefixesTheBigEndianLength() {
        #expect(frame([1, 2, 3]) == [0, 0, 0, 3, 1, 2, 3])
        #expect(frame(Array(repeating: 0, count: 0x0102)).prefix(4) == [0, 0, 1, 2])
    }

    @Test func assemblesFramesFromPartialReads() throws {
        var decoder = FrameDecoder()
        let stream = frame(Array("first".utf8)) + frame([]) + frame(Array("third".utf8))
        var frames: [[UInt8]] = []
        for byte in stream {
            decoder.append([byte])
            while let body = try decoder.next() { frames.append(body) }
        }
        #expect(frames == [Array("first".utf8), [], Array("third".utf8)])
        #expect(decoder.isEmpty)
    }

    @Test func splitsSeveralFramesInOneRead() throws {
        var decoder = FrameDecoder()
        decoder.append(frame([1]) + frame([2, 2]) + [0, 0])
        #expect(try decoder.next() == [1])
        #expect(try decoder.next() == [2, 2])
        #expect(try decoder.next() == nil)
        #expect(!decoder.isEmpty)
    }

    @Test func rejectsAnOversizedLengthBeforeItsBody() throws {
        var accepted = FrameDecoder()
        accepted.append([0x01, 0x00, 0x00, 0x00])
        #expect(try accepted.next() == nil)

        var rejected = FrameDecoder()
        rejected.append([0x01, 0x00, 0x00, 0x01])
        #expect(throws: IPCError.malformed("a frame of 16777217 bytes exceeds the limit of 16777216")) {
            try rejected.next()
        }
    }
}

@Suite struct JSONTests {
    @Test func roundTripsEveryKind() throws {
        let value = JSON.object([
            "text": .string("quote \" backslash \\ newline \n tab \t nul \u{0} bell \u{7} é 😀"),
            "number": .int(-42),
            "list": .array([.bool(true), .bool(false), .null, .int(Int.max), .int(Int.min)]),
            "nested": .object(["empty": .array([]), "": .object([:])]),
        ])
        #expect(try JSON(parsing: value.encoded) == value)
    }

    @Test func encodesCompactlyWithSortedKeys() {
        let value = JSON.object(["b": .int(1), "a": .array([.string("x\u{1}")])])
        #expect(String(decoding: value.encoded, as: UTF8.self) == #"{"a":["x\u0001"],"b":1}"#)
    }

    @Test func parsesEscapesAndWhitespace() throws {
        let text = #" { "s" : "é😀\/\b\f\r" , "a" : [ 1 , -2 ] } "#
        #expect(try JSON(parsing: Array(text.utf8)) == .object([
            "s": .string("é😀/\u{8}\u{c}\r"), "a": .array([.int(1), .int(-2)]),
        ]))
    }

    @Test(arguments: [
        "", "{", "}", #"{"a":}"#, #"{"a" 1}"#, #"{a:1}"#, "[1,]", "[1 2]", #""abc"#, "\"\u{1}\"",
        #""\x""#, #""\ud800""#, #""\udc00""#, #""\ud800A""#, #""\u12g4""#, "1.5", "1e3", "-",
        "tru", "nul", "{} x", "99999999999999999999",
    ])
    func rejectsMalformedText(_ text: String) {
        #expect(throws: IPCError.self) { try JSON(parsing: Array(text.utf8)) }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: IPCError.self) { try JSON(parsing: [0x22, 0xFF, 0x22]) }
    }

    @Test func limitsNesting() throws {
        let shallow = String(repeating: "[", count: 10) + String(repeating: "]", count: 10)
        #expect(throws: Never.self) { try JSON(parsing: Array(shallow.utf8)) }
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(throws: IPCError.self) { try JSON(parsing: Array(deep.utf8)) }
    }
}

@Suite struct MessageTests {
    @Test func roundTripsRequestsAndResponses() throws {
        for request in [Request.command(["workspace", "3 4", ""]), .command([]), .subscribe] {
            #expect(try Request(decoding: request.encoded) == request)
        }
        let response = Response(exitCode: -1, stdout: "a\nb", stderr: "é")
        #expect(try Response(decoding: response.encoded) == response)
    }

    @Test func rejectsRequestsOfAnotherShape() {
        let cases: [(String, IPCError)] = [
            ("[]", .malformed("a request must be an object")),
            (#"{"args":["ping"]}"#, .malformed("the request has no protocol version")),
            (#"{"protocol":2,"args":["ping"]}"#, .protocolMismatch(client: 2)),
            (#"{"protocol":1,"args":[1]}"#, .malformed("args must be strings")),
            (#"{"protocol":1,"subscribe":false}"#, .malformed("the request has neither args nor subscribe")),
        ]
        for (text, error) in cases {
            #expect(throws: error) { try Request(decoding: Array(text.utf8)) }
        }
    }

    @Test func rejectsResponsesWithMissingFields() {
        #expect(throws: IPCError.self) { try Response(decoding: Array(#"{"exitCode":0,"stdout":""}"#.utf8)) }
        #expect(throws: IPCError.self) {
            try Response(decoding: Array(#"{"exitCode":4294967296,"stdout":"","stderr":""}"#.utf8))
        }
    }
}
