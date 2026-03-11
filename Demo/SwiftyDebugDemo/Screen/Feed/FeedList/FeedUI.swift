//
//  FeedUI.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

enum FeedUIActions {
    case selectPost(post:Post)
    case deletePost(id:Int)
    case refresh
}

protocol FeedUIDelegate:AnyObject {
    func doActions(_ actions: FeedUIActions)
}

class FeedUI: BaseUI {

    weak var delegate:FeedUIDelegate?
    private var posts:[Post] = []

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: configureLayout())
        cv.backgroundColor = .systemGroupedBackground
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        cv.register(PostCell.self, forCellWithReuseIdentifier: PostCell.reuseId)
        cv.delegate = self
        cv.dataSource = self
        return cv
    }()

    private let refreshControl = UIRefreshControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElements()
        setupConstraints()
        refreshControl.addTarget(self, action: #selector(onRefresh), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.addSubview(collectionView)
        collectionView.refreshControl = refreshControl
    }

    override func setupConstraints() {
        super.setupConstraints()
        collectionView.anchor([.fill(uiHolderView)])
    }

    func setupPosts(_ posts:[Post]) {
        self.posts = posts
        refreshControl.endRefreshing()
        collectionView.reloadData()
    }

    func addPost(_ post:Post) {
        posts.insert(post, at: 0)
        collectionView.insertItems(at: [IndexPath(item: 0, section: 0)])
    }

    func removePost(id:Int) {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else{return}
        posts.remove(at: idx)
        collectionView.deleteItems(at: [IndexPath(item: idx, section: 0)])
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    @objc private func onRefresh() {
        delegate?.doActions(.refresh)
    }

    private func configureLayout() -> UICollectionViewLayout {
        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.scrollDirection = .vertical

        let sectionProvider = { (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(110))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(110))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 0
            return section
        }
        return UICollectionViewCompositionalLayout(sectionProvider: sectionProvider, configuration: config)
    }
}

extension FeedUI: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        posts.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PostCell.reuseId, for: indexPath) as! PostCell
        cell.setupCell(model: posts[indexPath.item])
        return cell
    }
}

extension FeedUI: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.doActions(.selectPost(post: posts[indexPath.item]))
    }
}
