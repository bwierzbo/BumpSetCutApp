//
//  GameReviewFactory.swift
//  BumpSetCut
//
//  Factory for creating the Game Review flow (setup -> review).
//

import SwiftUI

struct GameReviewFactory: View {
    let videoMetadata: VideoMetadata

    @State private var showSetup = true
    @State private var activeSetup: GameSetup?
    @State private var activeResumeState: GameReviewState?

    var body: some View {
        Group {
            if let state = activeResumeState {
                GameReviewView(videoMetadata: videoMetadata, state: state)
            } else if let setup = activeSetup {
                GameReviewView(videoMetadata: videoMetadata, setup: setup)
            } else {
                GameSetupView(
                    videoId: videoMetadata.originalVideoId ?? videoMetadata.id,
                    onStart: { setup in
                        activeSetup = setup
                    },
                    onResume: { state in
                        activeResumeState = state
                    }
                )
            }
        }
    }
}
