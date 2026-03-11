//
//  DemoInfoVM.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS
import Factory

enum DemoInfoVMActions {
    case didFireRequests
}

@MainActor protocol DemoInfoVMDelegate:AnyObject {
    func doActions(_ actions: DemoInfoVMActions)
}

class DemoInfoVM: BaseVM {

    @Injected(RepoContainer.feedRepo) private var feedRepo:FeedRepo
    @Injected(RepoContainer.pokemonRepo) private var pokemonRepo:PokemonRepo
    weak var delegate:DemoInfoVMDelegate?

    required init() {
        super.init()
    }

    func fireTestRequests() {
        Logger.info("Firing batch test requests...")
        Task { [weak self] in
            guard let self else{return}
            async let posts = makeAwaitRequst({ [weak self] in await self?.feedRepo.fetchPosts() })
            async let user = makeAwaitRequst({ [weak self] in await self?.feedRepo.fetchUser(id: 3) })
            async let pikachu = makeAwaitRequst({ [weak self] in await self?.pokemonRepo.fetchDetail(name: "pikachu") })
            async let mewtwo = makeAwaitRequst({ [weak self] in await self?.pokemonRepo.fetchDetail(name: "mewtwo") })
            async let createPost = makeAwaitRequst({ [weak self] in await self?.feedRepo.createPost(title: "Test Post", body: "Fired from SwiftyDebug Demo", userId: 1) })
            async let deletePost = makeAwaitRequst({ [weak self] in await self?.feedRepo.deletePost(id: 42) })

            let _ = await (posts, user, pikachu, mewtwo, createPost, deletePost)
            Logger.debug("Batch requests complete")
            await delegate?.doActions(.didFireRequests)
        }
    }
}
