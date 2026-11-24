#if DEBUG
import SwiftUI

// THROWAWAY PROTOTYPE: the three browsers. Hard-coded state per scene.

private func megabytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func fileIcon(_ file: ProtoFile) -> String {
    file.name.hasSuffix(".zip") ? "doc.zipper" : "doc"
}

private func pageTitle(_ page: ProtoPage) -> String {
    switch page.url {
    case ProtoPage.freedoomURL: return "Download – Freedoom"
    case ProtoPage.idgamesURL: return "Index of /levels/doom2/megawads"
    case ProtoPage.apkURL: return "Release v0.4.3 · Freedoom-for-Android"
    case ProtoPage.loginURL: return "Sign in to GitHub"
    default: return page.host
    }
}

/// Real Freedoom art, which the start pages and B's featured tile show.
private struct FreedoomArt: View {
    let library: LibraryService
    var aspectRatio: CGFloat = Theme.heroAspectRatio
    @State private var game: Game?

    var body: some View {
        Group {
            if let game {
                TitleArtView(game: game, library: library, aspectRatio: aspectRatio)
            } else {
                Color.appSurface.aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .onAppear {
            game = ((try? library.shelfGames()) ?? []).first { $0.name == "Freedoom Phase 1" }
        }
    }
}

// MARK: - A: full-screen browser from the Add menu, Safari-like chrome

struct ProtoBrowserA: View {
    let scene: ProtoScene
    let library: LibraryService

    private var page: ProtoPage? {
        if case .page(let page) = scene.browser { return page }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let page {
                    ProtoWebView(page: page)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    startPage
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if case .signIn = scene.overlay {
                    Label("Waddle forgets this sign-in when you close the browser.", systemImage: "hand.raised")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if case .progress(let file, let received) = scene.overlay {
                        progressPill(file, received: received)
                            .padding(.horizontal, Theme.Spacing.base)
                            .padding(.bottom, Theme.Spacing.sm)
                    }
                    bottomBar
                }
            }
            .navigationTitle(page.map(pageTitle) ?? "Get Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {}
                }
            }
            .background(Color.appBackground)
        }
        .alert(alertTitle, isPresented: .constant(alertTitle != "")) {
            alertButtons
        } message: {
            alertMessage
        }
    }

    private var alertTitle: String {
        switch scene.overlay {
        case .confirm(let file): return "Download “\(file.name)”?"
        case .notGame: return "Waddle Can’t Use This File"
        default: return ""
        }
    }

    @ViewBuilder private var alertButtons: some View {
        switch scene.overlay {
        case .confirm:
            Button("Cancel", role: .cancel) {}
            Button("Download") {}.keyboardShortcut(.defaultAction)
        case .notGame:
            Button("Open in Safari") {}
            Button("OK", role: .cancel) {}
        default: EmptyView()
        }
    }

    @ViewBuilder private var alertMessage: some View {
        switch scene.overlay {
        case .confirm(let file):
            Text("\(file.size) from \(file.host). Waddle adds the games inside it to your shelf.")
        case .notGame(let file):
            Text("“\(file.name)” (\(file.size)) is not a Doom game file. Waddle downloads .wad, .pk3, .zip, .deh and .bex files only.")
        default: EmptyView()
        }
    }

