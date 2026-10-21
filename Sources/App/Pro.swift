import StoreKit
import SwiftUI

/// One-time "Pro" unlock (non-consumable). Everything else is free.
@MainActor
final class Pro: ObservableObject {
    static let productID = "com.cadentate.assignmenttracker.pro"
    @Published private(set) var isPro = false
    @Published private(set) var price: String?
    @Published var message: String?
    private var product: Product?
    private var updates: Task<Void, Never>?

    #if DEBUG
    /// Debug-only stand-in for a purchase, so the gated features can be exercised without an App Store account.
    @AppStorage("debugPro") private var debugPro = false
    func debugToggle() { debugPro.toggle(); recompute() }
    #endif
    private var entitled = false
    /// Set by a verified purchase in this session, so a stale entitlement list can't undo it.
    private var purchased = false

    init() {
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update {
                    if t.revocationDate != nil { await self?.revoked() }
                    await t.finish()
                }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
        recompute()
    }

    deinit { updates?.cancel() }

    private func recompute() {
        #if DEBUG
        isPro = entitled || debugPro
        #else
        isPro = entitled
        #endif
    }

    func load() async {
        product = try? await Product.products(for: [Self.productID]).first
        price = product?.displayPrice
    }

    private func revoked() { purchased = false }

    func refresh() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { found = true }
        }
        entitled = found || purchased
        recompute()
    }

    func buy() async {
        guard let product else { message = "The store isn't available right now. Try again in a moment."; return }
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let t):
                    purchased = true; entitled = true; recompute()   // unlock immediately, then tidy up
                    message = nil
                    await t.finish()
                    await refresh()
                case .unverified(_, let error):
                    message = "The purchase couldn't be verified: \(error.localizedDescription)"
                }
            case .pending: message = "Waiting for approval."
            case .userCancelled: break
            @unknown default: message = "The purchase didn't complete."
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        do { try await AppStore.sync(); await refresh(); message = isPro ? nil : "No earlier purchase found for this Apple ID." }
        catch { message = error.localizedDescription }
    }
}

struct PaywallView: View {
    @EnvironmentObject private var pro: Pro
    let plans: [Plan]
    var reason: String?
    @State private var preview: String?
    @State private var checking = false
    @State private var needsAccess = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let perks: [(String, String, String)] = [
        ("calendar.badge.exclamationmark", "Plan around your whole life", "Skip work, clubs and appointments, not just classes."),
        ("calendar.badge.plus", "Study blocks in your calendar", "Sessions appear in Apple Calendar and update when the plan changes."),
        ("link", "More than one feed", "Combine several schools or accounts."),
        ("slider.horizontal.3", "Per-course settings", "Give a hard class more time or a bigger safety margin."),
        ("chart.line.uptrend.xyaxis", "Learns how long you take", "Estimates adjust to your real pace."),
        ("rectangle.on.rectangle", "Widget", "Today's sessions on your home screen."),
    ]

    var body: some View {
        SheetScaffold(title: "Unlock Pro", subtitle: reason) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(perks.enumerated()), id: \.offset) { i, p in
                    if i > 0 { RowDivider() }
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: p.0).font(.system(size: 16)).foregroundStyle(Theme.slate).frame(width: 22).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.1).font(.system(size: 16, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.ink)
                            Text(p.2).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))

            SheetSection(title: "See what you'd gain", footer: preview) {
                ActionRow(title: checking ? "Checking…" : "Check my calendar for conflicts") {
                    checking = true
                    Task {
                        defer { checking = false }
                        guard let busy = await CalendarSync.busy() else {
                            needsAccess = true
                            preview = "Calendar access is off, so I can't check. Turn it on for this app in Privacy settings, then try again."
                            return
                        }
                        needsAccess = false
                        let c = Planner.conflicts(plans, busy: busy)
                        preview = c.sessions == 0
                            ? "No planned sessions overlap your calendar right now."
                            : "\(c.sessions) planned session\(c.sessions == 1 ? "" : "s") overlap \(c.events) of your calendar event\(c.events == 1 ? "" : "s"). Pro would move them."
                    }
                }
                if needsAccess, let url = CalendarSync.settingsURL {
                    RowDivider()
                    ActionRow(title: "Open Calendar privacy settings") { openURL(url) }
                }
            }

            VStack(spacing: 10) {
                Button { Task { await pro.buy() } } label: {
                    Text(pro.price.map { "Unlock for \($0), once" } ?? "Unlock Pro")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.paper)
                        .frame(maxWidth: .infinity).padding(.vertical, 14).background(Theme.ink, in: Capsule())
                }.buttonStyle(.plain)
                Button("Restore purchase") { Task { await pro.restore() } }
                    .font(.system(size: 14)).foregroundStyle(Theme.slate)
                if let m = pro.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.warn) }
                Text("One payment, no subscription. Everything else in the app stays free.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                #if DEBUG
                Button(pro.isPro ? "Debug: switch Pro off" : "Debug: simulate purchase") { pro.debugToggle() }
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                #endif
            }
        }
        .presentationDetents([.large])
        .onChange(of: pro.isPro) { _, on in if on { dismiss() } }
    }
}
