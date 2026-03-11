//
//  PokemonDetailSection.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit

enum PokemonDetailSectionType: Int, CaseIterable {
    case hero = 0
    case info
    case stats

    var title:String {
        switch self {
        case .hero: return ""
        case .info: return "INFO"
        case .stats: return "BASE STATS"
        }
    }
}

enum PokemonDetailItemType {
    case heroImage(url:URL?, color:UIColor)
    case nameTypes(name:String, types:[String], color:UIColor)
    case infoCard(label:String, value:String)
    case stat(name:String, value:Int, color:UIColor)

    var cellInfo:CellInfo {
        switch self {
        case .heroImage:
            return .init(cell: PokemonHeroCell.self, reuseId: PokemonHeroCell.reuseId)
        case .nameTypes:
            return .init(cell: PokemonNameTypesCell.self, reuseId: PokemonNameTypesCell.reuseId)
        case .infoCard:
            return .init(cell: PokemonInfoCardCell.self, reuseId: PokemonInfoCardCell.reuseId)
        case .stat:
            return .init(cell: PokemonStatCell.self, reuseId: PokemonStatCell.reuseId)
        }
    }
}

struct PokemonDetailSectionItem {
    var type:PokemonDetailItemType
}

struct PokemonDetailSection {

    let type:PokemonDetailSectionType
    var items:[PokemonDetailSectionItem] = []

    init(type:PokemonDetailSectionType, detail:PokemonDetail, spriteURL:URL?) {
        self.type = type
        self.items = buildItems(detail: detail, spriteURL: spriteURL)
    }

    private func buildItems(detail:PokemonDetail, spriteURL:URL?) -> [PokemonDetailSectionItem] {
        switch type {
        case .hero:
            return [
                .init(type: .heroImage(url: spriteURL, color: detail.typeColor)),
                .init(type: .nameTypes(name: detail.name ?? "", types: detail.typeNames, color: detail.typeColor)),
            ]
        case .info:
            return [
                .init(type: .infoCard(label: "Height", value: String(format: "%.1f m", Double(detail.height ?? 0) / 10))),
                .init(type: .infoCard(label: "Weight", value: String(format: "%.1f kg", Double(detail.weight ?? 0) / 10))),
                .init(type: .infoCard(label: "Base EXP", value: detail.baseExperience.map { "\($0) XP" } ?? "—")),
            ]
        case .stats:
            return (detail.stats ?? []).map {
                .init(type: .stat(name: $0.stat?.name ?? "", value: $0.baseStat ?? 0, color: detail.typeColor))
            }
        }
    }
}
