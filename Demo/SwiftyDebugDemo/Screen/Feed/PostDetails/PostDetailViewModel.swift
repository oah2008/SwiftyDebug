//
//  PostDetailViewModel.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS
import Factory

enum PostDetailVMActions {
    case didFetchData(user:User?, comments:[Comment]?)
}

@MainActor protocol PostDetailVMDelegate:AnyObject {
    func doActions(_ actions: PostDetailVMActions)
}

class PostDetailVM: BaseVM {

    @Injected(RepoContainer.feedRepo) private var feedRepo:FeedRepo
    private var post:Post?
    weak var delegate:PostDetailVMDelegate?

    required init() {
        super.init()
    }

    enum PostDetailFetchResult {
        case user(User?)
        case comments([Comment]?)
    }

    func load(post:Post) {
        self.post = post
        Logger.debug("Loading post #\(post.id ?? 0) details...")
        Task { [weak self] in
            guard let self else{return}
            var user:User?
            var comments:[Comment]?

            let sections = await fetchSectionsData()
            for section in sections {
                switch section {
                case .user(let u):
                    user = u
                case .comments(let c):
                    comments = c
                }
            }

            await delegate?.doActions(.didFetchData(user: user, comments: comments))
        }
    }

    private func fetchSectionsData() async -> [PostDetailFetchResult] {

        let sectionsData = await withTaskGroup(of: PostDetailFetchResult.self) { [weak self] group -> [PostDetailFetchResult] in

            var results = [PostDetailFetchResult]()

            group.addTask { [weak self] in
                let result = await self?.makeAwaitRequst({ [weak self] in await self?.feedRepo.fetchUser(id: self?.post?.userId ?? 0) })
                guard case .onSuccess(let user, _) = result else { return .user(nil) }
                Logger.debug("Loaded user: \(user?.name ?? "")")
                return .user(user)
            }

            group.addTask { [weak self] in
                let result = await self?.makeAwaitRequst({ [weak self] in await self?.feedRepo.fetchComments(postId: self?.post?.id ?? 0) })
                guard case .onSuccess(let comments, _) = result else { return .comments(nil) }
                Logger.debug("Loaded \(comments?.count ?? 0) comments")
                return .comments(comments)
            }

            for await value in group {
                results.append(value)
            }
            return results
        }
        return sectionsData
    }
}
