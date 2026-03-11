//
//  FeedViewModel.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS
import Factory

enum FeedVMActions {
    case didFetchPosts(posts:[Post])
    case didCreatePost(post:Post)
    case didDeletePost(id:Int)
    case onError
}

@MainActor protocol FeedVMDelegate:AnyObject {
    func doActions(_ actions: FeedVMActions)
}

class FeedVM: BaseVM {

    @Injected(RepoContainer.feedRepo) private var feedRepo:FeedRepo
    weak var delegate:FeedVMDelegate?

    required init() {
        super.init()
    }

    func fetchPosts() {
        Task { [weak self] in
            guard let self else{return}
            Logger.debug("Fetching posts...")
            let result = await makeAwaitRequst({ [weak self] in await self?.feedRepo.fetchPosts() })
            guard case .onSuccess(let posts, _) = result, let posts else {
                Logger.error("Posts fetch failed")
                await delegate?.doActions(.onError)
                return
            }
            Logger.debug("Loaded \(posts.count) posts")
            await delegate?.doActions(.didFetchPosts(posts: posts))
        }
    }

    func createPost(title:String, body:String) {
        Task { [weak self] in
            guard let self else{return}
            Logger.debug("Creating post: \"\(title)\"")
            let result = await makeAwaitRequst({ [weak self] in await self?.feedRepo.createPost(title: title, body: body, userId: 1) })
            guard case .onSuccess(let post, _) = result, let post else {
                Logger.error("Create failed")
                await delegate?.doActions(.onError)
                return
            }
            Logger.debug("Post created id:\(post.id ?? 0)")
            await delegate?.doActions(.didCreatePost(post: post))
        }
    }

    func deletePost(id:Int) {
        Task { [weak self] in
            guard let self else{return}
            Logger.info("Deleting post \(id)...")
            let result = await makeAwaitRequst({ [weak self] in await self?.feedRepo.deletePost(id: id) })
            guard case .onSuccess(_, _) = result else {
                Logger.error("Delete failed")
                await delegate?.doActions(.onError)
                return
            }
            Logger.debug("Post \(id) deleted")
            await delegate?.doActions(.didDeletePost(id: id))
        }
    }
}
