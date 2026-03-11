//
//  RepoContainer.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import Factory

class RepoContainer: SharedContainer {
    static let feedRepo = Factory(scope: .shared) { FeedRepo() }
    static let pokemonRepo = Factory(scope: .shared) { PokemonRepo() }
}
