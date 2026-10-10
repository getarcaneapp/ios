import Testing

@testable import Arcane_Mobile

@Suite struct EnvDocumentTests {
    @Test func preservesUnicodeCRLFAndComments() throws {
        let source = "# 🐳\r\nexport TOKEN='café'\r\nOTHER=${KEEP}\r\n"
        let doc = EnvDocument(source)
        let entry = try #require(doc.entries.first)
        #expect(try doc.setting("café", entry: entry) == source)
        #expect(try doc.setting("new", entry: entry) == source.replacingOccurrences(of: "'café'", with: "'new'"))
    }
    @Test func unsupportedLinesAndDuplicatesRemainRaw() {
        let source = "# comment\nA=one\nA=two\nB=plain # comment\nC=\"escape\\n\"\nD=good\n"
        let doc = EnvDocument(source)
        #expect(doc.entries.map(\.name) == ["D"])
        #expect(doc.unsupportedLines == 4)
    }
    @Test func multilineContentDoesNotBecomeEditableEntries() {
        let doc = EnvDocument("A='first\nB=inside\nlast'\nC=outside\n")
        #expect(doc.entries.map(\.name) == ["C"])
    }
    @Test func addingAndRemovingPreservesNeighbors() throws {
        let source = "# header\r\nA=1\r\nB=2\r\n"
        let doc = EnvDocument(source)
        #expect(try doc.adding("C") == source + "C=\r\n")
        #expect(throws: (any Error).self) { try doc.adding("A") }
        #expect(throws: (any Error).self) { try doc.adding("BAD-NAME") }
        #expect(doc.removing(try #require(doc.entries.first)) == "# header\r\nB=2\r\n")
    }
    @Test func rejectsStaleEntryAndMultilineEdits() throws {
        let old = EnvDocument("A=one\n")
        let entry = try #require(old.entries.first)
        let changed = EnvDocument("A=two\n")
        #expect(throws: (any Error).self) { try changed.setting("overwrite", entry: entry) }
        #expect(changed.removing(entry) == changed.source)
        #expect(throws: (any Error).self) { try old.setting("one\ntwo", entry: entry) }
    }

    @Test func escapedQuoteDoesNotEndMultilineValue() {
        let source = "A=\"first\\\" line\nB=inside\nlast\"\nC=outside\n"
        #expect(EnvDocument(source).entries.map(\.name) == ["C"])
    }

    @Test func trailingEscapedQuoteDoesNotEndMultilineValue() {
        let source = "A=\"first\\\"\nB=inside\nlast\"\nC=outside\n"
        #expect(EnvDocument(source).entries.map(\.name) == ["C"])
    }
    @Test func unsupportedDuplicateHidesAllAssignmentsForName() {
        let doc = EnvDocument("A=plain\nA=\"escaped\\n\"\nB=visible\n")
        #expect(doc.entries.map(\.name) == ["B"])
        #expect(doc.unsupportedLines == 2)
    }
}
