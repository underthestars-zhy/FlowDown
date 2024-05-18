//
//  ContentView.swift
//  FlowDown
//
//  Created by 朱浩宇 on 2024/2/4.
//

import SwiftUI
import Parma
import SwiftUIX
@_spi(Advanced) import SwiftUIIntrospect
import NaturalLanguage
import CoreML
import Markdown

struct ContentView: View {
    @State var content = ""
    @FocusState var focus: Bool
    @State var modelTriggedChange = false

    @State var hasFirst = false
    @State var hasSecond = false
    @State var hasThird = false

    var body: some View {
        HStack {
            TextEditor(text: $content)
            .frame(maxWidth: .infinity)
            .focused($focus)
            .onAppear {
                focus = true
            }
            #if !os(macOS)
            .introspect(.textEditor, on: .iOS(.v17...)) { textEditor in
                textEditor.textContainerInset = UIEdgeInsets.zero
                textEditor.textContainer.lineFragmentPadding = 0
            }
            #else
            .introspect(.textEditor, on: .macOS(.v13...)) { textEditor in
                textEditor.backgroundColor = .clear
            }
            #endif
            .padding(40)
            .onChange(of: content) { old, new in
                if new.isEmpty { hasFirst = false; hasSecond = false; hasThird = false }
                if modelTriggedChange { modelTriggedChange = false; return }
                guard !new.isEmpty else { return }

                if new[new.index(before: new.endIndex)] == "\n" && (new.count < 2 || new[new.index(new.endIndex, offsetBy: -2)] != "\n") {
                    let oldBlocks = blocks(of: old)
                    var newBlocks = blocks(of: new)

                    print(oldBlocks, newBlocks)

                    if (countValidBlocks(oldBlocks)-1) < countValidBlocks(newBlocks) && !newBlocks[newBlocks.count-1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let newBlock = newBlocks[newBlocks.count-1]

                        let modifiedNewBlock = modifyBlock(newBlock)

                        print("modified:", modifiedNewBlock)

                        newBlocks[newBlocks.count-1] = modifiedNewBlock

                        content = text(from: newBlocks)
                    }
                }
            }

            Divider()

            VStack {
                HStack {
//                    Parma(content)
                    Markdown(content: $content)

                    Spacer()
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func blocks(of input: String) -> [String] {
        let paragraphs = input.components(separatedBy: "\n\n")

        var result: [String] = []
        for paragraph in paragraphs {
            result.append(contentsOf: paragraph.components(separatedBy: "\n").filter { !$0.isEmpty })
            if paragraph != paragraphs.last {
                result.append("\n")
            }
        }

        return result
    }

    func countValidBlocks(_ blocks: [String]) -> Int {
        blocks.filter {
            !$0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        }.count
    }

    func modifyBlock(_ block: String) -> String {
        do {
            print(block)
            let mlModel = try MarkdownTextBlockClassification(configuration: MLModelConfiguration()).model
            let predictor = try NLModel(mlModel: mlModel)
            let labels = predictor.predictedLabelHypotheses(for: block, maximumCount: 4)

            print(labels)

            guard !labels.isEmpty else { return block }

            switch checkLabel(labels) {
            case "h1":
                hasFirst = true
                modelTriggedChange = true
                return "# \(block)"
            case "h2":
                hasSecond = true
                modelTriggedChange = true
                return "## \(block)"
            case "h3":
                hasThird = true
                modelTriggedChange = true
                return "### \(block)"
            case "body": return modifyBody(block)
            default: return block
            }
        } catch {
            print("Error: ", error)
            return block
        }
    }

    func checkLabel(_ labels: [String : Double]) -> String {
        let sorted = labels.sorted { f1, f2 in
            f1.value > f2.value
        }.map(\.key)

        for label in sorted {
            switch label {
            case "h1": if hasFirst { break } else { return label }
            case "h2": if hasFirst { return label }
            case "h3": if hasFirst && hasSecond { return label }
            case "body": return label
            default: break
            }
        }

        return "body"
    }

    func modifyBody(_ body: String) -> String {
        guard !containsMarkdown(text: body) else { return body }

        do {
            var text = body

            let mlModel = try MarkdownStyleTagging(configuration: MLModelConfiguration()).model

            let customModel = try NLModel(mlModel: mlModel)
            let customTagScheme = NLTagScheme("MarkFlow")

            let tagger = NLTagger(tagSchemes: [.nameType, customTagScheme])
            tagger.string = text
            tagger.setModels([customModel], forTagScheme: customTagScheme)

            var needModified = [(Range<String.Index>, String)]()

            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: customTagScheme, options: [.joinContractions, .omitWhitespace]) { tag, tokenRange  in
                if let tag = tag {
                    if tag.rawValue != "normal" {
                        needModified.append((tokenRange, tag.rawValue))
                    }
                    print("\(text[tokenRange]): \(tag.rawValue)")
                }
                return true
            }

            var offset = 0

            var index = 0

            func findUpperBound() -> String.Index {
                let type = needModified[index].1
                if index + 1 < needModified.count {
                    while index + 1 < needModified.count {
                        if needModified[index + 1].1 != type {
                            return needModified[index].0.upperBound
                        }

                        index += 1
                    }

                    return needModified[needModified.count - 1].0.upperBound
                } else {
                    return needModified[index].0.upperBound
                }
            }

            while index < needModified.count {
                let modify = needModified[index]

                switch modify.1 {
                case "code":
                    text.insert("`", at: text.index(modify.0.lowerBound, offsetBy: offset))
                    offset += 1
                    text.insert("`", at: text.index(findUpperBound(), offsetBy: offset))
                    offset += 1
                case "bold":
                    text.insert(contentsOf: "**", at: text.index(modify.0.lowerBound, offsetBy: offset))
                    offset += 2
                    text.insert(contentsOf: "**", at: text.index(findUpperBound(), offsetBy: offset))
                    offset += 2
                case "italic":
                    text.insert("*", at: text.index(modify.0.lowerBound, offsetBy: offset))
                    offset += 1
                    text.insert("*", at: text.index(findUpperBound(), offsetBy: offset))
                    offset += 1
                default: break
                }

                index += 1
            }

            if !needModified.isEmpty { modelTriggedChange = true }

            return text
        } catch {
            print("Error: ", error)
            return body
        }
    }

    func text(from blocks: [String]) -> String {
        blocks.reduce(into: "") { partialResult, block in
            partialResult += block + (block == "\n" ? "" : "\n")
        }
    }

    func containsMarkdown(text: String) -> Bool {
        let markdownPatterns = [
            "\\#{1,6}\\s", // Headings
            "\\*{1,2}[^*]+\\*{1,2}", // Bold and italic
            "\\_[^_]+\\_", // Italic
            "\\!\\[[^\\]]+\\]\\([^\\)]+\\)", // Images
            "\\[[^\\]]+\\]\\([^\\)]+\\)", // Links
            "`[^`]+`" // Inline code
        ]

        for pattern in markdownPatterns {
            if let regex = try? Regex(pattern) {
                if let matches = try? regex.firstMatch(in: text), !matches.isEmpty { return true }
            }
        }

        return false
    }
}

#Preview {
    ContentView()
}
