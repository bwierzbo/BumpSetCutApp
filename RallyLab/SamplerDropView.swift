//
//  SamplerDropView.swift
//  RallyLab
//
//  Drop target for the Sampler tab: any number of videos or folders, from
//  Finder or from Photos. Photos hands over file promises rather than paths
//  (its library is off-limits), so those are received into ~/Movies/RallyLab
//  first — the same place the Pipeline tab's drops land — and then queued.
//

import AppKit
import SwiftUI

struct SamplerDropView: NSViewRepresentable {
    let onDrop: ([URL]) -> Void
    let onStatus: (String) -> Void

    func makeNSView(context: Context) -> SamplerDropNSView {
        let view = SamplerDropNSView()
        view.onDrop = onDrop
        view.onStatus = onStatus
        return view
    }

    func updateNSView(_ nsView: SamplerDropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.onStatus = onStatus
    }
}

final class SamplerDropNSView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    private let promiseQueue = OperationQueue()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                + [.fileURL]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                         as? [NSFilePromiseReceiver]) ?? []

        // Finder drags: plain file URLs, possibly many.
        if receivers.isEmpty {
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            onDrop(urls)
            return true
        }

        // Photos drags: receive every promise into the import folder, then
        // queue them all at once.
        let importDir = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RallyLab", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        } catch {
            onStatus("Import failed: \(error.localizedDescription)")
            return false
        }

        onStatus("Importing \(receivers.count) item\(receivers.count == 1 ? "" : "s") from Photos…")
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: importDir, options: [:], operationQueue: promiseQueue) { url, error in
                if error == nil {
                    lock.lock(); received.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if received.isEmpty {
                self?.onStatus("Photos import failed.")
            } else {
                self?.onDrop(received)
            }
        }
        return true
    }
}
