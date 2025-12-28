import SwiftUI
import AVKit

// MARK: - Rally Video Player

struct RallyVideoPlayer: View {
    let url: URL
    let isActive: Bool
    let size: CGSize
    let playerCache: RallyPlayerCache
    var thumbnail: UIImage? = nil  // Optional thumbnail to show while video loads

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    /// Get or create the player for this specific URL from the cache
    private var player: AVPlayer {
        playerCache.getOrCreatePlayer(for: url)
    }

    var body: some View {
        ZStack {
            Color.black

            // Show thumbnail as background while video loads
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: isPortrait ? .fit : .fill)
                    .clipped()
            }

            // Video player on top (covers thumbnail when playing)
            VideoPlayer(player: player)
                .aspectRatio(contentMode: isPortrait ? .fit : .fill)
                .disabled(true)
                .clipped()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if isActive {
                playerCache.togglePlayPause()
            }
        }
    }
}

// MARK: - Standalone Video Player (for non-cached use)

struct StandaloneRallyVideoPlayer: View {
    let url: URL
    let isActive: Bool
    let size: CGSize

    @StateObject private var playerManager = StandalonePlayerManager()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            Color.black

            if let player = playerManager.player {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: isPortrait ? .fit : .fill)
                    .disabled(true)
                    .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            playerManager.togglePlayPause()
        }
        .onAppear {
            playerManager.setupPlayer(url: url)
            if isActive {
                playerManager.playFromBeginning()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                playerManager.playFromBeginning()
            } else {
                playerManager.pause()
            }
        }
        .onDisappear {
            playerManager.cleanup()
        }
    }
}

// MARK: - Standalone Player Manager

@MainActor
final class StandalonePlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying: Bool = false
    private var notificationObserver: NSObjectProtocol?

    func setupPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func playFromBeginning() {
        player?.seek(to: .zero)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func cleanup() {
        player?.pause()
        player = nil
        isPlaying = false

        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
    }
}
