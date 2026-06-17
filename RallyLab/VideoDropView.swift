//
//  VideoDropView.swift
//  RallyLab
//
//  AppKit-backed drop target. SwiftUI's onDrop can't fulfill file promises
//  from sandboxed sources like Photos (the source app gets a permission error
//  writing into SwiftUI's staging folder), so this uses NSFilePromiseReceiver,
//  which grants the source proper write access to the destination we choose.
//

import AppKit
import SwiftUI

struct VideoDropView: NSViewRepresentable {
    let model: RallyLabModel

    func makeNSView(context: Context) -> DropNSView {
        let view = DropNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.model = model
    }
}

final class DropNSView: NSView {
    weak var model: RallyLabModel?
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
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // Photos-style drags carry BOTH a file promise and a file URL into the
        // protected Photos library package, which we can't read — so prefer
        // the promise whenever one is present, and only treat promise-less
        // drags (Finder) as plain file URLs.
        let receiver = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver])?.first

        if receiver == nil,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], let url = urls.first {
            model?.loadVideo(url)
            return true
        }

        guard let receiver else { return false }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            model?.setStatus("Import failed: \(error.localizedDescription)")
            return false
        }

        model?.setStatus("Importing video…")
        receiver.receivePromisedFiles(atDestination: stagingDir, options: [:], operationQueue: promiseQueue) { fileURL, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.model?.setStatus("Import failed: \(error.localizedDescription)")
                } else {
                    self?.model?.importPromisedFile(fileURL)
                }
            }
        }
        return true
    }
}
