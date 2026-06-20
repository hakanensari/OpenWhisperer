import Foundation

/// `speakable-text.sh` reads a markdown assistant message on stdin and prints spoken text:
/// the first prose paragraph by default (markdown stripped, ~600-char cap). Returns failures.
func speakableTextFailures() -> [String] {
    var failures: [String] = []
    let sandbox = Hook.Sandbox()
    defer { sandbox.cleanup() }

    func firstPara(_ input: String) -> String {
        Hook.run("speakable-text.sh", stdin: input, sandbox: sandbox).stdout
    }
    func expect(_ input: String, _ expected: String, _ name: String) {
        let r = firstPara(input)
        if r != expected {
            failures.append("speakable-text.\(name): got \(r.debugDescription), expected \(expected.debugDescription)")
        }
    }

    expect("Fixed it. Tests pass now.\n", "Fixed it. Tests pass now.", "singleParagraphPlain")
    expect("First line stays.\n\nSecond paragraph dropped.\n", "First line stays.", "stopsAtBlankLine")
    expect("```swift\nlet x = 1\n```\n\nThe real summary sentence.\n",
           "The real summary sentence.", "skipsLeadingCodeFence")
    expect("## Result\nDone and verified.\n", "Done and verified.", "skipsLeadingHeading")
    expect("Updated **auth** in `login.swift` see [docs](http://x.io/y) now.\n",
           "Updated auth in login.swift see docs now.", "stripsInlineMarkdownAndLinks")
    expect("```\ncode only\n```\n", "", "emptyWhenNoProse")
    expect("| col1 | col2 |\nActual prose here.\n", "Actual prose here.", "skipsTableRows")
    expect("- first bullet item\n", "first bullet item", "deBullets")
    expect("1. step one\n", "step one", "deNumbers")
    expect("This is *important* text.\n", "This is important text.", "stripsItalic")
    expect("Visit https://example.com today.\n", "Visit today.", "stripsBareUrl")

    // Long paragraph: capped at <=600 chars on a sentence boundary.
    let long = String(repeating: "Sentence one is here. ", count: 40)
        .trimmingCharacters(in: .whitespaces) + "\n"
    let capped = firstPara(long)
    if capped.count > 600 {
        failures.append("speakable-text.capsLongParagraph: length \(capped.count) > 600")
    }
    if !capped.hasSuffix(".") {
        failures.append("speakable-text.capsLongParagraph: does not end on a sentence boundary: \(capped.suffix(20).debugDescription)")
    }

    return failures
}
