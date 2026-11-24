#if DEBUG
import SwiftUI

// THROWAWAY PROTOTYPE: the shelf as it would look in each direction, drawn
// from the real tiles, card, wordmark and banner, with hard-coded state.
struct ProtoShelf: View {
    let scene: ProtoScene
    let library: LibraryService
    var openBrowser: () -> Void = {}

    @State private var all: [Game] = []
    @State private var width: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var shown: [Game] {
        all.filter { game in
            switch scene.shelf {
            case .empty: return false
            case .freedoom: return game.name.hasPrefix("Freedoom")
            case .freedoomAndScythe:
                return game.name.hasPrefix("Freedoom") || game.name.localizedCaseInsensitiveContains("scythe")
            }
        }
        .sorted { a, b in
            // Fresh arrivals lead, the way a just-imported game does.
            let fa = isFresh(a), fb = isFresh(b)
            if fa != fb { return fa }
            return a.name < b.name
        }
    }

    private var freedoom: Game? { all.first { $0.name == "Freedoom Phase 1" } }

    private func isFresh(_ game: Game) -> Bool {
        scene.fresh.contains { game.name.localizedCaseInsensitiveContains($0) }
    }

    private var minTile: CGFloat { width > 600 ? 190 : 150 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.grid) {
                if scene.shelf == .empty {
                    emptyTop
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile), spacing: 20)], spacing: 20) {
                    if scene.shelf == .empty, scene.direction == .b, let freedoom {
                        featuredTile(freedoom)
                    }
                    ForEach(shown) { game in
                        PlayableTileView(game: game, library: library)
                            .overlay {
                                if isFresh(game) {
                                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                        .strokeBorder(Color.appAccent, lineWidth: 2)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if isFresh(game) { newBadge.padding(Theme.Spacing.sm) }
                            }
                    }
                    if shown.count < 4, !(scene.shelf == .empty && scene.direction == .c) {
                        ghostTile
                    }
                }
            }
            .padding(16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color.appBackground)
        .navigationTitle("Waddle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) {
            if let banner = scene.banner {
                ImportNoticeBanner(text: banner)
                    .padding(.horizontal, Theme.Spacing.base)
                    .padding(.bottom, scene.direction == .c ? 24 : 100)
            }
        }
        .onAppear { all = (try? library.shelfGames()) ?? [] }
    }

    private var newBadge: some View {
        Text("NEW")
            .font(Theme.Typography.badge)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.appAccent, in: Capsule())
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Image("WaddleWordmark")
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(height: Theme.wordmarkHeight)
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {} label: { Label("Settings", systemImage: "gearshape") }
        }
        if scene.direction == .b {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: openBrowser) { Label("Browse the Web", systemImage: "globe") }
                    .accessibilityIdentifier("browserButton")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {} label: { Label("From Files…", systemImage: "folder") }
                Button {} label: { Label("From a Link…", systemImage: "link") }
                if scene.direction == .a {
                    Divider()
                    Button {} label: { Label("From the Web…", systemImage: "globe") }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("importButton")
        }
    }

    @ViewBuilder
    private var emptyTop: some View {
        switch scene.direction {
        case .a:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Nothing to play yet")
                    .font(.headline)
                Text("Find a game on the web, like Freedoom, which is free. Or add WADs you already have.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openBrowser) {
                    Label("Find Games on the Web", systemImage: "globe")
                }
                .buttonStyle(.waddlePrimary)
                Button {} label: { Label("Add From Files", systemImage: "folder") }
                    .buttonStyle(.waddleSecondary)
            }
            .waddleCard()
        case .b:
            Text("Start with Freedoom, a free game made for engines like this one, or add WADs you already have.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .c:
            VStack(spacing: Theme.Spacing.base) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.appSecondaryText)
                    .padding(.top, 60)
                Text("Your shelf is empty")
                    .font(.title3.bold())
                Text("Browse the web for Doom games and Waddle adds what you download here. Freedoom is a good first one, and it is free.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openBrowser) { Label("Browse for Games", systemImage: "safari") }
                    .buttonStyle(.waddlePrimary)
                    .frame(maxWidth: 360)
                Button {} label: { Label("Add From Files", systemImage: "folder") }
                    .buttonStyle(.waddleSecondary)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.base)
        }
    }

    /// B's offer to a new player: one tile that is not a game yet.
    private func featuredTile(_ game: Game) -> some View {
        Button(action: openBrowser) {
            TitleArtView(game: game, library: library)
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                           .init(color: .black.opacity(0.85), location: 0.6),
                                           .init(color: .black.opacity(0.95), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 74)
                        .overlay(alignment: .bottomLeading) {
                            HStack(alignment: .bottom) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Freedoom").font(Theme.Typography.tileTitle)
                                    Text("Free · \(ProtoFile.freedoom.size)")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                Spacer(minLength: 4)
                                Text("Get")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 5)
                                    .background(Color.appAccent, in: Capsule())
                            }
                            .padding(10)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var ghostTile: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(Color.appSecondaryText.opacity(0.35),
                          style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            .aspectRatio(Theme.tileAspectRatio, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.title2)
                    Text("Add Games").font(.subheadline)
                }
                .foregroundStyle(Color.appSecondaryText)
            }
    }
}
#endif
