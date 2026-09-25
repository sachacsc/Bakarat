//
//  AuthService.swift
//  Baccarat
//
//  ObservableObject around Supabase Auth. Exposes :
//   - `session` (current Supabase session, nil if signed out)
//   - `profile` (custom `profiles` row, fetched on sign-in)
//   - `isSignedIn` computed convenience
//   - signIn / signUp / signOut / sendPasswordReset / updateProfile
//
//  Listens to authStateChanges so external sign-out (token expiry, etc.) flips
//  the UI back to the gate automatically.
//

import Foundation
import Combine
import Supabase
import UIKit

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var profile: UserProfile?
    @Published var isLoading = false
    @Published var lastError: String?
    /// True une fois que `restoreSessionIfNeeded()` a fini (succès ou échec).
    /// Permet d'afficher un splash écran au boot tant qu'on n'a pas décidé si
    /// l'utilisateur est connecté ou non — évite le flash login → tabbar.
    @Published private(set) var didFinishInitialRestore = false
    /// True quand Supabase a déclenché l'event PASSWORD_RECOVERY (après
    /// résolution d'un deep link com.sacha.bakarat://auth/callback#...).
    /// ContentView présente SetNewPasswordSheet quand vrai. Reset par la
    /// sheet à la fin du flow.
    @Published var isInPasswordRecovery: Bool = false

    private let client = SupabaseClientProvider.shared
    private var observationTask: Task<Void, Never>?

    var isSignedIn: Bool { session != nil }
    /// Email du user courant, sans avoir à importer le module Auth dans les views.
    var userEmail: String? { session?.user.email }
    /// UUID du user courant.
    var userId: UUID? { session?.user.id }
    /// True si le user courant est un compte anonyme (créé via "Continuer en
    /// tant qu'invité"). Sert à proposer la conversion en compte permanent
    /// dans la sheet profil.
    var isAnonymous: Bool {
        guard let user = session?.user else { return false }
        return user.isAnonymous
    }

    init() {
        observeAuthChanges()
    }

    deinit {
        observationTask?.cancel()
    }

    private func observeAuthChanges() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.client.auth.authStateChanges {
                self.session = change.session
                switch change.event {
                case .signedIn, .tokenRefreshed, .initialSession:
                    if let s = change.session {
                        await self.loadProfile(for: s.user.id)
                    }
                case .signedOut:
                    self.profile = nil
                case .passwordRecovery:
                    self.isInPasswordRecovery = true
                default:
                    break
                }
            }
        }
    }

    func restoreSessionIfNeeded() async {
        do {
            let s = try await client.auth.session
            self.session = s
            await loadProfile(for: s.user.id)
        } catch {
            // Pas de session en cache. Hook QA (DEBUG) : `-autoLoginEmail` /
            // `-autoLoginPassword` permettent au tour automatisé de démarrer
            // déjà connecté.
            if let email = QALaunchOptions.autoLoginEmail,
               let password = QALaunchOptions.autoLoginPassword {
                do {
                    try await client.auth.signIn(email: email, password: password)
                    let s = try await client.auth.session
                    self.session = s
                    await loadProfile(for: s.user.id)
                } catch {
                    self.lastError = friendlyAuthMessage(error)
                }
            }
        }
        didFinishInitialRestore = true
    }

    // MARK: - Profile

    private func loadProfile(for userID: UUID) async {
        do {
            let row: UserProfile = try await client
                .from("profiles")
                .select()
                .eq("user_id", value: userID)
                .single()
                .execute()
                .value
            self.profile = row
        } catch {
            // Fallback : the trigger may not have populated the row yet. Retry once.
            self.profile = UserProfile(
                userId: userID,
                displayName: session?.user.email?.split(separator: "@").first.map(String.init) ?? "?",
                avatarUrl: nil,
                currency: "EUR"
            )
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        guard let userID = session?.user.id else { return }
        struct Patch: Encodable { let display_name: String }
        try await client
            .from("profiles")
            .update(Patch(display_name: newName))
            .eq("user_id", value: userID)
            .execute()
        if var p = profile {
            p.displayName = newName
            profile = p
        }
    }

    /// Upload l'image vers `avatars/{user_id}/avatar.jpg` (RLS owner-only),
    /// récupère l'URL publique et update profiles.avatar_url. Le `data`
    /// attendu est un JPEG ou PNG ; on le ré-encode en JPEG quality 0.85
    /// downsizé à 512x512 pour limiter la taille.
    func uploadAvatar(imageData: Data) async throws {
        guard let userID = session?.user.id else { return }

        // Downsize + re-encode JPEG.
        let optimized = Self.downsizeAndEncode(imageData) ?? imageData
        // Path doit être LOWERCASE : la RLS compare auth.uid()::text (que
        // Postgres renvoie toujours en minuscules) à storage.foldername(name)[1].
        // Swift UUID.uuidString renvoie en MAJUSCULES → mismatch silencieux,
        // d'où "new row violates row-level security policy".
        let path = "\(userID.uuidString.lowercased())/avatar.jpg"

        // Upload (upsert = remplace l'existant).
        _ = try await client.storage
            .from("avatars")
            .upload(
                path,
                data: optimized,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )

        // URL publique + cache-bust pour forcer le refresh côté AsyncImage.
        let baseURL = try client.storage.from("avatars").getPublicURL(path: path)
        let publicURL = baseURL.absoluteString + "?v=\(Int(Date().timeIntervalSince1970))"

        struct Patch: Encodable { let avatar_url: String }
        try await client
            .from("profiles")
            .update(Patch(avatar_url: publicURL))
            .eq("user_id", value: userID)
            .execute()

        if var p = profile {
            p.avatarUrl = publicURL
            profile = p
        }
    }

    /// Downsize + re-encode JPEG. Renvoie nil si l'image n'est pas décodable.
    private static func downsizeAndEncode(_ data: Data, maxDim: CGFloat = 512) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let scale = min(1.0, maxDim / max(img.size.width, img.size.height))
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Sign in / Sign up

    func signIn(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signUp(email: email, password: password)
    }

    /// Crée un compte anonyme côté Supabase. Utilisé par le flow "Rejoindre
    /// via code" quand l'utilisateur n'a pas (encore) de compte. L'auth state
    /// passe en SIGNED_IN avec un user.isAnonymous = true ; le profile est
    /// auto-créé via le trigger handle_new_user (display_name = "Invité-XXXX"
    /// par défaut, modifiable depuis la sheet profil).
    func signInAnonymously() async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signInAnonymously()
    }

    /// Convertit un compte anonyme en compte permanent en lui attachant un
    /// email + mot de passe. L'UUID du user est préservé → l'historique
    /// (parties revendiquées, dettes…) survit à la conversion.
    func linkEmailToAnonymous(email: String, password: String) async throws {
        guard isAnonymous else { return }
        try await client.auth.update(user: UserAttributes(email: email, password: password))
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(
            email,
            redirectTo: URL(string: "com.sacha.bakarat://auth/callback")
        )
    }

    /// Sign in (ou sign up automatique) avec Apple. Le caller fournit l'ID
    /// token JWT renvoyé par ASAuthorization + le raw nonce qu'il a généré
    /// au démarrage du flow (Supabase re-hash et vérifie).
    /// Si Apple a renvoyé un nom complet (1er login uniquement), il
    /// remplace le display_name auto-généré par le trigger handle_new_user.
    func signInWithApple(idToken: String, rawNonce: String, fullName: String?) async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
        // Si Apple a renvoyé un nom, on patche le display_name. Sinon on
        // garde celui auto-créé par le trigger (basé sur l'email).
        if let name = fullName, !name.isEmpty {
            try? await updateDisplayName(name)
        }
    }

    /// Met à jour le mot de passe du user courant. Appelé depuis
    /// SetNewPasswordSheet après que le deep link a établi la session en
    /// mode recovery.
    func updatePassword(_ newPassword: String) async throws {
        try await client.auth.update(user: UserAttributes(password: newPassword))
        isInPasswordRecovery = false
    }
}
