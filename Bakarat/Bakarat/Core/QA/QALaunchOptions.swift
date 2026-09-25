//
//  QALaunchOptions.swift
//  Bakarat
//
//  Hooks de lancement pour les loops et les tours automatisés
//  (docs/PLAN_ONLINE_V2.md — T04). DEBUG uniquement : en release, tous les
//  accesseurs renvoient nil / 0, donc le code appelant n'a pas besoin de
//  `#if DEBUG` autour de chaque usage.
//
//  Arguments reconnus :
//    -autoLoginEmail <email> -autoLoginPassword <mdp>
//    -qaRoomCode ABCD        code forcé à la création du salon
//    -autoJoinCode ABCD      join automatique au lancement
//    -qaBots N               N bots in-app (comptes bakaratqa.g1..g3)
//    -qaPassword <mdp>       mot de passe des comptes QA (sinon $BAKARAT_QA_PASSWORD)
//    -chaos <profil>         profil de perturbation du transport
//

import Foundation

/// Journal QA sur fichier : `print` n'atteint pas la console simctl de façon
/// fiable (stdout bufferisé / détaché). Quand un hook QA est actif, chaque
/// ligne de log du module Online est aussi ajoutée à `Documents/qa.log`,
/// lisible via `xcrun simctl get_app_container <sim> com.sacha.Bakarat data`.
enum QALog {
    private static let url: URL? = {
        guard QALaunchOptions.isActive else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent("qa.log")
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil)
        }
        return u
    }()
    private static let handle: FileHandle? = url.flatMap { try? FileHandle(forWritingTo: $0) }
    private static let lock = NSLock()
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ line: String) {
        guard let handle else { return }
        lock.lock(); defer { lock.unlock() }
        handle.seekToEndOfFile()
        handle.write(("\(df.string(from: Date())) \(line)\n").data(using: .utf8) ?? Data())
    }
}

enum QALaunchOptions {

    /// Valeur d'un argument nommé (`-flag valeur`).
    private static func value(for flag: String) -> String? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let v = args[idx + 1]
        guard !v.hasPrefix("-") else { return nil }
        return v
        #else
        return nil
        #endif
    }

    static var autoLoginEmail: String? { value(for: "-autoLoginEmail") }
    static var autoLoginPassword: String? { value(for: "-autoLoginPassword") }

    /// Code imposé à `room_create` (permet au tour XCUITest de connaître le code).
    static var forcedRoomCode: String? {
        value(for: "-qaRoomCode").map { $0.uppercased() }
    }

    /// Code à rejoindre automatiquement au premier affichage de l'onglet Play.
    static var autoJoinCode: String? {
        value(for: "-autoJoinCode").map { $0.uppercased() }
    }

    /// Nombre de bots in-app à lancer (0 = aucun).
    static var botCount: Int {
        Int(value(for: "-qaBots") ?? "") ?? 0
    }

    /// Mot de passe des comptes QA : argument, sinon variable d'environnement.
    static var qaPassword: String? {
        if let v = value(for: "-qaPassword") { return v }
        #if DEBUG
        return ProcessInfo.processInfo.environment["BAKARAT_QA_PASSWORD"]
        #else
        return nil
        #endif
    }

    /// Nom du profil chaos appliqué au transport de l'app.
    /// `-autoCreateRoom` : crée le salon au lancement (avec `-qaRoomCode` si
    /// fourni) et pousse le lobby — le tour n'a pas à tapoter « Créer ».
    static var autoCreateRoom: Bool { CommandLine.arguments.contains("-autoCreateRoom") }
    /// `-autoStartAt N` : l'hôte démarre la partie dès que N participants sont
    /// dans le lobby (bots compris).
    static var autoStartAt: Int? { value(for: "-autoStartAt").flatMap(Int.init) }

    static var chaosName: String? { value(for: "-chaos") }

    /// Profil chaos résolu (nil si inconnu ou absent).
    static var chaosProfile: ChaosProfile? {
        guard let name = chaosName else { return nil }
        return ChaosProfile.named(name)
    }

    /// Vrai si au moins un hook QA est actif (utile pour les logs).
    static var isActive: Bool {
        autoLoginEmail != nil || forcedRoomCode != nil || autoCreateRoom
            || autoJoinCode != nil || botCount > 0 || chaosName != nil
    }
}
