//
//  ProfileRootView.swift
//  Bakarat
//
//  Tab 3 "Profil" — inspiré du SettingsView de Zmeo : header centré avec
//  avatar (pencil badge édition photo), nom + email/statut invité, puis
//  cards groupés (Compte · Préférences · Support · Session) avec rows
//  icône + titre + accessoire chevron/texte.
//
//  Compte anonyme : bandeau "Compte invité" + une row "Lier mon compte"
//  qui ouvre une sheet email/mot de passe, sans perdre l'UUID donc
//  l'historique + dettes survivent.
//

import SwiftUI
import PhotosUI

struct ProfileRootView: View {
    @EnvironmentObject private var auth: AuthService

    @State private var photoItem: PhotosPickerItem?
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?

    // Avatar cropper flow
    @State private var pickedImage: UIImage? = nil
    @State private var showCropper = false
    @State private var isUploadingAvatar = false
    @State private var avatarError: String? = nil

    // Edit pseudo
    @State private var showEditName = false
    @State private var editedName = ""
    @State private var saveError: String?
    @State private var isSaving = false

    // Upgrade anonymous → email account
    @State private var showUpgrade = false
    @State private var upgradeEmail = ""
    @State private var upgradePassword = ""
    @State private var upgradeError: String?
    @State private var isUpgrading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    accountCard
                    supportCard
                    sessionCard
                    versionFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await auth.signOut() }
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Delete my account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    Task {
                        do { try await auth.deleteAccount() }
                        catch { deleteError = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your account, your games, your balances and your photo are deleted immediately. This cannot be undone.")
            }
            .alert("Deletion failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .alert("Edit username", isPresented: $showEditName) {
                TextField("Username", text: $editedName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { }
                Button("Save", action: savePseudo)
            } message: {
                if let saveError {
                    Text(saveError)
                } else {
                    Text("Choose how other players see you in shared counters and games.")
                }
            }
            .sheet(isPresented: $showUpgrade) {
                upgradeSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showCropper) {
                ProfileImageCropperView(
                    image: $pickedImage,
                    isPresented: $showCropper
                ) { cropped in
                    Task { await uploadCropped(cropped) }
                }
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedImage(newItem) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarBubble(profile: auth.profile, size: 96)
                        // Force le re-render quand l'URL change (cache-bust query
                        // ne suffit pas si SwiftUI réutilise la vue identique).
                        .id(auth.profile?.avatarUrl ?? "")
                        .opacity(isUploadingAvatar ? 0.4 : 1)
                    if isUploadingAvatar {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 96, height: 96)
                    } else {
                        pencilBadge
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isUploadingAvatar)

            Text(auth.profile?.displayName ?? "—")
                .font(.title2.weight(.bold))
                .lineLimit(1)

            if auth.isAnonymous {
                Text("Temporary guest account")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Text(auth.userEmail ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let avatarError {
                Text(avatarError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var pencilBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(7)
            .background(Theme.brandRed)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2)
            )
            .offset(x: 2, y: 2)
    }

    // MARK: - Cards

    private var accountCard: some View {
        settingsCard(header: "Account") {
            settingsRow(
                icon: "person.crop.circle",
                iconColor: .blue,
                title: "Username",
                accessory: .text(auth.profile?.displayName ?? "—")
            ) {
                editedName = auth.profile?.displayName ?? ""
                saveError = nil
                showEditName = true
            }

            if auth.isAnonymous {
                settingsRow(
                    icon: "link",
                    iconColor: .green,
                    title: "Link my account to an email",
                    subtitle: "Keep your history with a password",
                    accessory: .chevron
                ) {
                    showUpgrade = true
                }
            } else {
                settingsRow(
                    icon: "envelope",
                    iconColor: .gray,
                    title: "Email",
                    accessory: .text(auth.userEmail ?? "—")
                ) { /* read-only */ }
            }
        }
    }

    private var supportCard: some View {
        settingsCard(header: "Help & legal") {
            NavigationLink {
                RulesView()
            } label: {
                settingsRowContent(
                    icon: "questionmark.circle",
                    iconColor: .orange,
                    title: "How to play",
                    accessory: .chevron
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                PrivacyPolicyView()
            } label: {
                settingsRowContent(
                    icon: "lock.shield",
                    iconColor: .blue,
                    title: "Privacy policy",
                    accessory: .chevron
                )
            }
            .buttonStyle(.plain)

            Button {
                openSupportEmail()
            } label: {
                settingsRowContent(
                    icon: "envelope",
                    iconColor: .indigo,
                    title: "Contact support",
                    subtitle: "sacha.csc@gmail.com",
                    accessory: .chevron
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func openSupportEmail() {
        let subject = "Bakarat support"
        let body = "Describe your issue or suggestion here.\n\n---\nApp: Bakarat v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")\nUser ID: \(auth.userId?.uuidString ?? "anonymous")"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "sacha.csc@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    private var sessionCard: some View {
        settingsCard(header: "Session") {
            settingsRow(
                icon: "rectangle.portrait.and.arrow.right",
                iconColor: Theme.systemRed,
                title: "Sign out",
                accessory: .none,
                titleColor: Theme.systemRed
            ) {
                showSignOutConfirm = true
            }
            settingsRow(
                icon: "trash",
                iconColor: Theme.systemRed,
                title: "Delete my account",
                subtitle: "Erases your data permanently",
                accessory: .none,
                titleColor: Theme.systemRed
            ) {
                showDeleteConfirm = true
            }
            .accessibilityIdentifier("profile.deleteAccount")
        }
    }

    private var versionFooter: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return Text("Bakarat v\(v)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }

    // MARK: - Generic settings card / row (port léger de Zmeo)

    @ViewBuilder
    private func settingsCard<Content: View>(
        header: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).textCase(.uppercase)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 12)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    private enum RowAccessory {
        case chevron, none, text(String)
    }

    @ViewBuilder
    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        accessory: RowAccessory = .chevron,
        titleColor: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            settingsRowContent(
                icon: icon,
                iconColor: iconColor,
                title: title,
                subtitle: subtitle,
                accessory: accessory,
                titleColor: titleColor
            )
        }
        .buttonStyle(.plain)
    }

    /// Contenu d'une row settings sans Button — utilisé comme label d'un
    /// NavigationLink ou d'un Button externe.
    @ViewBuilder
    private func settingsRowContent(
        icon: String,
        iconColor: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        accessory: RowAccessory = .chevron,
        titleColor: Color = .primary
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch accessory {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
            case .none:
                EmptyView()
            case .text(let value):
                Text(value)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func savePseudo() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            isSaving = true
            saveError = nil
            do {
                try await auth.updateDisplayName(trimmed)
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Étape 1 : récupère les bytes depuis la PhotosPickerItem, décode en
    /// UIImage et présente le cropper. Les formats HEIC sont supportés via
    /// UIImage(data:).
    private func loadPickedImage(_ item: PhotosPickerItem) async {
        avatarError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                avatarError = "Couldn't load the image."
                return
            }
            guard let img = UIImage(data: data) else {
                avatarError = "Unsupported image format."
                return
            }
            pickedImage = img
            showCropper = true
        } catch {
            avatarError = error.localizedDescription
        }
        // Reset la sélection pour qu'une re-sélection de la même photo
        // re-trigger le onChange.
        photoItem = nil
    }

    /// Étape 2 : reçoit l'image croppée par ProfileImageCropperView et upload.
    private func uploadCropped(_ image: UIImage) async {
        isUploadingAvatar = true
        avatarError = nil
        defer { isUploadingAvatar = false }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            avatarError = "Couldn't encode the image as JPEG."
            return
        }
        do {
            try await auth.uploadAvatar(imageData: data)
            pickedImage = nil
        } catch {
            avatarError = error.localizedDescription
        }
    }

    // MARK: - Upgrade anonymous → email

    private var upgradeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $upgradeEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $upgradePassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text("Your game history and debts are preserved. The account UUID stays the same.")
                        .font(.caption)
                }
                if let err = upgradeError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                Section {
                    Button {
                        Task { await linkAccount() }
                    } label: {
                        HStack {
                            if isUpgrading { ProgressView().tint(.white) }
                            Text(isUpgrading ? "Loading..." : "Link my account")
                                .modifier(PrimaryButtonStyle())
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(!upgradeFormValid || isUpgrading)
                }
            }
            .navigationTitle("Link my account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showUpgrade = false }
                }
            }
        }
    }

    private var upgradeFormValid: Bool {
        upgradeEmail.contains("@") && upgradePassword.count >= 6
    }

    private func linkAccount() async {
        guard upgradeFormValid else { return }
        isUpgrading = true
        upgradeError = nil
        defer { isUpgrading = false }
        do {
            try await auth.linkEmailToAnonymous(
                email: upgradeEmail.trimmingCharacters(in: .whitespaces),
                password: upgradePassword
            )
            showUpgrade = false
        } catch {
            upgradeError = error.localizedDescription
        }
    }
}
