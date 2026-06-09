//
//  AudioSessionManager.swift
//  BumpSetCut
//
//  Centralized control of the shared AVAudioSession.
//

import AVFoundation

/// Centralized audio-session control.
///
/// The app plays video with sound, so it uses the `.playback` category. The
/// session must **not** be held active for the whole app lifetime: a
/// permanently-active `.playback` session stalls keyboard presentation by
/// several seconds on real devices, because every first-responder activation
/// has to renegotiate audio routing against the live session.
///
/// Instead we configure the category once at launch and let `AVPlayer` activate
/// the session on demand when it starts playing, then proactively release it
/// when the keyboard appears. Releasing is a no-op while audio is actually
/// playing (the system reports the session busy), so it only frees the session
/// in the idle text-entry case that causes the stall.
enum AudioSessionManager {
    /// Configure the playback category. Call once at launch. Does not activate.
    static func configureCategory() {
        do {
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }

    /// Release the audio session if nothing is actively playing. Safe to call
    /// liberally — when a player is producing audio the session is busy and this
    /// throws, which we ignore, leaving playback untouched.
    static func deactivateIfIdle() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
}
