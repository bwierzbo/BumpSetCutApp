
//
//  LibraryView.swift
//  BumpSetCut
//
//  Rebuilt 2025-08-10: Files-style browser for videos in app sandbox
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers
import PhotosUI
import QuickLookThumbnailing

// MARK: - Transferables (Photos import)
struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let src = received.file
            let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return PickedVideo(url: dst)
        }
    }
}

// MARK: - File model
struct FileItem: Identifiable, Hashable {
    enum Kind: String { case folder, video, other }
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let kind: Kind
    let size: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let duration: Double? // seconds for video

    init(url: URL,
         isDirectory: Bool,
         size: Int64?,
         creationDate: Date?,
         modificationDate: Date?,
         duration: Double?) {
        self.id = url
        self.url = url
        self.isDirectory = isDirectory
        self.name = url.lastPathComponent
        if isDirectory { self.kind = .folder }
        else if ["mov","mp4"].contains(url.pathExtension.lowercased()) { self.kind = .video }
        else { self.kind = .other }
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.duration = duration
    }
}

// MARK: - Services
final class FileSystemService {
    static let shared = FileSystemService()

    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "fs.io", qos: .userInitiated)

    var documentsRoot: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func listItems(at directory: URL) async -> [FileItem] {
        await withCheckedContinuation { cont in
            ioQueue.async {
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
                let fm = FileManager.default
                guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                    cont.resume(returning: [])
                    return
                }
                let items: [FileItem] = urls.compactMap { url in
                    let res = try? url.resourceValues(forKeys: Set(keys))
                    let isDir = res?.isDirectory ?? false
                    let duration: Double? = nil
                    // Defer duration loading to UI to avoid deprecated synchronous access
                    return FileItem(url: url,
                                    isDirectory: isDir,
                                    size: (res?.fileSize).map { Int64($0) },
                                    creationDate: res?.creationDate,
                                    modificationDate: res?.contentModificationDate,
                                    duration: duration)
                }
                cont.resume(returning: items)
            }
        }
    }

    func createFolder(named name: String, at directory: URL) throws -> URL {
        let safe = sanitizeName(name)
        guard !safe.isEmpty else { throw NSError(domain: "fs", code: 1) }
        let baseURL = directory.appendingPathComponent(safe, isDirectory: true)
        let unique = uniqueDirectoryURL(baseURL)
        try fm.createDirectory(at: unique, withIntermediateDirectories: true)
        return unique
    }

    func rename(item url: URL, to newName: String) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = sanitizeName(newName)
        let target = dir.appendingPathComponent(base).appendingPathExtension(ext)
        let unique = uniqueFileURL(target)
        try fm.moveItem(at: url, to: unique)
        return unique
    }

    func delete(urls: [URL]) throws {
        for u in urls { try fm.removeItem(at: u) }
    }

    func move(urls: [URL], toFolder dest: URL) throws -> [URL] {
        var moved: [URL] = []
        for src in urls {
            let name = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            let target = dest.appendingPathComponent(name).appendingPathExtension(ext)
            let unique = fm.fileExists(atPath: target.path) ? uniqueFileURL(target) : target
            try fm.moveItem(at: src, to: unique)
            moved.append(unique)
        }
        return moved
    }

    func copyIn(from externalURLs: [URL], toFolder dest: URL) throws -> [URL] {
        var copied: [URL] = []
        for src in externalURLs {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
            let target = dest.appendingPathComponent(base).appendingPathExtension(ext)
            let unique = fm.fileExists(atPath: target.path) ? uniqueFileURL(target) : target
            try fm.copyItem(at: src, to: unique)
            copied.append(unique)
        }
        return copied
    }

    // MARK: - Helpers
    private func sanitizeName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
    }

    private func uniqueFileURL(_ desired: URL) -> URL {
        var candidate = desired
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        let dir = candidate.deletingLastPathComponent()
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    private func uniqueDirectoryURL(_ desired: URL) -> URL {
        var candidate = desired
        let dir = candidate.deletingLastPathComponent()
        let base = desired.lastPathComponent
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i))", isDirectory: true)
            i += 1
        }
        return candidate
    }
}

