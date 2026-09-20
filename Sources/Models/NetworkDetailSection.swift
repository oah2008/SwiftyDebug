//
//  NetworkDetailSection.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

struct NetworkDetailSection {
    var title: String?

    /// The text the section renders.
    ///
    /// Assigning it after construction also refreshes `rawContent`. Without that
    /// the invariant "copy reads `rawContent`, display reads `content`" was only
    /// held by the two sections that happened to set `rawContent` by hand: every
    /// other one (REQUEST PARAMETERS, JWT, ERROR DETAILS, CACHE, REWRITES) is
    /// built by `init(content: nil)` and then assigned, so its `rawContent`
    /// stayed nil and `NetworkDetailCell.tapCopy` silently fell back to the
    /// display string. A post-init assignment is never the `\/`-substituted
    /// form — that transform only happens inside `init` — so the assigned value
    /// IS the raw content. (Property observers do not run during `init`, so the
    /// initialiser's own transformed assignment cannot clobber it.) (See COPY.)
    var content: String? {
        didSet {
            rawContent = content
            // The truncation threshold has to follow the value, not the
            // initialiser argument. Every section built as `init(content: nil)`
            // and filled in afterwards (REQUEST PARAMETERS, JWT, ERROR DETAILS,
            // REWRITES) kept the `false` that `init` computed from `nil`, so a
            // 200 KB query string was syntax-highlighted and laid out whole in
            // one cell with no "Show Full" way out of it. (Property observers do
            // not run during `init`, so `init` must still compute it too.)
            mustInPreview = (content?.count ?? 0) > 10000
        }
    }
    var url: String?
    var image: UIImage?
    var blankContent: String?
    var isLast: Bool = false
    var requestSerializer: RequestSerializer = RequestSerializer.json//default JSON format
    var requestHeaderFields: [String: Any]?
    var responseHeaderFields: [String: Any]?
    var requestData: Data?
    var responseData: Data?
    var httpModel: NetworkTransaction?
    var mustInPreview:Bool = false
    /// Show "Preview JSON" button for this section
    var showPreview: Bool = false
    /// Info-only section (e.g. ERROR) — uses dimmer styling, no preview
    var isInfoOnly: Bool = false
    /// Optional size annotation shown after the section title (e.g. "↑ 12.4 KB")
    var sizeTag: String? = nil
    /// Other requests shown horizontally in the "SIMILAR REQUESTS" section
    var similarRequests: [NetworkTransaction]? = nil
    /// Image URLs parsed from the response JSON, shown in the "MEDIA" grid section.
    var mediaImageURLs: [String]? = nil
    /// Original content before display transformation — used for copying valid JSON.
    var rawContent: String? = nil


    init(title: String? = nil, content: String? = "", url: String? = "", image: UIImage? = nil, httpModel: NetworkTransaction? = nil) {
        self.title = title?.replacingOccurrences(of: "\\/", with: "/")
        self.rawContent = content
        self.content = content?.replacingOccurrences(of: "\\/", with: "/")
        self.url = url?.replacingOccurrences(of: "\\/", with: "/")
        self.image = image
        self.httpModel = httpModel

        mustInPreview = (content?.count ?? 0) > 10000
    }
}
