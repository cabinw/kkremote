import Foundation

@main struct SampleJournalTests {
    struct Value: Encodable { let text: String; let index: Int }
    struct SlowValue: Encodable {
        let entered: DispatchSemaphore, release: DispatchSemaphore
        func encode(to encoder: Encoder) throws {
            entered.signal(); release.wait()
            var container = encoder.singleValueContainer(); try container.encode("blocked")
        }
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("samples.jsonl")
        let journal = try SampleJournal<Value>(url: url)
        for i in 0..<4 { precondition(journal.append(Value(text: "窗口\n测试", index: i))) }
        precondition(journal.finish()); precondition(journal.finish())
        precondition(!journal.append(Value(text:"closed",index:4)))
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator:"\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String:Any]
        }
        precondition(rows.count == 4 && rows.map { $0["sequence"] as! Int } == [0,1,2,3])
        precondition((rows[0]["sample"] as! [String:Any])["text"] as! String == "窗口\n测试")
        do { _ = try SampleJournal<Value>(url: url); fatalError("existing evidence overwritten") } catch {}
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        let slow = try SampleJournal<SlowValue>(url: directory.appendingPathComponent("bounded.jsonl"),capacity:1)
        precondition(slow.append(SlowValue(entered:entered,release:release)))
        entered.wait()
        precondition(!slow.append(SlowValue(entered:entered,release:release)))
        release.signal()
        precondition(!slow.finish())
        let status = slow.snapshot()
        precondition(status.highWater == 1 && status.submitted == 2 && status.written == 1 && status.dropped == 1 && status.pending == 0)
        print("SAMPLE_JOURNAL_TESTS_PASSED: ordered UTF8 records, exclusive evidence, bounded queue, loss exposed, close drains")
    }
}
