//
//  FilterableEndpoint.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// One row in the endpoint sub-filter list.
struct FilterableEndpoint {
    /// Relative sub-path shown in the UI (e.g. "/stores/{id}")
    let displayPath: String
    /// Full normalized path used as the filter key in applyFilter() (e.g. "/mahally/v2/stores/{id}")
    let filterPath: String
    /// Parent group label — the tag name or host (e.g. "mahally")
    let tag: String
}