// MARK: - Thumbnails
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) -> Task<UIImage?, Never> {
        if let img = cache.object(forKey: url as NSURL) {
            return Task { img }
        }
        if let t = inflight[url] { return t }
        let task = Task { [weak self] () -> UIImage? in
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
            do {
                let img = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).uiImage
                self?.cache.setObject(img, forKey: url as NSURL)
                return img
            } catch { return nil }
        }
        inflight[url] = task
        Task { [weak self] in
            _ = await task.value
            self?.inflight[url] = nil
        }
        return task
    }
}

// MARK: - Sorting / View modes
enum SortKey: String, CaseIterable { case name = "Name", date = "Date", size = "Size", kind = "Kind" }
enum ViewMode: String { case list, grid }

// MARK: - LibraryView (root navigator)
struct LibraryView: View {
    @State private var root: URL = FileSystemService.shared.documentsRoot

    var body: some View {
        NavigationStack {
            BrowserView(current: root)
        }
        .navigationTitle("")
        .preferredColorScheme(.dark)
    }
}

// MARK: - Browser View
struct BrowserView: View {
    @State private var items: [FileItem] = []
    @State private var loading = false
    @State private var error: String? = nil

    @State private var viewMode: ViewMode = .grid
    @State private var sortKey: SortKey = .name
    @State private var ascending: Bool = true
    @State private var searchText: String = ""

    @State private var selection = Set<URL>()
    @State private var isSelecting = false

    // Sheets
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    @State private var showingMoveSheet = false

    @State private var showingPhotosPicker = false
    @State private var pickedItem: PhotosPickerItem?

    @State private var showingFileImporter = false

    let current: URL
    private let fs = FileSystemService.shared

