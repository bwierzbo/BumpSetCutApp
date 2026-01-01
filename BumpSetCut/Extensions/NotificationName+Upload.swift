//
//  NotificationName+Upload.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import Foundation

extension Notification.Name {
    static let uploadCompleted = Notification.Name("uploadCompleted")
    static let uploadFailed = Notification.Name("uploadFailed")
    static let uploadProgress = Notification.Name("uploadProgress")
    static let libraryContentChanged = Notification.Name("libraryContentChanged")
}