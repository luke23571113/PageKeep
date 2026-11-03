import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum NotebookAppearance {
    struct Symbol: Identifiable {
        let id: String
        let title: String
    }

    struct PaletteColor: Identifiable {
        let id: String
        let title: String
        let color: Color
    }

    static let symbols = [
        Symbol(id: "book.closed", title: "Book"),
        Symbol(id: "books.vertical", title: "Books"),
        Symbol(id: "doc.text", title: "Document"),
        Symbol(id: "folder", title: "Folder"),
        Symbol(id: "graduationcap", title: "Graduation Cap"),
        Symbol(id: "pencil", title: "Pencil"),
        Symbol(id: "plus.forwardslash.minus", title: "Calculator"),
        Symbol(id: "function", title: "Function"),
        Symbol(id: "globe", title: "Globe"),
        Symbol(id: "leaf", title: "Leaf"),
        Symbol(id: "music.note", title: "Music"),
        Symbol(id: "lightbulb", title: "Light Bulb")
    ]

    static let colors = [
        PaletteColor(id: "default", title: "Default", color: .accentColor),
        PaletteColor(id: "red", title: "Red", color: .red),
        PaletteColor(id: "orange", title: "Orange", color: .orange),
        PaletteColor(id: "yellow", title: "Yellow", color: .yellow),
        PaletteColor(id: "green", title: "Green", color: .green),
        PaletteColor(id: "teal", title: "Teal", color: .teal),
        PaletteColor(id: "blue", title: "Blue", color: .blue),
        PaletteColor(id: "indigo", title: "Indigo", color: .indigo),
        PaletteColor(id: "purple", title: "Purple", color: .purple),
        PaletteColor(id: "pink", title: "Pink", color: .pink)
    ]

    static func symbol(_ name: String) -> String {
        guard symbols.contains(where: { $0.id == name }) else {
            return "book.closed"
        }
#if os(macOS)
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return "book.closed" }
#else
        guard UIImage(systemName: name) != nil else { return "book.closed" }
#endif
        return name
    }

    static func color(_ id: String) -> Color {
        colors.first { $0.id == id }?.color ?? .accentColor
    }
}

struct NotebookIcon: View {
    let symbolName: String
    let colorID: String

    init(symbolName: String, colorID: String) {
        self.symbolName = symbolName
        self.colorID = colorID
    }

    init(notebook: Notebook) {
        self.init(symbolName: notebook.symbolName, colorID: notebook.colorID)
    }

    var body: some View {
        Image(systemName: NotebookAppearance.symbol(symbolName))
            .font(.title2)
            .foregroundStyle(NotebookAppearance.color(colorID))
            .frame(width: 48, height: 56)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(NotebookAppearance.color(colorID).opacity(0.08))
            }
            .accessibilityHidden(true)
    }
}
