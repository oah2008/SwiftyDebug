//
//  NetworkGroup.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Represents a group of network requests sharing the same urls prefix or host.
struct NetworkGroup {
    let key: String           // urls stripped path or host
    let displayName: String   // tag name if available, else the key
    let fullURL: String       // the urls URL or host for subtitle display
    let tag: String?          // from networkTagMap
    let isPathFilter: Bool    // true if from urls, false if plain host
    let count: Int            // request count
    let models: [NetworkTransaction]   // refs to actual models (for drill-down)
}
