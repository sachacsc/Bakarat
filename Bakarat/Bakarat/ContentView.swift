//
//  ContentView.swift
//  Bakarat
//
//  Top-level switch : auth gate when no session, MainTabView when signed in.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = QALaunchOptions.isActive
    @State private var showOnboarding: Bool = false

    var body: some View {
        Group {
            if !auth.didFinishInitialRestore {
                SplashView()
                    .transition(.opacity)
            } else if auth.isSignedIn {
                MainTabView()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                AuthGateView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isSignedIn)
        .animation(.easeInOut(duration: 0.25), value: auth.didFinishInitialRestore)
        .sheet(isPresented: Binding(
            get: { auth.isInPasswordRecovery },
            set: { auth.isInPasswordRecovery = $0 }
        )) {
            SetNewPasswordSheet()
                .environmentObject(auth)
                .presentationDetents([.medium])
                .interactiveDismissDisabled(true)
        }
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
            hasSeenOnboarding = true
        }) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            // Au premier sign-in, présente l'onboarding si jamais vu.
            if signedIn && !hasSeenOnboarding { showOnboarding = true }
        }
        .onAppear {
            if auth.isSignedIn && !hasSeenOnboarding { showOnboarding = true }
        }
    }
}