    var body: some View {
        content
            .navigationTitle(current == fs.documentsRoot ? "On My iPhone" : current.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { buildToolbar() }
            .searchable(text: $searchText)
            .onAppear { refresh() }
            .onChange(of: current) { _, _ in refresh() }
            .onChange(of: pickedItem) { _, it in if let it = it { importFromPhotos(it) } }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyStateView(showUpload: current == fs.documentsRoot, onImport: { showingPhotosPicker = true })
            } else {
                if viewMode == .list { listView } else { gridView }
            }
        }
        .animation(.default, value: items)
    }

    private var filteredItems: [FileItem] {
        let f = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = items
        if !f.isEmpty {
            out = out.filter { $0.name.localizedCaseInsensitiveContains(f) }
        }
        out.sort { a, b in
            switch sortKey {
            case .name: return ascending ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            case .date:
                let ad = a.modificationDate ?? a.creationDate ?? .distantPast
                let bd = b.modificationDate ?? b.creationDate ?? .distantPast
                return ascending ? ad < bd : ad > bd
            case .size:
                let asz = a.size ?? -1
                let bsz = b.size ?? -1
                return ascending ? asz < bsz : asz > bsz
            case .kind:
                return ascending ? a.kind.rawValue < b.kind.rawValue : a.kind.rawValue > b.kind.rawValue
            }
        }
        return out
    }

    // MARK: List
    private var listView: some View {
        List(selection: $selection) {
            ForEach(filteredItems) { item in
                row(for: item)
                    .contentShape(Rectangle())
                    .onTapGesture { tap(item) }
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
                    .contextMenu { contextMenu(item) }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier],
                delegate: DirectoryDropDelegate(destURL: current,
                                                perform: { urls in dropToCurrentFolder(urls) }))
        // Modern drop destinations for in-app drag
        .dropDestination(for: URL.self) { urls, _ in dropToCurrentFolder(urls); return true }
        .dropDestination(for: String.self) { strings, _ in
            let urls = strings.compactMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }
            dropToCurrentFolder(urls); return true
        }
        .listStyle(.plain)
        .listRowSeparator(.visible)
        .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))
    }

    // MARK: Grid
    private var gridView: some View {
        ScrollView {
            let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredItems) { item in
                    gridCell(for: item)
                        .contextMenu { contextMenu(item) }
                        .onTapGesture { tap(item) }
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                }
            }
            .padding(12)
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier],
                delegate: DirectoryDropDelegate(destURL: current,
                                                perform: { urls in dropToCurrentFolder(urls) }))
        // Modern drop destinations for in-app drag
        .dropDestination(for: URL.self) { urls, _ in dropToCurrentFolder(urls); return true }
        .dropDestination(for: String.self) { strings, _ in
            let urls = strings.compactMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }
            dropToCurrentFolder(urls); return true
        }
    }

    // MARK: Row / Cell
    private func row(for item: FileItem) -> some View {
        HStack(spacing: 12) {
            ThumbView(url: item.url, kind: item.kind, size: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.kind == .folder {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // Modern drop destinations for in-app drag
        .dropDestination(for: URL.self) { urls, _ in
            if item.kind == .folder { dropPerform(urls, to: item); return true }
            return false
        }
        .dropDestination(for: String.self) { strings, _ in
            if item.kind == .folder {
                let urls = strings.compactMap { URL(string: $0) ?? URL(string: $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") }
                dropPerform(urls, to: item)
                return true
            }
            return false
        }
    }

    private func gridCell(for item: FileItem) -> some View {
        VStack(spacing: 8) {
            ThumbView(url: item.url, kind: item.kind, size: 110)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.name).font(.footnote).multilineTextAlignment(.center).lineLimit(2)
            Text(subtitle(for: item)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        // Modern drop destinations for in-app drag
        .dropDestination(for: URL.self) { urls, _ in
            if item.kind == .folder { dropPerform(urls, to: item); return true }
            return false
        }
        .dropDestination(for: String.self) { strings, _ in
            if item.kind == .folder {
                let urls = strings.compactMap { URL(string: $0) ?? URL(string: $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") }
                dropPerform(urls, to: item)
                return true
            }
            return false
        }
    }

    private func subtitle(for item: FileItem) -> String {
        switch item.kind {
        case .folder:
            return "Folder"
        case .video:
            let dur = item.duration.map { formatDuration($0) } ?? ""
            if let s = item.size { return dur.isEmpty ? byteString(s) : "\(dur) • \(byteString(s))" }
            return dur
        case .other:
            if let s = item.size { return byteString(s) }
            return "File"
        }
    }

    // MARK: Context Menu
    @ViewBuilder
    private func contextMenu(_ item: FileItem) -> some View {
        if item.kind == .folder {
            Button("Open") { tap(item) }
        } else {
            Button("Play") { open(item) }
            Button("Share") { share([item.url]) }
        }
        Button("Rename…") { renamePrompt(item) }
        Button("Move…") { selection = [item.url]; showingMoveSheet = true }
        Divider()
        Button(role: .destructive) { deleteConfirm([item.url]) } label: { Text("Delete") }
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private func buildToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if current != fs.documentsRoot {
                Button(action: { pop() }) { Image(systemName: "chevron.left") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) { viewToggle }
        ToolbarItem(placement: .navigationBarTrailing) { sortMenu }
        ToolbarItem(placement: .principal) { addMenu }
        ToolbarItem(placement: .bottomBar) {
            if isSelecting {
                selectionBar
            } else {
                Button("Select") { isSelecting = true }
            }
        }
    }

    private var viewToggle: some View {
        Button(action: { viewMode = (viewMode == .list ? .grid : .list) }) {
            Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                ForEach(SortKey.allCases, id: \.self) { key in Text(key.rawValue).tag(key) }
            }
            Toggle(isOn: $ascending) { Text("Ascending") }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var addMenu: some View {
        Menu {
            if current == fs.documentsRoot {
                Button("Upload from Photos") { showingPhotosPicker = true }
                Button("Import from Files") { showingFileImporter = true }
                Divider()
            }
            Button("New Folder…") { showingNewFolder = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill"); Text("Add")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickedItem, matching: .videos)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie, .mpeg4Movie, .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): doImport(urls)
            case .failure(let err): print("fileImporter error: \(err)")
            }
        }
        .sheet(isPresented: $showingNewFolder) { newFolderSheet }
        .sheet(isPresented: $showingMoveSheet) { moveSheet }
    }

    private var selectionBar: some View {
        HStack {
            Button("Move") { showingMoveSheet = true }.disabled(selection.isEmpty)
            Spacer()
            Button("Share") { share(Array(selection)) }.disabled(selection.isEmpty)
            Spacer()
            Button(role: .destructive) { deleteConfirm(Array(selection)) } label: { Text("Delete") }.disabled(selection.isEmpty)
            Spacer()
            Button("Cancel") { selection.removeAll(); isSelecting = false }
        }
    }

    private var newFolderSheet: some View {
        VStack(spacing: 16) {
            Text("New Folder").font(.headline)
            TextField("Folder name", text: $newFolderName).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showingNewFolder = false }
                Spacer()
                Button("Create") { createFolder() }.disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .presentationDetents([.fraction(0.25)])
    }

    private var moveSheet: some View {
        FolderPickerView(root: fs.documentsRoot, initial: current) { dest in
            doMove(to: dest)
        }
    }

    // MARK: Actions
    private func refresh() {
        loading = true
        Task { @MainActor in
            let listed = await fs.listItems(at: current)
            self.items = listed
            self.loading = false
        }
    }

    private func tap(_ item: FileItem) {
        if isSelecting {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            return
        }
        if item.kind == .folder { push(item.url) } else { open(item) }
    }

    private func open(_ item: FileItem) {
        let player = AVPlayer(url: item.url)
        let vc = AVPlayerViewController()
        vc.player = player
        UIApplication.shared.firstKeyWindow?.rootViewController?.present(vc, animated: true) { player.play() }
    }

    private func share(_ urls: [URL]) {
        guard let vc = UIApplication.shared.firstKeyWindow?.rootViewController else { return }
        let ac = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.present(ac, animated: true)
    }

    private func renamePrompt(_ item: FileItem) {
        let alert = UIAlertController(title: "Rename", message: item.name, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "New name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            do {
                _ = try fs.rename(item: item.url, to: text)
                refresh()
            } catch { print("rename error: \(error)") }
        })
        UIApplication.shared.firstKeyWindow?.rootViewController?.present(alert, animated: true)
    }

    private func deleteConfirm(_ urls: [URL]) {
        guard let vc = UIApplication.shared.firstKeyWindow?.rootViewController else { return }
        let alert = UIAlertController(title: "Delete", message: "This will permanently delete the selected item(s).", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            do { try fs.delete(urls: urls); selection.removeAll(); refresh() } catch { print("delete error: \(error)") }
        })
        vc.present(alert, animated: true)
    }

    private func createFolder() {
        do { _ = try fs.createFolder(named: newFolderName, at: current); newFolderName = ""; showingNewFolder = false; refresh() } catch { print("create folder error: \(error)") }
    }

    private func doMove(to dest: URL) {
        do { _ = try fs.move(urls: Array(selection), toFolder: dest); isSelecting = false; selection.removeAll(); showingMoveSheet = false; refresh() } catch { print("move error: \(error)") }
    }

    private func dropPerform(_ urls: [URL], to folder: FileItem) {
        guard folder.kind == .folder else { return }
        do { _ = try fs.move(urls: urls, toFolder: folder.url); refresh() } catch { print("drop move error: \(error)") }
    }

    private func dropToCurrentFolder(_ urls: [URL]) {
        do { _ = try fs.move(urls: urls, toFolder: current); refresh() }
        catch { print("drop move error: \(error)") }
    }

    private func doImport(_ urls: [URL]) {
        do { _ = try fs.copyIn(from: urls, toFolder: fs.documentsRoot); refresh() } catch { print("import error: \(error)") }
    }

    private func importFromPhotos(_ item: PhotosPickerItem) {
        Task {
            do {
                if let picked = try await item.loadTransferable(type: PickedVideo.self) {
                    doImport([picked.url])
                }
            } catch { print("photos import error: \(error)") }
        }
    }

    private func push(_ url: URL) {
        // Push a new browser for the folder
        guard let window = UIApplication.shared.firstKeyWindow else { return }
        let vc = UIHostingController(rootView: BrowserView(current: url))
        window.rootViewController?.show(vc, sender: nil)
    }

    private func pop() { UIApplication.shared.firstKeyWindow?.rootViewController?.dismiss(animated: true) }
}

// MARK: - Thumb View
struct ThumbView: View {
    let url: URL
    let kind: FileItem.Kind
    var size: CGFloat = 110
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image { Image(uiImage: img).resizable().scaledToFill() }
            else {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15))
                Image(systemName: kind == .folder ? "folder" : (kind == .video ? "film" : "doc")).font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard kind != .folder else { return }
        let task = ThumbnailCache.shared.thumbnail(for: url, size: CGSize(width: size * 2, height: size * 2), scale: UIScreen.main.scale)
        self.image = await task.value
    }
}

// MARK: - Folder Picker (Move sheet)
struct FolderPickerView: View {
    let root: URL
    @State var current: URL
    let onPick: (URL) -> Void

    init(root: URL, initial: URL, onPick: @escaping (URL) -> Void) {
        self.root = root
        self._current = State(initialValue: initial)
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    private let fs = FileSystemService.shared

    var body: some View {
        NavigationView {
            ScrollView {
                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(folders, id: \.self) { url in
                        Button(action: { current = url; Task { await load() } }) {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.fill").font(.system(size: 28))
                                Text(url.lastPathComponent).font(.subheadline).multilineTextAlignment(.center).lineLimit(2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(current == root ? "Move to Folder" : current.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Move Here") { onPick(current); dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    if current != root { Button(action: { current = current.deletingLastPathComponent(); Task { await load() } }) { Image(systemName: "chevron.left") } }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        let items = await fs.listItems(at: current)
        self.folders = items.filter { $0.kind == .folder }.map { $0.url }
    }
}

// MARK: - Drop Delegate
struct FolderDropDelegate: DropDelegate {
    let dest: FileItem
    let perform: ([URL], FileItem) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard dest.kind == .folder else { return false }
        return info.hasItemsConforming(to: [.fileURL, .url, .text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dest.kind == .folder else { return false }

        var providers = info.itemProviders(for: [.fileURL])
        if providers.isEmpty { providers = info.itemProviders(for: [.url]) }
        if providers.isEmpty { providers = info.itemProviders(for: [.text]) }

        var urls: [URL] = []
        let group = DispatchGroup()

        func handleValue(_ value: NSSecureCoding?) {
            if let u = value as? URL {
                urls.append(u)
            } else if let data = value as? Data {
                if let s = String(data: data, encoding: .utf8) {
                    if let u = URL(string: s) { urls.append(u) }
                    else { urls.append(URL(fileURLWithPath: s)) }
                } else if let u = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(u)
                }
            } else if let s = value as? String {
                if let u = URL(string: s) { urls.append(u) } else { urls.append(URL(fileURLWithPath: s)) }
            }
        }

        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                p.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) { perform(urls, dest) }
        return true
    }
}

struct DirectoryDropDelegate: DropDelegate {
    let destURL: URL
    let perform: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .url, .text]) }

    func performDrop(info: DropInfo) -> Bool {
        var providers = info.itemProviders(for: [.fileURL])
        if providers.isEmpty { providers = info.itemProviders(for: [.url]) }
        if providers.isEmpty { providers = info.itemProviders(for: [.text]) }

        var urls: [URL] = []
        let group = DispatchGroup()

        func handleValue(_ value: NSSecureCoding?) {
            if let u = value as? URL {
                urls.append(u)
            } else if let data = value as? Data {
                if let s = String(data: data, encoding: .utf8) {
                    if let u = URL(string: s) { urls.append(u) }
                    else { urls.append(URL(fileURLWithPath: s)) }
                } else if let u = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(u)
                }
            } else if let s = value as? String {
                if let u = URL(string: s) { urls.append(u) } else { urls.append(URL(fileURLWithPath: s)) }
            }
        }

        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                p.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { value, _ in
                    handleValue(value); group.leave()
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) { perform(urls) }
        return true
    }
}

// MARK: - Helpers UI & Formatters
struct EmptyStateView: View {
    let showUpload: Bool
    let onImport: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 48)).foregroundStyle(.gray)
            Text("No files yet").foregroundStyle(.secondary)
            if showUpload {
                Button("Upload from Photos", action: onImport)
            }
        }
        .padding(.top, 40)
    }
}

func byteString(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    return fmt.string(fromByteCount: bytes)
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

// MARK: - UIApplication helpers
extension UIApplication {
    var firstKeyWindow: UIWindow? { connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first }
}

extension UIWindowScene { var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}
