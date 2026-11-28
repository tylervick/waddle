import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension's principal class (#551): Waddle in Safari's share
/// sheet, for a page or a link.
///
/// It takes one web link (`NSExtensionActivationSupportsWebURLWithMaxCount`
/// = 1 and nothing else, so a file shared from Files still goes through
/// **Open in Waddle**, and Waddle is listed once there), shows it, and on
/// **Add to Waddle** leaves it in `PendingLinkInbox` for Waddle to download
/// when it next opens. It downloads nothing itself: an extension cannot open
/// its app, and the file is the app's to fetch, with its own caps and checks.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] added in
            guard let context = self?.extensionContext else { return }
            if added {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        loadSharedLink()
    }

    /// Finds the first web link among what was shared and hands it to the
    /// model. Safari offers a page as a URL (and, on some pages, as text
    /// too); only the URL is read.
    private func loadSharedLink() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            model.state = .refused(LinkDownloadError.notALink.reason)
            return
        }
        _ = provider.loadObject(ofClass: NSURL.self) { [model] object, _ in
            let url = (object as? NSURL) as URL?
            Task { @MainActor in model.show(url) }
        }
    }
}

/// What the sheet shows, and what its buttons do.
@MainActor
@Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        /// A link Waddle will download: its host and last path component.
        case ready(URL)
        /// Why this link cannot be added: the app's own reason.
        case refused(String)
    }

    var state: State = .loading
    /// Ends the extension: true once the link is added, false on Cancel.
    @ObservationIgnored var finish: (Bool) -> Void = { _ in }
    /// Where the link goes. Nil when this build has no App Group, which a
    /// shipped build always has.
    @ObservationIgnored var inbox: PendingLinkInbox? = .shared()

    /// Shows `url`, or why Waddle would refuse it, by the check the app
    /// makes before it downloads (`WebLink.validate`).
    func show(_ url: URL?) {
        guard let url else {
            state = .refused(LinkDownloadError.notALink.reason)
            return
        }
        switch WebLink.validate(url.absoluteString) {
        case .success(let valid): state = .ready(valid)
        case .failure(let error): state = .refused(error.reason)
        }
    }

    func add() {
        guard case .ready(let url) = state else { return }
        guard let inbox else {
            state = .refused(PendingLinkInbox.Refusal.unwritable.reason)
            return
        }
        switch inbox.add(url.absoluteString) {
        case .success: finish(true)
        case .failure(let refusal): state = .refused(refusal.reason)
        }
    }

    func cancel() {
        finish(false)
    }
}

/// The sheet: the link, what will happen to it, **Add to Waddle** and
/// **Cancel**. No compose view: there is nothing to write.
struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .loading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                case .ready(let url):
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: url.host() ?? url.absoluteString)
                                .font(.headline)
                                .accessibilityIdentifier("shareLinkHost")
                            if let name = Self.lastComponent(of: url) {
                                Text(verbatim: name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("shareLinkName")
                            }
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        Text("Waddle will download this when you open it.")
                    }
                case .refused(let reason):
                    Section {
                        Text(reason)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("shareLinkRefusal")
                    }
                }
            }
            .navigationTitle("Waddle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                        .accessibilityIdentifier("shareCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Waddle") { model.add() }
                        .disabled(!model.isReady)
                        .accessibilityIdentifier("shareAdd")
                }
            }
        }
    }

    /// The link's last path component, when it has one worth showing.
    static func lastComponent(of url: URL) -> String? {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }
}

private extension ShareModel {
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }
}
