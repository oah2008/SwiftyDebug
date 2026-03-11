//
//  FeedEndPoint.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS

enum FeedEndPoint {
    case posts
    case createPost
    case deletePost(id:Int)
    case comments(postId:Int)
    case user(id:Int)
}

extension FeedEndPoint: NetworkEndpoints {

    var info: EndpointInfo {
        switch self {
        case .posts:
            return .init("posts", .get)
        case .createPost:
            return .init("posts", .post)
        case .deletePost(let id):
            return .init("posts/\(id)", .delete)
        case .comments(let postId):
            return .init("posts/\(postId)/comments", .get)
        case .user(let id):
            return .init("users/\(id)", .get)
        }
    }
}
