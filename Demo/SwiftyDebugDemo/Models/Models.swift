//
//  Models.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyNetworkIOS

// MARK: - User Item Type

enum UserItemType {
    case name(String)
    case email(String)
    case phone(String)
    case company(String)

    var icon:String {
        switch self {
        case .name: return "person.fill"
        case .email: return "envelope.fill"
        case .phone: return "phone.fill"
        case .company: return "building.2.fill"
        }
    }

    var label:String {
        switch self {
        case .name: return "Name"
        case .email: return "Email"
        case .phone: return "Phone"
        case .company: return "Company"
        }
    }

    var value:String {
        switch self {
        case .name(let v), .email(let v), .phone(let v), .company(let v):
            return v
        }
    }
}

// MARK: - Empty Model

struct EmptyModel: NetworkModel {}

extension Array: NetworkModel where Element: NetworkModel {}

// MARK: - JSONPlaceholder Models

struct Post: NetworkModel {
    var id: Int?
    var userId: Int?
    var title: String?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case id, userId, title, body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
        self.userId = try? container.decodeIfPresent(Int.self, forKey: .userId)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.body = try? container.decodeIfPresent(String.self, forKey: .body)
    }
}

struct Comment: NetworkModel {
    var id: Int?
    var postId: Int?
    var name: String?
    var email: String?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case id, postId, name, email, body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
        self.postId = try? container.decodeIfPresent(Int.self, forKey: .postId)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.email = try? container.decodeIfPresent(String.self, forKey: .email)
        self.body = try? container.decodeIfPresent(String.self, forKey: .body)
    }
}

struct User: NetworkModel {
    var id: Int?
    var name: String?
    var username: String?
    var email: String?
    var phone: String?
    var website: String?
    var company: Company?

    enum CodingKeys: String, CodingKey {
        case id, name, username, email, phone, website, company
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.username = try? container.decodeIfPresent(String.self, forKey: .username)
        self.email = try? container.decodeIfPresent(String.self, forKey: .email)
        self.phone = try? container.decodeIfPresent(String.self, forKey: .phone)
        self.website = try? container.decodeIfPresent(String.self, forKey: .website)
        self.company = try? container.decodeIfPresent(Company.self, forKey: .company)
    }

    struct Company: NetworkModel {
        var name: String?
        var catchPhrase: String?

        enum CodingKeys: String, CodingKey {
            case name, catchPhrase
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try? container.decodeIfPresent(String.self, forKey: .name)
            self.catchPhrase = try? container.decodeIfPresent(String.self, forKey: .catchPhrase)
        }
    }
}

// MARK: - PokeAPI Models

struct PokemonListResponse: NetworkModel {
    var count: Int?
    var results: [PokemonListItem]?

    enum CodingKeys: String, CodingKey {
        case count, results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.count = try? container.decodeIfPresent(Int.self, forKey: .count)
        self.results = try? container.decodeIfPresent([PokemonListItem].self, forKey: .results)
    }
}

struct PokemonListItem: NetworkModel {
    var name: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case name, url
    }

    init(name:String?, url:String?) {
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.url = try? container.decodeIfPresent(String.self, forKey: .url)
    }

    var id: Int {
        let parts = (url ?? "").split(separator: "/")
        return Int(parts.last ?? "0") ?? 0
    }

    var spriteURL: URL? {
        URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/\(id).png")
    }
}

struct PokemonDetail: NetworkModel {
    var id: Int?
    var name: String?
    var height: Int?
    var weight: Int?
    var baseExperience: Int?
    var types: [TypeSlot]?
    var stats: [StatEntry]?
    var sprites: Sprites?

    enum CodingKeys: String, CodingKey {
        case id, name, height, weight, types, stats, sprites
        case baseExperience = "base_experience"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.height = try? container.decodeIfPresent(Int.self, forKey: .height)
        self.weight = try? container.decodeIfPresent(Int.self, forKey: .weight)
        self.baseExperience = try? container.decodeIfPresent(Int.self, forKey: .baseExperience)
        self.types = try? container.decodeIfPresent([TypeSlot].self, forKey: .types)
        self.stats = try? container.decodeIfPresent([StatEntry].self, forKey: .stats)
        self.sprites = try? container.decodeIfPresent(Sprites.self, forKey: .sprites)
    }

