//
//  HandCategory.swift
//  Baccarat
//
//  Port direct de src/game/categories.js. Ordre = force croissante.
//  multi est le multiplicateur de paiement (Carré ×8, Q. Flush ×16, Royale ×20,
//  le reste ×1).
//

import Foundation

enum HandCategory: Int, CaseIterable, Codable {
    case highcard  = 0
    case pair
    case twopair
    case trips
    case straight
    case flush
    case fullhouse
    case quads
    case sflush
    case royal

    var id: String {
        switch self {
        case .highcard:  return "highcard"
        case .pair:      return "pair"
        case .twopair:   return "twopair"
        case .trips:     return "trips"
        case .straight:  return "straight"
        case .flush:     return "flush"
        case .fullhouse: return "fullhouse"
        case .quads:     return "quads"
        case .sflush:    return "sflush"
        case .royal:     return "royal"
        }
    }

    var label: String {
        switch self {
        case .highcard:  return String(localized: "Hauteur")
        case .pair:      return String(localized: "Paire")
        case .twopair:   return String(localized: "Double paire")
        case .trips:     return String(localized: "Brelan")
        case .straight:  return String(localized: "Suite")
        case .flush:     return String(localized: "Couleur")
        case .fullhouse: return String(localized: "Full")
        case .quads:     return String(localized: "Carré")
        case .sflush:    return String(localized: "Quinte flush")
        case .royal:     return String(localized: "Royale")
        }
    }

    var multi: Int {
        switch self {
        case .quads:  return 8
        case .sflush: return 16
        case .royal:  return 20
        default:      return 1
        }
    }

    static func from(id: String) -> HandCategory? {
        HandCategory.allCases.first { $0.id == id }
    }
}
