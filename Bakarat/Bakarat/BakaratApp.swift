//
//  BakaratApp.swift
//  Bakarat
//
//  Entry point. Wraps everything in the AuthService environment so any view
//  can observe `auth.session` and react to login/logout.
//

import SwiftUI
import SwiftData

@main
struct BakaratApp: App {
    @UIApplicationDelegateAdaptor(BakaratAppDelegate.self) var appDelegate
    @StateObject private var auth = AuthService()
    /// Service partagé : la même instance alimente l'onglet Dettes et le
    /// greying des historiques (Online + Compteur).
    @StateObject private var debts = DebtsService()
    /// Deep links : URLs ouvertes via le scheme custom (join compteur,
    /// reset password). Les vues consomment ses @Published.
    @StateObject private var deepLink = DeepLinkRouter()

    /// Container SwiftData (compteurs locaux). Recréé à la volée si l'init
    /// throw — un wipe & recreate vaut mieux qu'un crash de l'app au launch.
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Counter.self,
            CounterPlayer.self,
            CounterManche.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[SwiftData] container init failed: \(error). Falling back to in-memory.")
            let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memConfig])
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(debts)
                .environmentObject(deepLink)
                .onOpenURL { url in deepLink.handle(url: url) }
                .task {
                    // Restore session at launch (synchronously if cached locally).
                    await auth.restoreSessionIfNeeded()
                }
                .task(id: auth.userId) {
                    // Dès qu'un user est connecté, on bootstrap le service Dettes
                    // (un load() + abonnement realtime). On s'arrête sur logout.
                    if let uid = auth.userId {
                        await debts.startLiveUpdates(myUserId: uid)
                        // Demande la permission notifs au 1er signed-in
                        // (idempotent : iOS gère le "déjà demandé" lui-même).
                        if !QALaunchOptions.isActive {
                            await NotificationService.shared.requestAuthorizationAndRegister()
                        }
                    } else {
                        await debts.stopLiveUpdates()
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
