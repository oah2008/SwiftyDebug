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
    var content: String?
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
    var heigth:Double = 0
    var mustInPreview:Bool = false
    /// Show "Preview JSON" button for this section
    var showPreview: Bool = false
    /// Info-only section (e.g. ERROR) — uses dimmer styling, no preview
    var isInfoOnly: Bool = false
    /// Optional size annotation shown after the section title (e.g. "↑ 12.4 KB")
    var sizeTag: String? = nil
    /// Other requests shown horizontally in the "SIMILAR REQUESTS" section
    var similarRequests: [NetworkTransaction]? = nil


    init(title: String? = nil, content: String? = "", url: String? = "", image: UIImage? = nil, httpModel: NetworkTransaction? = nil) {
        self.title = title?.replacingOccurrences(of: "\\/", with: "/")
        self.content = content?.replacingOccurrences(of: "\\/", with: "/")
        self.url = url?.replacingOccurrences(of: "\\/", with: "/")
        self.image = image
        self.httpModel = httpModel

        mustInPreview = (content?.count ?? 0 > 10000)
        self.heigth = mustInPreview ? 100 : Double((self.content as NSString?)?.heightWithFont(UIFont.systemFont(ofSize: 13), constraintToWidth: (UIScreen.main.bounds.size.width - 30)) ?? 0.0)
    }
}