    private func progressPill(_ file: ProtoFile, received: Int64) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: Double(received), total: Double(file.bytes))
                    .tint(Color.appAccent)
                Text("\(megabytes(received)) of \(file.size)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }
            Button {} label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.appSecondaryText)
            }
            .accessibilityLabel("Cancel Download")
        }
        .padding(Theme.Spacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(Color.appHairline))
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.base) {
            Image(systemName: "chevron.left").foregroundStyle(page == nil ? Color.appSecondaryText.opacity(0.4) : .primary)
            Image(systemName: "chevron.right").foregroundStyle(Color.appSecondaryText.opacity(0.4))
            HStack(spacing: 6) {
                if let page {
                    Image(systemName: "lock.fill").font(.caption)
                    Text(page.host).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.clockwise").font(.subheadline)
                } else {
                    Image(systemName: "magnifyingglass").font(.subheadline)
                    Text("Search or enter website")
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer(minLength: 0)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 40)
            .background(Color.appSurface, in: Capsule())
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(page == nil ? Color.appSecondaryText.opacity(0.4) : .primary)
        }
        .font(.title3)
        .padding(.horizontal, Theme.Spacing.base)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.bar)
    }

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.base) {
                Text("FEATURED")
                    .font(Theme.Typography.badge)
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 0) {
                    FreedoomArt(library: library)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Freedoom").font(Theme.Typography.heroTitle)
                        Text("Two complete games, free to play and share, made for engines like the one in Waddle.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Color.appSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {} label: {
                            Label("Visit freedoom.github.io", systemImage: "safari")
                        }
                        .buttonStyle(.waddlePrimary)
                        .padding(.top, Theme.Spacing.xs)
                    }
                    .padding(Theme.Spacing.base)
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline))
                Text("Open any website from the address bar. When you tap a link to a .wad, .pk3, .zip, .deh or .bex file, Waddle shows its size and asks before downloading.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560)
            .padding(Theme.Spacing.base)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appBackground)
    }
}

// MARK: - B: beside the shelf, minimal chrome, no start page

struct ProtoBrowserB: View {
    let scene: ProtoScene
    let library: LibraryService
    /// Pushed on a phone: the bar's own back button goes to the shelf.
    var pushed = false

    private var page: ProtoPage {
        if case .page(let page) = scene.browser { return page }
        return .freedoom()
    }

    var body: some View {
        ProtoWebView(page: page, mobile: true)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: Theme.Spacing.sm) {
                    card
                    HStack(spacing: 28) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right").foregroundStyle(Color.appSecondaryText.opacity(0.4))
                        Spacer()
                    }
                    .font(.title3)
                    .padding(.horizontal, Theme.Spacing.grid)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .padding(.top, Theme.Spacing.sm)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(pageTitle(page)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                            Text(page.host)
                        }
                        .font(.caption2)
                        .foregroundStyle(Color.appSecondaryText)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {} label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Button {} label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        Button {} label: { Label("Go to Address…", systemImage: "character.cursor.ibeam") }
                        Divider()
                        Button {} label: { Label("Bookmark This Page", systemImage: "bookmark") }
                        Menu {
                            Button("Freedoom – Download") {}
                            Button("Index of /levels/doom2/megawads") {}
                        } label: { Label("Bookmarks", systemImage: "book") }
                        Divider()
                        Button {} label: { Label("Open in Safari", systemImage: "safari") }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("browserMore")
                }
                if !pushed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {}
                    }
                }
            }
    }

    @ViewBuilder private var card: some View {
        switch scene.overlay {
        case .confirm(let file):
            cardShell {
                fileRow(file, detail: "\(file.size) · \(file.host)")
                HStack(spacing: Theme.Spacing.md) {
                    Button("Not Now") {}.buttonStyle(.waddleSecondary)
                    Button { } label: { Label("Add to Shelf", systemImage: "arrow.down") }
                        .buttonStyle(.waddlePrimary)
                }
            }
        case .progress(let file, let received):
            cardShell {
                fileRow(file, detail: "\(megabytes(received)) of \(file.size)", cancel: true)
                ProgressView(value: Double(received), total: Double(file.bytes)).tint(Color.appAccent)
            }
        case .done(_, let games):
            cardShell {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On your shelf").font(.subheadline.weight(.semibold))
                        Text(games).font(Theme.Typography.caption).foregroundStyle(Color.appSecondaryText)
                    }
                    Spacer()
                    Button("Play") {}.buttonStyle(.waddlePrimary).fixedSize()
                }
            }
        case .notGame(let file):
            cardShell {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Color.appWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not a game file").font(.subheadline.weight(.semibold))
                        Text("\(file.name) (\(file.size)) is an app for another system. Waddle only adds Doom game files, so it was not downloaded.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Color.appSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button { } label: { Label("Open Page in Safari", systemImage: "safari") }
                    .buttonStyle(.waddleSecondary)
            }
        case .signIn:
            cardShell {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(Color.appSecondaryText)
                    Text("You can sign in here, but Waddle keeps no cookies: closing the browser signs you out. Sites you use often may be easier in Safari.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.appSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        default:
            EmptyView()
        }
    }

    private func cardShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md, content: content)
            .waddleCard()
            .padding(.horizontal, Theme.Spacing.md)
    }

    private func fileRow(_ file: ProtoFile, detail: String, cancel: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: fileIcon(file))
                .font(.title)
                .foregroundStyle(Color.appAccent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(Theme.Typography.caption).foregroundStyle(Color.appSecondaryText)
            }
            Spacer()
            if cancel {
                Button {} label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Color.appSecondaryText)
                }
            }
        }
    }
}

