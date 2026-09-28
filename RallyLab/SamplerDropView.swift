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
    /// A drag is hovering over the view (true) or has left or landed (false).
    var onTargeted: (Bool) -> Void = { _ in }
    /// Clicks that land on the drop view itself rather than on SwiftUI
    /// content above it.
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> SamplerDropNSView {
        let view = SamplerDropNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SamplerDropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.onStatus = onStatus
        nsView.onTargeted = onTargeted
        nsView.onClick = onClick
    }
}

final class SamplerDropNSView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onTargeted: (Bool) -> Void = { _ in }
    var onClick: (() -> Void)?
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

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
