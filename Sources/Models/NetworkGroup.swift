//
//  NetworkGroup.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// A group of requests that resolve to the same tag. (See TAGS-FILTER.)
struct NetworkGroup {
    /// `NetworkTag.key` — the group's identity, and the string every surface
    /// hashes for the pill colour. Hashing the LABEL instead is what made one
    /// tag render in a different hue in the group header than on its own rows.
    let key: String
    let displayName: String   // the tag's label
    let fullURL: String       // what the tag matched, for subtitle display
    let tag: String?          // the tag's label, or nil when there is none
    let isPathFilter: Bool    // true when the tag came from `addTag`
    let count: Int            // request count
    let models: [NetworkTransaction]   // refs to actual models (for drill-down)
}
