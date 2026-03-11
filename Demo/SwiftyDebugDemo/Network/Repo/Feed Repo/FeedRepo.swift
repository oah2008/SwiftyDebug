//
//  FeedRepo.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS

class FeedRepo: BaseRepo {

    func fetchPosts() async -> APIResult.Result<[Post]>? {
        let endpoint = FeedEndPoint.posts
        let result = await makeModelRequest(model: [Post].self, endPoint: endpoint.info)
        return result
    }

    func fetchUser(id:Int) async -> APIResult.Result<User>? {
        let endpoint = FeedEndPoint.user(id: id)
        let result = await makeModelRequest(model: User.self, endPoint: endpoint.info)
        return result
    }

    func fetchComments(postId:Int) async -> APIResult.Result<[Comment]>? {
        let endpoint = FeedEndPoint.comments(postId: postId)
        let result = await makeModelRequest(model: [Comment].self, endPoint: endpoint.info)
        return result
    }

    func createPost(title:String, body:String, userId:Int) async -> APIResult.Result<Post>? {
        let endpoint = FeedEndPoint.createPost
        let parameters:[String: Any] = ["title": title, "body": body, "userId": userId]
        let result = await makeModelRequest(model: Post.self, endPoint: endpoint.info, parameters: parameters)
        return result
    }

    func deletePost(id:Int) async -> APIResult.Result<EmptyModel>? {
        let endpoint = FeedEndPoint.deletePost(id: id)
        let result = await makeModelRequest(model: EmptyModel.self, endPoint: endpoint.info)
        return result
    }
}
