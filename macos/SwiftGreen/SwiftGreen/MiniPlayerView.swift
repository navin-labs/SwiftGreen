import SwiftUI
import AppKit

/// Menu-bar popover: the Media pane in miniature — art-tinted backdrop, track,
/// progress and transport.
struct MiniPlayerView: View {
    @ObservedObject var store = MediaControlStore.shared
    @ObservedObject var server: mDNSQuicServer

    /// The last track is cached across launches; its controls only mean something while
    /// the phone is connected, otherwise every tap would be silently dropped.
    private var live: Bool { store.hasActiveSession && server.serverStatus == mDNSQuicServer.onlineStatus }

    var body: some View {
        ZStack {
            if !live {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.white.opacity(0.5))
                    Text(server.serverStatus == mDNSQuicServer.onlineStatus ? "Nothing playing on your phone" : "Your phone isn't connected")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }
            } else {
                player
            }
        }
        .frame(width: 320, height: 150)
        // Background, not a ZStack sibling, so the fill-scaled art can't resize the popover.
        .background {
            ZStack {
                Color.sgBackground
                if live, let art = store.albumArt {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 320, height: 150)
                        .clipped()
                        .blur(radius: 40)
                        .saturation(1.3)
                        .opacity(0.6)
                }
                Color.black.opacity(0.35)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: store.trackTitle)
    }

    private var player: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.trackTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(store.artist)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                    if !store.appName.isEmpty {
                        Text(store.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                Spacer(minLength: 0)
            }

            // Thin progress line: the popover is for glancing, seeking lives in the pane.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)

            HStack(spacing: 28) {
                control("backward.fill", 16, "Previous track") { send("previous") }
                control(store.isPlaying ? "pause.fill" : "play.fill", 22,
                        store.isPlaying ? "Pause" : "Play") { send("play_pause") }
                control("forward.fill", 16, "Next track") { send("next") }
            }
        }
        .padding(16)
    }

    private var artwork: some View {
        ZStack {
            if let img = store.albumArt {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private var progress: Double {
        store.durationMs > 0 ? min(max(Double(store.positionMs) / Double(store.durationMs), 0), 1) : 0
    }

    private func control(_ symbol: String, _ size: CGFloat, _ label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send(_ action: String) {
        mDNSQuicServer.activeServer?.sendMediaAction(action: action)
    }
}
