//
//  OnlineHistoryView.swift
//  Bakarat
//
//  Push destination depuis le tab Online → "Historique". Liste les parties
//  online auxquelles le user a participé, avec son solde cumulé et un badge
//  "En cours" pour les parties où l'action continue (heuristique : dernière
//  manche < 24h + status active côté DB).
//

import SwiftUI

struct OnlineHistoryView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var debts: DebtsService
    @StateObject private var ownedService = OnlineHistoryService()
    /// Service partagé avec OnlineRootView (qui fait déjà le fetch). Si nil,
    /// on utilise notre propre instance.
    let injectedService: OnlineHistoryService?

    init(injectedService: OnlineHistoryService? = nil) {
        self.injectedService = injectedService
    }

    private var historyService: OnlineHistoryService {
        injectedService ?? ownedService
    }

    var body: some View {
        Group {
            if historyService.isLoading && historyService.games.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = historyService.loadError {
                ContentUnavailableView {
                    Label("Erreur de chargement", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Réessayer") {
                        Task { await reload() }
                    }
                }
            } else if historyService.games.isEmpty {
                ContentUnavailableView {
                    Label("Aucune partie", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Tes parties online apparaîtront ici une fois la première manche jouée.")
                }
            } else {
                List {
                    Section {
                        ForEach(historyService.games) { game in
                            gameRow(game)
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        }
                    } footer: {
                        Text("Solde = somme de tes gains/pertes sur l'ensemble des manches de la partie.")
                            .font(.caption)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await reload() }
            }
        }
        .navigationTitle("Historique")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    // MARK: - Row

    @ViewBuilder
    private func gameRow(_ game: GameHistoryItem) -> some View {
        let isPaid = debts.settledGameIds.contains(game.id)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dateLabel(game))
                        .font(.subheadline.weight(.semibold))
                    if game.isOngoing {
                        Text("En cours")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                    if isPaid {
                        Text("Payé")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(for: game))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatMoney(game.myBalance, currency: game.currency))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(balanceColor(game.myBalance))
                Text(formatPrice(game.linePrice, currency: game.currency) + "/ligne")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(isPaid ? 0.55 : 1.0)
    }

    // MARK: - Helpers

    private func reload() async {
        guard let uid = auth.userId else { return }
        await historyService.load(myUserId: uid)
    }

    private func dateLabel(_ g: GameHistoryItem) -> String {
        let date = g.lastMancheAt ?? g.createdAt
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func subtitle(for g: GameHistoryItem) -> String {
        var parts: [String] = []
        if g.numParticipants > 0 {
            parts.append((g.numParticipants > 1 ? String(localized: "\(g.numParticipants) joueurs") : String(localized: "1 joueur")))
        }
        if g.numManches > 0 {
            parts.append((g.numManches > 1 ? String(localized: "\(g.numManches) manches") : String(localized: "1 manche")))
        } else {
            parts.append(String(localized: "Aucune manche"))
        }
        return parts.joined(separator: " · ")
    }

    private func formatMoney(_ v: Double, currency: String) -> String {
        if abs(v) < 0.005 { return "0 \(currencyLabel(currency))" }
        let sign = v > 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.2f", abs(v))) \(currencyLabel(currency))"
    }

    private func formatPrice(_ v: Double, currency: String) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v)) \(currencyLabel(currency))"
        }
        return String(format: "%.2f", v) + " \(currencyLabel(currency))"
    }

    private func currencyLabel(_ c: String) -> String {
        switch c.uppercased() {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        case "CHF": return "CHF"
        default:    return c
        }
    }

    private func balanceColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : .red
    }
}
