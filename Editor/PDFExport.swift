import AppKit
import KayakomaKit
import UniformTypeIdentifiers

/// Saves a document as PDF, after asking where and on which paper size.
@MainActor
enum PDFExport {
    enum PaperSize: Int, CaseIterable {
        case a4, letter

        var size: CGSize {
            switch self {
            case .a4: MarkdownPDFExporter.a4
            case .letter: MarkdownPDFExporter.letter
            }
        }

        var title: String {
            switch self {
            case .a4: String(localized: "A4")
            case .letter: String(localized: "US Letter")
            }
        }
    }

    static func run(document: RenderedDocument, theme: Theme, baseURL: URL?, fileName: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + ".pdf"
        panel.title = String(localized: "Exporter en PDF")
        let paperSize = NSPopUpButton()
        for size in PaperSize.allCases {
            paperSize.addItem(withTitle: size.title)
            paperSize.lastItem?.tag = size.rawValue
        }
        paperSize.selectItem(withTag: PaperSize.a4.rawValue)
        panel.accessoryView = accessory(label: String(localized: "Format du papier :"), control: paperSize)

        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let size = PaperSize(rawValue: paperSize.selectedTag()) ?? .a4
            let exporter = MarkdownPDFExporter(theme: theme, baseURL: baseURL, pageSize: size.size)
            do {
                try exporter.pdfData(for: document).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    private static func accessory(label: String, control: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        let stack = NSStackView(views: [text, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.setFrameSize(stack.fittingSize)
        return stack
    }
}
