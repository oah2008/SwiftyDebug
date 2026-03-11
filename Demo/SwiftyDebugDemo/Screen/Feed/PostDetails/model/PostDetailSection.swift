//
//  PostDetailSection.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation


enum PostDetailSectionType: Int, CaseIterable {

    case post = 0
    case author
    case comments

    var title:String {
        switch self {
        case .post: return "POST"
        case .author: return "AUTHOR"
        case .comments: return "COMMENTS"
        }
    }
}

struct PostDetailSectionItem {
    var type:PostDetailSectionItemType
    let id:Int = Int(arc4random_uniform(1000000))
}

enum PostDetailSectionItemType {

    case postBody(post:Post)
    case userInfo(item:UserItemType)
    case comment(comment:Comment)

    var cellInfo:CellInfo {
        switch self {
        case .postBody:
            return .init(cell: PostBodyCell.self, reuseId: PostBodyCell.reuseId)
        case .userInfo:
            return .init(cell: UserInfoCell.self, reuseId: UserInfoCell.reuseId)
        case .comment:
            return .init(cell: CommentCell.self, reuseId: CommentCell.reuseId)
        }
    }
}

struct PostDetailSection {

    let type:PostDetailSectionType
    var items:[PostDetailSectionItem] = []

    init(type:PostDetailSectionType, post:Post? = nil, user:User? = nil, comments:[Comment]? = nil) {
        self.type = type
        self.items = getItems(post: post, user: user, comments: comments)
    }

    func getItems(post:Post? = nil, user:User? = nil, comments:[Comment]? = nil) -> [PostDetailSectionItem] {
        switch type {
        case .post:
            guard let post else{return []}
            return [.init(type: .postBody(post: post))]
        case .author:
            guard let user else{return []}
            return getUserItems(user: user)
        case .comments:
            guard let comments, !comments.isEmpty else{return []}
            return comments.map { .init(type: .comment(comment: $0)) }
        }
    }

    private func getUserItems(user:User) -> [PostDetailSectionItem] {
        var items:[UserItemType] = []
        if let name = user.name, !name.isEmpty { items.append(.name(name)) }
        if let email = user.email, !email.isEmpty { items.append(.email(email)) }
        if let phone = user.phone, !phone.isEmpty { items.append(.phone(phone)) }
        if let company = user.company?.name, !company.isEmpty { items.append(.company(company)) }
        return items.map { .init(type: .userInfo(item: $0)) }
    }
}
