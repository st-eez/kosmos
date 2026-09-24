import Testing
@testable import KosmosCore

/// Renders a table compactly so a test can compare a whole document in one string.
private func render(_ table: TOMLTable) -> String {
    "{" + table.entries.map { "\($0.key)=\(render($0.value))" }.joined(separator: ",") + "}"
}

private func render(_ value: TOMLValue) -> String {
    switch value.kind {
    case .string(let string): "\"\(string)\""
    case .integer(let integer): String(integer)
    case .boolean(let boolean): String(boolean)
    case .array(let items): "[" + items.map(render).joined(separator: ",") + "]"
    case .table(let table): render(table)
    }
}

private func parsed(_ text: String) throws -> String {
    render(try parseTOML(text))
}

/// The error a document fails with, as `line:column: path: message`.
private func failure(_ text: String) -> String? {
    do {
        _ = try parseTOML(text)
        return nil
    } catch {
        return "\(error.position.line):\(error.position.column): \(error.path): \(error.message)"
    }
}

@Suite struct TOMLTests {
    @Test func keysAndScalars() throws {
        let text = """
        # A comment line
        name = "kosmos"   # a trailing comment
        count = 42
        on = true
        off = false
        "quoted key" = 'literal'
        """
        #expect(try parsed(text) == #"{name="kosmos",count=42,on=true,off=false,quoted key="literal"}"#)
    }

    @Test func keysAndValuesKeepTheirPositions() throws {
        let table = try parseTOML("\n  inner =   10\n")
        let entry = try #require(table["inner"])
        #expect(entry.keyPosition == SourcePosition(line: 2, column: 3))
        #expect(entry.value.position == SourcePosition(line: 2, column: 13))
    }

    @Test func basicStringEscapes() throws {
        let text = #"s = "tab\t nl\n quote\" slash\\ e\u00E9 face\U0001F600 A\x41 esc\e b\b f\f r\r""#
        let entry = try #require(try parseTOML(text)["s"])
        #expect(entry.value.kind == .string("tab\t nl\n quote\" slash\\ e\u{E9} face\u{1F600} A\u{41} esc\u{1B} b\u{08} f\u{0C} r\r"))
    }

    @Test func literalStringsKeepBackslashes() throws {
        #expect(try parsed(#"path = 'C:\Users\n'"#) == #"{path="C:\Users\n"}"#)
    }

    @Test func hashInsideAStringIsNotAComment() throws {
        #expect(try parsed(#"a = "x # y" # z"#) == #"{a="x # y"}"#)
    }

    @Test func badStringsPointAtTheProblem() {
        #expect(failure(#"s = "a\qb""#) == #"1:7: s: '\q' is not a valid escape"#)
        #expect(failure("s = \"open\nt = 1") == "1:5: s: the string is not closed on this line")
        #expect(failure("s = 'open") == "1:5: s: the string is not closed on this line")
        #expect(failure(#"s = "\uD800""#) == #"1:6: s: '\u' names U+D800, which is not a Unicode scalar value"#)
        #expect(failure(#"s = "\u12""#) == #"1:6: s: '\u' needs 4 hexadecimal digits"#)
        #expect(failure("s = \"a\u{01}b\"") == "1:7: s: control character U+0001 must be escaped in a string")
        #expect(failure("s = \"\"\"long\"\"\"") == "1:5: s: multi-line strings are not supported")
    }

    @Test func integers() throws {
        #expect(try parsed("a = 1_000\nb = +5\nc = -5\nd = 0") == "{a=1000,b=5,c=-5,d=0}")
        #expect(failure("a = 01") == "1:5: a: '01' is not a valid integer")
        #expect(failure("a = 1__0") == "1:5: a: '1__0' is not a valid integer")
        #expect(failure("a = 1-2") == "1:5: a: '1-2' is not a valid integer")
        #expect(failure("a = 99999999999999999999") == "1:5: a: 99999999999999999999 is out of range for a 64-bit integer")
    }

    @Test func unsupportedValuesAreRejected() {
        #expect(failure("a = 1.5") == "1:5: a: floats are not supported")
        #expect(failure("a = 1e3") == "1:5: a: floats are not supported")
        #expect(failure("a = 1e-3") == "1:5: a: floats are not supported")
        #expect(failure("a = -2.5E-10") == "1:5: a: floats are not supported")
        #expect(failure("a = -inf") == "1:5: a: floats are not supported")
        #expect(failure("a = 1979-05-27") == "1:5: a: dates and times are not supported")
        #expect(failure("a = 07:32:00") == "1:5: a: dates and times are not supported")
        #expect(failure("a = 0xFF") == "1:5: a: hexadecimal, octal and binary integers are not supported")
        #expect(failure("layout = tiles") == "1:10: layout: expected a value; put strings in quotes")
    }

