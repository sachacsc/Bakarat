//
//  RoomLifecycleModifier.swift
//  Bakarat
//
//  Cycle de vie iOS du salon (docs/PLAN_ONLINE_V2.md — T20). Posé une seule
//  fois sur `OnlineLobbyView` : comme la vue de jeu est rendue à l'intérieur,
//  elle en hérite.
//
//   • `.active`     → `handleForeground()` : resync (rejoin channel + room_get)
//                     puis reprise idempotente du tempo si on anime la partie.
//   • `.background` → `handleBackground()` : on coupe le tempo, il repartira.
//
//  Le réseau (`NWPathMonitor`) est surveillé dans `RoomTransport` (T21).
//

import SwiftUI

struct RoomLifecycleModifier: ViewModifier {
    @ObservedObject var service: OnlineGameService
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Task { await service.handleForeground() }
                case .background:
                    service.handleBackground()
                default:
                    break
                }
            }
    }
}

extension View {
    /// Branche le salon sur le cycle de vie de la scène.
    func roomLifecycle(_ service: OnlineGameService) -> some View {
        modifier(RoomLifecycleModifier(service: service))
    }
}
