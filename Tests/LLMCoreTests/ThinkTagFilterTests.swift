import Testing
@testable import LLMCore

/// Feed all chunks then flush, concatenating the visible output.
private func run(_ chunks: [String]) -> String {
    var filter = ThinkTagFilter()
    var out = ""
    for c in chunks { out += filter.feed(c) }
    out += filter.flush()
    return out
}

@Suite struct ThinkTagFilterTests {
    @Test func noThinkPassesThrough() {
        #expect(run(["Hello, ", "world!"]) == "Hello, world!")
    }

    @Test func completeBlockInOneChunk() {
        #expect(run(["<think>reasoning here</think>answer"]) == "answer")
    }

    @Test func blockSplitAcrossChunks() {
        // Tag and content split at awkward boundaries.
        #expect(run(["before <th", "ink>hidden", " stuff</thi", "nk>after"]) == "before after")
    }

    @Test func openTagNeverClosedDropsToEnd() {
        #expect(run(["visible <think>never closed reasoning"]) == "visible ")
    }

    @Test func partialTagThatIsNotATagIsEmitted() {
        // "<th" looks like a tag start but resolves to plain text.
        #expect(run(["a<th", "en b"]) == "a<then b")
    }

    @Test func multipleBlocks() {
        #expect(run(["<think>x</think>A<think>y</think>B"]) == "AB")
    }

    @Test func lessThanSignAlone() {
        #expect(run(["1 < 2 and ", "3 > 2"]) == "1 < 2 and 3 > 2")
    }
}
