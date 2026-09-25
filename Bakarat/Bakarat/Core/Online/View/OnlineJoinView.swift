//
//  OnlineJoinView.swift
//  Bakarat
//
//  Formulaire de saisie du code de salon (4 caractères). Extrait de l'ancien
//  `OnlineRootView` (code mort supprimé — le flux est hébergé par
//  `PlayRootView`).
//

import SwiftUI

// MARK: - Join code form

struct OnlineJoinView: View {
    @Binding var code: String
    var errorMessage: String? = nil
    var onSubmit: () -> Void
    var onCodeChange: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 16)

            // Badge systemGray — adapté light/dark, mêmes proportions que le badge lobby
            VStack(spacing: 6) {
                Text("Code de la partie")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                TextField("ABCD", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .tint(Color.primary)
                    .tracking(8)
                    .padding(.bottom, 2)
                    .onChange(of: code) { _, new in
                        let trimmed = new.uppercased().filter { $0.isLetter || $0.isNumber }
                        if trimmed != new { code = String(trimmed.prefix(4)) }
                        onCodeChange?()
                    }

                Button {
                    pasteFromClipboard()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Coller")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                    )
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemGray6))
            )
            .padding(.horizontal, 16)

            Spacer()

            Button {
                onSubmit()
            } label: {
                Text("Rejoindre")
                    .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
            .disabled(code.count != 4)
            .opacity(code.count == 4 ? 1 : 0.5)
            .padding(.horizontal, 16)

            if let err = errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
        .navigationTitle("Rejoindre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func pasteFromClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        let cleaned = clip.uppercased().filter { $0.isLetter || $0.isNumber }
        code = String(cleaned.prefix(4))
    }
}
