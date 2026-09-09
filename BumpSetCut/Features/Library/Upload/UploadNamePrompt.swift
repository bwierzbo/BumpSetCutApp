//
//  UploadNamePrompt.swift
//  BumpSetCut
//
//  Shared upfront naming alert for video uploads. Presented right after
//  picking a video; the import then runs in the background behind the
//  global upload pill. Skip commits nil and the coordinator applies a
//  dated default name.
//

import SwiftUI

extension View {
    func uploadNamePrompt(isPresented: Binding<Bool>, onCommit: @escaping (String?) -> Void) -> some View {
        bscNameAlert(
            title: "Name Your Video",
            message: "Give your video a custom name",
            placeholder: "Video name",
            confirmTitle: "Upload",
            cancelTitle: "Skip",
            isPresented: isPresented,
            onCommit: onCommit
        )
    }
}
