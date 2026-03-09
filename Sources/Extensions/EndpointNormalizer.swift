//
//  EndpointNormalizer.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

enum EndpointNormalizer {

    /// Replaces numeric IDs and UUIDs in a URL path with `{id}` so that
    /// different requests to the same endpoint pattern match each other.
    /// e.g. `/api/users/123/orders` → `/api/users/{id}/orders`
    static func normalize(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        let normalized = components.map { component -> String in
            if component.isEmpty { return component }
            if component.allSatisfy({ $0.isNumber || $0 == "-" }) && component.contains(where: { $0.isNumber }) {
                return "{id}"
            }
            if UUID(uuidString: component) != nil { return "{id}" }
            return component
        }
        return normalized.joined(separator: "/")
    }
}