// MARK: - C: a whole browser in its own tab

struct ProtoBrowserC: View {
    let scene: ProtoScene
    let library: LibraryService

    private var page: ProtoPage? {
        if case .page(let page) = scene.browser { return page }
        return nil
    }

    private var sheetUp: Bool {
        switch scene.overlay {
        case .confirm, .notGame, .downloads, .progress: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if let page {
                ProtoWebView(page: page, persistent: true)
            } else {
                newTabPage
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { addressBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { toolbarRow }
        .sheet(isPresented: .constant(sheetUp)) {
            sheet
                .presentationDetents(detents)
                .presentationBackground(Color.appSurface)
        }
    }

    private var detents: Set<PresentationDetent> {
        switch scene.overlay {
        case .downloads, .progress: return [.medium]
        default: return [.height(330)]
        }
    }

    private var addressBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                if let page {
                    Image(systemName: "lock.fill").font(.caption)
                    Text(page.url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.clockwise")
                } else {
                    Image(systemName: "magnifyingglass")
                    Text("Search or enter website").foregroundStyle(Color.appSecondaryText)
                    Spacer(minLength: 0)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 38)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
        .background(.bar)
    }

    private var downloadsActive: Bool {
        switch scene.overlay {
        case .progress, .downloads: return true
        default: return false
        }
    }

    private var toolbarRow: some View {
        HStack {
            Image(systemName: "chevron.left")
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Color.appSecondaryText.opacity(0.4))
            Spacer()
            Image(systemName: "square.and.arrow.up")
            Spacer()
            Image(systemName: "book")
            Spacer()
            ZStack {
                Image(systemName: "arrow.down.circle")
                if downloadsActive {
                    Circle().trim(from: 0, to: 0.44)
                        .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 25, height: 25)
                }
            }
            Spacer()
            ZStack {
                Image(systemName: "square.on.square")
                Text("2").font(.system(size: 9, weight: .bold)).offset(x: -2, y: 2)
            }
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var newTabPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    WaddleSectionHeader("Suggested")
                    HStack(spacing: Theme.Spacing.md) {
                        FreedoomArt(library: library, aspectRatio: Theme.tileAspectRatio)
                            .frame(width: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Freedoom").font(.headline)
                            Text("A free game for Doom engines")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Color.appSecondaryText)
                            Text("freedoom.github.io")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Color.appAccent)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    WaddleSectionHeader("Bookmarks")
                    EmptyStateView(systemImage: "book", title: "No bookmarks yet",
                                   hint: "Tap the book button on any page to keep it here.")
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    WaddleSectionHeader("Recently Visited")
                    EmptyStateView(systemImage: "clock", title: "Nothing yet",
                                   hint: "Pages you open appear here. Clear them in Settings.")
                }
            }
            .frame(maxWidth: 600)
            .padding(Theme.Spacing.base)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appBackground)
    }

    @ViewBuilder private var sheet: some View {
        switch scene.overlay {
        case .confirm(let file):
            confirmSheet(file, icon: fileIcon(file), tint: .appAccent,
                         title: "Download File?",
                         body: "Waddle checks it when it arrives and puts any games it finds on your shelf.",
                         primary: "Download")
        case .notGame(let file):
            confirmSheet(file, icon: "exclamationmark.triangle.fill", tint: .appWarning,
                         title: "Not a Game File",
                         body: "Waddle can’t play “\(file.name)”. You can still keep it in Downloads and share it to another app.",
                         primary: "Download Anyway")
        case .downloads, .progress:
            downloadsList
        default:
            EmptyView()
        }
    }

    private func confirmSheet(_ file: ProtoFile, icon: String, tint: Color, title: String,
                              body: String, primary: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(tint)
            Text(title).font(.title3.bold())
            VStack(spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold))
                Text("\(file.size) · from \(file.host)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }
            Text(body)
                .font(Theme.Typography.caption)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel") {}.buttonStyle(.waddleSecondary)
                Button(primary) {}.buttonStyle(.waddlePrimary)
            }
        }
        .padding(Theme.Spacing.grid)
    }

    private var downloadsList: some View {
        NavigationStack {
            List {
                if case .progress(let file, let received) = scene.overlay {
                    downloadRow(file, status: "\(megabytes(received)) of \(file.size)",
                                progress: Double(received) / Double(file.bytes))
                } else {
                    downloadRow(.scythe, status: "On your shelf · Scythe", done: true)
                    downloadRow(.apk, status: "Not a game file · kept here", warning: true)
                    downloadRow(.freedoom, status: "On your shelf · Freedoom Phase 1, Phase 2", done: true)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") {} }
                ToolbarItem(placement: .cancellationAction) { Button("Clear") {} }
            }
        }
    }

    private func downloadRow(_ file: ProtoFile, status: String, progress: Double? = nil,
                             done: Bool = false, warning: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: fileIcon(file)).font(.title2)
                .foregroundStyle(warning ? Color.appSecondaryText : Color.appAccent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.subheadline.weight(.semibold))
                if let progress { ProgressView(value: progress).tint(Color.appAccent) }
                Text(status).font(Theme.Typography.caption)
                    .foregroundStyle(warning ? Color.appWarning : Color.appSecondaryText)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
            } else if warning {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Color.appSecondaryText)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.appSecondaryText)
            }
        }
        .listRowBackground(Color.appBackground)
    }
}