    struct TypeSlot: NetworkModel {
        var slot: Int?
        var type: TypeInfo?

        enum CodingKeys: String, CodingKey {
            case slot, type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.slot = try? container.decodeIfPresent(Int.self, forKey: .slot)
            self.type = try? container.decodeIfPresent(TypeInfo.self, forKey: .type)
        }

        struct TypeInfo: NetworkModel {
            var name: String?

            enum CodingKeys: String, CodingKey {
                case name
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.name = try? container.decodeIfPresent(String.self, forKey: .name)
            }
        }
    }

    struct StatEntry: NetworkModel {
        var baseStat: Int?
        var stat: StatInfo?

        enum CodingKeys: String, CodingKey {
            case baseStat = "base_stat"
            case stat
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.baseStat = try? container.decodeIfPresent(Int.self, forKey: .baseStat)
            self.stat = try? container.decodeIfPresent(StatInfo.self, forKey: .stat)
        }

        struct StatInfo: NetworkModel {
            var name: String?

            enum CodingKeys: String, CodingKey {
                case name
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.name = try? container.decodeIfPresent(String.self, forKey: .name)
            }
        }
    }

    struct Sprites: NetworkModel {
        var frontDefault: String?

        enum CodingKeys: String, CodingKey {
            case frontDefault = "front_default"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.frontDefault = try? container.decodeIfPresent(String.self, forKey: .frontDefault)
        }
    }

    var primaryType: String {
        (types ?? []).min(by: { ($0.slot ?? 0) < ($1.slot ?? 0) })?.type?.name ?? "normal"
    }

    var typeNames: [String] {
        (types ?? []).sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map { ($0.type?.name ?? "").capitalized }
    }

    var typeColor: UIColor {
        switch primaryType {
        case "fire":     return UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1)
        case "water":    return UIColor(red: 0.27, green: 0.59, blue: 1.0, alpha: 1)
        case "grass":    return UIColor(red: 0.29, green: 0.74, blue: 0.38, alpha: 1)
        case "electric": return UIColor(red: 1.0, green: 0.80, blue: 0.10, alpha: 1)
        case "psychic":  return UIColor(red: 0.96, green: 0.30, blue: 0.56, alpha: 1)
        case "ice":      return UIColor(red: 0.44, green: 0.82, blue: 0.92, alpha: 1)
        case "dragon":   return UIColor(red: 0.44, green: 0.24, blue: 0.90, alpha: 1)
        case "dark":     return UIColor(red: 0.27, green: 0.22, blue: 0.20, alpha: 1)
        case "fairy":    return UIColor(red: 0.97, green: 0.62, blue: 0.82, alpha: 1)
        case "fighting": return UIColor(red: 0.77, green: 0.22, blue: 0.10, alpha: 1)
        case "poison":   return UIColor(red: 0.62, green: 0.25, blue: 0.72, alpha: 1)
        case "ground":   return UIColor(red: 0.89, green: 0.75, blue: 0.42, alpha: 1)
        case "rock":     return UIColor(red: 0.72, green: 0.65, blue: 0.37, alpha: 1)
        case "bug":      return UIColor(red: 0.64, green: 0.74, blue: 0.13, alpha: 1)
        case "ghost":    return UIColor(red: 0.43, green: 0.32, blue: 0.59, alpha: 1)
        case "steel":    return UIColor(red: 0.72, green: 0.72, blue: 0.81, alpha: 1)
        case "flying":   return UIColor(red: 0.59, green: 0.70, blue: 0.98, alpha: 1)
        default:         return UIColor(red: 0.65, green: 0.65, blue: 0.60, alpha: 1)
        }
    }
}
