import XCTest
@testable import MarginCore

final class AgentTests: XCTestCase {
    let token = String(repeating:"a",count:64)
    func wire(_ body: String = "{}", headers: String = "", method: String = "POST") -> Data {
        Data("\(method) /v1/call HTTP/1.1\r\nHost: 127.0.0.1:19876\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
    }
    func testHTTPFragmentedUnicodeBodyAndAuthorization() throws {
        let bytes = wire("{\"text\":\"中文🍎\"}")
        for length in 0..<bytes.count { XCTAssertNil(try AgentHTTPRequest.parse(Data(bytes.prefix(length)))) }
        let request = try XCTUnwrap(AgentHTTPRequest.parse(bytes))
        XCTAssertEqual(String(data:request.body,encoding:.utf8),"{\"text\":\"中文🍎\"}")
        XCTAssertNoThrow(try request.head.authorize(token:token,port:19876))
        XCTAssertThrowsError(try request.head.authorize(token:String(repeating:"b",count:64),port:19876))
    }
    func testHTTPRejectsAmbiguousLengthsAndPipelining() {
        for extra in ["Content-Length: 2\r\n","Transfer-Encoding: chunked\r\n"," Content-Length: 3\r\n"] {
            XCTAssertThrowsError(try AgentHTTPRequest.parse(wire(headers:extra)))
        }
        XCTAssertThrowsError(try AgentHTTPRequest.parse(wire() + wire()))
        XCTAssertThrowsError(try AgentHTTPRequest.parse(wire("x",method:"GET")))
    }
    func testHTTPBoundsBeforeBodyIsUploaded() throws {
        let value = Data("POST /v1/call HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(AgentLimits.bodyBytes + 1)\r\n\r\n".utf8)
        XCTAssertThrowsError(try AgentHTTPRequest.head(in:value))
        XCTAssertThrowsError(try AgentHTTPRequest.head(in:Data(repeating:65,count:AgentLimits.headerBytes + 1)))
        XCTAssertNil(try AgentHTTPRequest.head(in:Data("GET /v1/status".utf8)))
    }
    func testHTTPRejectsBrowserOriginsAndForeignHost() throws {
        let request = try XCTUnwrap(AgentHTTPRequest.parse(wire(headers:"Origin: https://example.com\r\n")))
        XCTAssertThrowsError(try request.head.authorize(token:token,port:19876))
        var head = try XCTUnwrap(AgentHTTPRequest.head(in:wire()))
        head.headers["host"] = "attacker.example:19876"
        XCTAssertThrowsError(try head.authorize(token:token,port:19876))
        head.headers["host"] = "localhost:19876"
        XCTAssertNoThrow(try head.authorize(token:token,port:19876))
    }
    func testResponseCountsUTF8Bytes() {
        let response = AgentHTTPResponse(body:Data("中文".utf8))
        let wire = String(data:response.encoded,encoding:.utf8)!
        XCTAssertTrue(wire.contains("Content-Length: 6\r\n")); XCTAssertTrue(wire.hasSuffix("中文"))
        XCTAssertTrue(wire.contains("Cache-Control: no-store"))
    }
    func sample() -> [Block] {
        var file = Block(.pdf,frame:Rect(0,0,300,480)); file.collapsed = true
        return [Block(.text,frame:Rect(0,0,600,180),text:"# 主题\n\n正文"),file,
                Block(.text,frame:Rect(0,0,600,180),text:String(repeating:"内容",count:200))]
    }
    func assertNoOverlap(_ blocks: [Block], file: StaticString = #filePath, line: UInt = #line) {
        for i in blocks.indices { for j in blocks.indices where i < j {
            XCTAssertFalse(blocks[i].visibleFrame.intersects(blocks[j].visibleFrame),file:file,line:line)
        } }
    }
    func testReadingLayoutHasTextAndFileLanesWithoutOverlap() throws {
        var note = Note(title:"宽页"); note.canvasWidth = 1400
        let source = sample(), result = try AgentLayout.arrange(source,in:note,style:.reading)
        XCTAssertEqual(result.map(\.id),source.map(\.id)); assertNoOverlap(result)
        XCTAssertEqual(result[0].frame.x,result[2].frame.x)
        XCTAssertGreaterThan(result[1].frame.x,result[0].frame.maxX)
        XCTAssertEqual(result[1].frame.height,36); XCTAssertGreaterThan(result[2].frame.y,result[0].frame.maxY)
    }
    func testNarrowReadingAndColumnPreserveMixedInputOrder() throws {
        var note = Note(title:"窄页"); note.canvasWidth = 600
        for style in [AgentLayoutStyle.reading,.column] {
            let result = try AgentLayout.arrange(sample(),in:note,style:style)
            assertNoOverlap(result)
            XCTAssertGreaterThan(result[1].frame.y,result[0].frame.maxY)
            XCTAssertGreaterThan(result[2].frame.y,result[1].frame.maxY)
            XCTAssertTrue(result.allSatisfy { $0.frame.maxX <= note.width })
        }
    }
    func testGridRowsRespectTallestBlockAndOrder() throws {
        var note = Note(title:"网格"); note.canvasWidth = 1200
        let input = sample() + sample()
        let result = try AgentLayout.arrange(input,in:note,style:.grid)
        assertNoOverlap(result); XCTAssertEqual(result.map(\.id),input.map(\.id))
        XCTAssertGreaterThan(result[3].frame.y,result.prefix(3).map { $0.frame.maxY }.max()!)
    }
    func testAppendDoesNotMoveExistingOrInk() throws {
        var note = Note(title:"手写"); note.canvasWidth = 1200; note.blocks = sample()
        note.ink = Data([1,2,3]); note.inkBounds = Rect(0,0,100,1700)
        let original = note
        let result = try AgentLayout.arrange(sample(),in:note,style:.reading)
        XCTAssertTrue(result.allSatisfy { $0.frame.y > 1700 }); XCTAssertEqual(note,original)
        XCTAssertThrowsError(try AgentLayout.protectExisting(note.blocks,in:note))
    }
    func testLayoutProtectsLocksAnchorsAndPageAnnotations() throws {
        var note = Note(title:"保护"), block = sample()[1]
        block.locked = true; XCTAssertThrowsError(try AgentLayout.protectExisting([block],in:note))
        block.locked = false; note.anchors = [AnnotationAnchor(ownerID:block.id,label:"批注",u:1,v:0)]
        XCTAssertThrowsError(try AgentLayout.protectExisting([block],in:note))
        note.anchors = []; var annotation = AttachmentPageAnnotations(); annotation.ink = Data([1])
        block.pageAnnotations = ["0":annotation]
        XCTAssertThrowsError(try AgentLayout.protectExisting([block],in:note))
        block.pageAnnotations = nil; XCTAssertNoThrow(try AgentLayout.protectExisting([block],in:note))
    }
    func testFinitePaperRejectsOverflowWithoutPartialLayout() {
        var note = Note(title:"A4"); note.paper = .a4
        let blocks = (0..<15).map { _ in Block(.text,frame:Rect(0,0,600,200),text:String(repeating:"文本",count:200)) }
        XCTAssertThrowsError(try AgentLayout.arrange(blocks,in:note,style:.column)); XCTAssertTrue(note.blocks.isEmpty)
    }
    func testReceiptsSurviveSaveAndOlderWorkspaceLoads() throws {
        var workspace = Workspace(notes:[Note(title:"旧资料")])
        let old = try JSONEncoder().encode(workspace)
        XCTAssertNil(try JSONDecoder().decode(Workspace.self,from:old).agentReceipts)
        workspace.agentReceipts = [AgentReceipt(requestID:"request-1",fingerprint:"sha",tool:"create_page",result:Data("{}".utf8))]
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self,from:JSONEncoder().encode(workspace)),workspace)
    }
}