    @Test func arraysSpanLinesWithCommentsAndATrailingComma() throws {
        let text = """
        a = [
          1, # one
          [2, 3],
          'x',
        ]
        b = []
        """
        #expect(try parsed(text) == #"{a=[1,[2,3],"x"],b=[]}"#)
        #expect(failure("a = [1,,2]") == "1:8: a[1]: expected a value, found ','")
        #expect(failure("a = [1 2]") == "1:8: a[0]: expected ',' or ']', found '2'")
        #expect(failure("a = [1,\n") == "2:1: a[1]: expected a value, found the end of the file")
    }

    @Test func inlineTables() throws {
        #expect(try parsed("t = { a = 1, b.c = 'x', d = { e = true } }") == #"{t={a=1,b={c="x"},d={e=true}}}"#)
        // TOML 1.1 allows line breaks and a trailing comma.
        #expect(try parsed("t = {\n  a = 1,\n  b = 2,\n}") == "{t={a=1,b=2}}")
        #expect(try parsed("t = {}") == "{t={}}")
        #expect(failure("t = { a = 1, a = 2 }") == "1:14: t.a: duplicate key; it is first defined at line 1")
        #expect(failure("t = { a = 1 b = 2 }") == "1:13: t.a: expected ',' or '}', found 'b'")
    }

    @Test func dottedKeysBuildTables() throws {
        #expect(try parsed("a.b.c = 1\na . d = 2\n\"x.y\" = 3") == #"{a={b={c=1},d=2},x.y=3}"#)
    }

    @Test func tablesAndArraysOfTables() throws {
        let text = """
        top = 1
        [a.b]
        c = 2
        [a]
        d = 3
        [[rule]]
        id = 'x'
        [[rule]]
        id = 'y'
        [[profile]]
        name = 'p'
        [[profile.rule]]
        id = 'z'
        """
        #expect(try parsed(text) == #"{top=1,a={b={c=2},d=3},rule=[{id="x"},{id="y"}],profile=[{name="p",rule=[{id="z"}]}]}"#)
    }

    @Test func tablePositionsPointAtTheHeader() throws {
        let rules = try #require(try parseTOML("\n[[rule]]\n\n[[rule]]\n")["rule"])
        guard case .array(let items) = rules.value.kind else { Issue.record("rule is not an array"); return }
        #expect(items.map(\.position.line) == [2, 4])
    }

    @Test func duplicateKeysAndTablesAreErrors() {
        #expect(failure("a = 1\nb = 2\na = 3") == "3:1: a: duplicate key; it is first defined at line 1")
        #expect(failure("[gaps]\ninner = 1\n[gaps]") == "3:2: gaps: 'gaps' is already defined at line 1")
        #expect(failure("[mode.main.binding]\nalt-h = 'a'\nalt-h = 'b'") == "3:1: mode.main.binding.alt-h: duplicate key; it is first defined at line 2")
        #expect(failure("[[rule]]\n[rule]") == "2:2: rule: 'rule' is already defined at line 1")
        #expect(failure("a = [1]\n[[a]]") == "2:3: a: 'a' is already defined at line 1")
        #expect(failure("t = { x = 1 }\n[t.y]") == "2:2: t: 't' is already defined at line 1")
    }

    @Test func dottedKeysCannotReopenTables() {
        // A dotted key may extend only tables that dotted keys created in the same table.
        #expect(failure("gaps.inner = 1\n[gaps]") == "2:2: gaps: 'gaps' is already defined at line 1")
        #expect(failure("[a.b]\nx = 1\n[a]\nb.y = 2") == "4:1: a.b: 'a.b' is already defined at line 1")
        #expect(failure("t = { x = 1 }\nt.y = 2") == "2:1: t: 't' is already defined at line 1")
    }

    @Test func syntaxErrorsCarryPositionAndPath() {
        #expect(failure("[mode.main.binding]\nalt-h 'focus'") == "2:7: mode.main.binding.alt-h: expected '=' after the key")
        #expect(failure("a = 1 2") == "1:7: a: expected the end of the line, found '2'")
        #expect(failure("[gaps\ninner = 1") == "1:6: gaps: expected ']' to close the table header")
        #expect(failure("[[rule]\n") == "1:8: rule: expected ']]' to close the table header")
        #expect(failure("= 1") == "1:1: : expected a key, found '='")
        #expect(failure("a =") == "1:4: a: expected a value, found the end of the file")
        #expect(failure("a = # nothing") == "1:5: a: expected a value, found '#'")
    }

    @Test func lineEndings() throws {
        #expect(try parsed("\u{FEFF}a = 1\r\nb = 2\r\n") == "{a=1,b=2}")
        #expect(failure("a = 1\rb = 2") == "1:6: a: a carriage return must be followed by a line feed")
        #expect(failure("a = 1\r\nb = x") == "2:5: b: expected a value; put strings in quotes")
    }
}