// MARK: - Root

struct ProtoRoot: View {
    let scene: ProtoScene
    let library: LibraryService
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        content.preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch scene.direction {
        case .a:
            NavigationStack { ProtoShelf(scene: scene, library: library) }
                .fullScreenCover(isPresented: .constant(scene.browser != nil)) {
                    ProtoBrowserA(scene: scene, library: library)
                }
        case .b:
            if sizeClass == .regular {
                NavigationStack { ProtoShelf(scene: scene, library: library) }
                    .inspector(isPresented: .constant(scene.browser != nil)) {
                        NavigationStack { ProtoBrowserB(scene: scene, library: library) }
                            .inspectorColumnWidth(min: 360, ideal: 430, max: 520)
                    }
            } else {
                NavigationStack {
                    ProtoShelf(scene: scene, library: library)
                        .navigationDestination(isPresented: .constant(scene.browser != nil)) {
                            ProtoBrowserB(scene: scene, library: library, pushed: true)
                        }
                }
            }
        case .c:
            TabView(selection: .constant(scene.browser != nil ? 1 : 0)) {
                Tab("Shelf", systemImage: "square.grid.2x2", value: 0) {
                    NavigationStack { ProtoShelf(scene: scene, library: library) }
                }
                Tab("Browse", systemImage: "safari", value: 1) {
                    ProtoBrowserC(scene: scene, library: library)
                }
            }
        }
    }
}
#endif
