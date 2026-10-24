import SwiftUI

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var updated: Date = Date()
    var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? L("Nota vuota", "Empty note") : String(first.prefix(40))
    }
}

/// Local notes where you can dictate brain-dumps, to-do lists and drafts.
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()
    @Published var notes: [Note] { didSet { save() } }

    private init() {
        if let data = try? Data(contentsOf: Paths.notes), let notes = try? JSONDecoder().decode([Note].self, from: data), !notes.isEmpty {
            self.notes = notes
        } else {
            notes = [Note(text: "")]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: Paths.notes, options: .atomic) }
    }
}

struct ScratchpadView: View {
    @ObservedObject var store = ScratchpadStore.shared
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.notes.sorted { $0.updated > $1.updated }) { note in
                    VStack(alignment: .leading) {
                        Text(note.title).lineLimit(1)
                        Text(note.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                    }
                    .tag(note.id)
                    .contextMenu {
                        Button(L("Elimina", "Delete"), role: .destructive) {
                            store.notes.removeAll { $0.id == note.id }
                            if store.notes.isEmpty { store.notes = [Note(text: "")] }
                            selection = store.notes.first?.id
                        }
                    }
                }
            }
            .toolbar {
                Button {
                    let note = Note(text: "")
                    store.notes.append(note)
                    selection = note.id
                } label: { Image(systemName: "square.and.pencil") }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let index = store.notes.firstIndex(where: { $0.id == selection }) {
                TextEditor(text: Binding(
                    get: { store.notes[index].text },
                    set: { store.notes[index].text = $0; store.notes[index].updated = Date() }))
                    .font(.system(size: 15))
                    .padding(8)
            } else {
                Text(L("Tieni premuto il tasto dettatura e parla: il testo finisce qui.", "Hold the dictation key and speak: text lands here."))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { selection = selection ?? store.notes.max { $0.updated < $1.updated }?.id }
        .frame(minWidth: 620, minHeight: 420)
    }
}
