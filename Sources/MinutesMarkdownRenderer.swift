import AppKit
import Foundation

/// Foundation parses Markdown; AppKit lays out a selectable, searchable document.
/// Rendering stays local, including links and image descriptions.
enum MinutesMarkdownRenderer {
    private static let ink = NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.29, alpha: 1)
    private static let violet = NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.72, alpha: 1)
    private static let pale = NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.98, alpha: 1)

    private struct Block {
        let identity: Int
        let intents: [PresentationIntent.IntentType]
        var text: AttributedString
    }

    static func render(_ markdown: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink])
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let identity = intents.first?.identity ?? -1
            let text = AttributedString(parsed[run.range])
            if blocks.last?.identity == identity { blocks[blocks.count - 1].text.append(text) }
            else { blocks.append(Block(identity: identity, intents: intents, text: text)) }
        }
        let result = NSMutableAttributedString(string: "")
        var tables: [Int: NSTextTable] = [:]
        var listedItems = Set<Int>()
        for block in blocks {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 11
            var font = NSFont.systemFont(ofSize: 14)
            var color = ink
            var prefix = ""
            var isCode = false
            var tableCell: (column: Int, row: Int, header: Bool)?

            for intent in block.intents {
                switch intent.kind {
                case .header(let level):
                    font = .systemFont(ofSize: level == 1 ? 25 : level == 2 ? 18 : 15, weight: .bold)
                    color = level == 2 ? violet : ink
                    paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : (level <= 2 ? 22 : 13)
                    paragraph.paragraphSpacing = level == 1 ? 18 : 9
                    paragraph.headerLevel = level
                case .codeBlock:
                    font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    isCode = true
                    let box = NSTextBlock()
                    box.backgroundColor = pale
                    box.setWidth(10, type: .absoluteValueType, for: .padding)
                    paragraph.textBlocks = [box]
                case .tableCell(let column): tableCell = (column, 0, false)
                case .tableHeaderRow: tableCell?.header = true
                case .tableRow(let row): tableCell?.row = row
                default: break
                }
            }

            if let item = block.intents.first(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = item.kind {
                let lists = block.intents.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
                let indent = CGFloat(max(0, lists.count - 1)) * 20
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 22
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                paragraph.paragraphSpacing = 7
                if listedItems.insert(item.identity).inserted {
                    prefix = lists.first?.kind == .orderedList ? "\(ordinal).\t" : "•\t"
                } else { paragraph.firstLineHeadIndent = paragraph.headIndent }
            }

            if block.intents.contains(where: { $0.kind == .blockQuote }) {
                let quote = NSTextBlock()
                quote.backgroundColor = pale
                quote.setWidth(10, type: .absoluteValueType, for: .padding)
                quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(violet)
                paragraph.textBlocks = [quote]
            }

            if let cell = tableCell,
               let tableIntent = block.intents.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = tableIntent.kind, columns.indices.contains(cell.column) {
                let table: NSTextTable
                if let existing = tables[tableIntent.identity] { table = existing }
                else {
                    table = NSTextTable()
                    table.numberOfColumns = columns.count
                    table.layoutAlgorithm = .fixedLayoutAlgorithm
                    table.collapsesBorders = true
                    table.hidesEmptyCells = false
                    table.setContentWidth(100, type: .percentageValueType)
                    tables[tableIntent.identity] = table
                }
                let box = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column, columnSpan: 1)
                box.setContentWidth(columns.count == 3 ? (cell.column == 0 ? 56 : 22) : 100 / CGFloat(columns.count), type: .percentageValueType)
                box.setWidth(9, type: .absoluteValueType, for: .padding)
                box.setWidth(0.5, type: .absoluteValueType, for: .border)
                box.setBorderColor(NSColor(calibratedWhite: 0.85, alpha: 1))
                box.backgroundColor = cell.header ? pale : cell.row.isMultiple(of: 2) ? NSColor(calibratedWhite: 0.985, alpha: 1) : .white
                box.verticalAlignment = .topAlignment
                paragraph.textBlocks = [box]
                paragraph.paragraphSpacing = 0
                paragraph.lineSpacing = 4
                switch columns[cell.column].alignment {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                @unknown default: paragraph.alignment = .left
                }
                font = .systemFont(ofSize: 13, weight: cell.header ? .semibold : .regular)
            }

            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: base)) }
            for run in block.text.runs {
                var attributes = base
                var runFont = font
                let inline = run.inlinePresentationIntent ?? []
                if inline.contains(.code) || isCode { runFont = .monospacedSystemFont(ofSize: 12, weight: .regular) }
                if inline.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                attributes[.font] = runFont
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if inline.contains(.code) { attributes[.backgroundColor] = pale }
                if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    attributes[.link] = link
                    attributes[.foregroundColor] = violet
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: String(block.text[run.range].characters), attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        return result
    }
}
