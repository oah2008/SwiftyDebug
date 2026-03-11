//
//  PostDetailUI.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class PostDetailUI: BaseUI {

    private var post:Post?
    private var user:User?
    private var comments:[Comment] = []
    private var sections:[PostDetailSection] = []

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: configureLayout())
        cv.backgroundColor = .systemGroupedBackground
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        cv.register(SectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: SectionHeaderView.reuseId)
        cv.delegate = self
        cv.dataSource = self
        return cv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElements()
        setupConstraints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.addSubview(collectionView)
    }

    override func setupConstraints() {
        super.setupConstraints()
        collectionView.anchor([.fill(uiHolderView)])
    }

    func setup(post:Post, user:User? = nil, comments:[Comment]? = nil) {
        self.post = post
        self.user = user
        self.comments = comments ?? []
        buildSections()
    }

    private func buildSections() {
        sections.removeAll()

        for type in PostDetailSectionType.allCases {
            let section:PostDetailSection
            switch type {
            case .post:
                section = PostDetailSection(type: type, post: post)
            case .author:
                section = PostDetailSection(type: type, user: user)
            case .comments:
                section = PostDetailSection(type: type, comments: comments)
            }
            guard section.items.count > 0 else{continue}
            sections.append(section)
            registerCell(section: section)
        }
        collectionView.reloadData()
    }

    private func registerCell(section:PostDetailSection) {
        for cell in section.items {
            let cellInfo = cell.type.cellInfo
            collectionView.register(cellInfo.cell, forCellWithReuseIdentifier: cellInfo.reuseId)
        }
    }

    private func configureLayout() -> UICollectionViewLayout {
        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.scrollDirection = .vertical
        config.interSectionSpacing = 10

        let sectionProvider = { (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(60))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(60))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            section.interGroupSpacing = 0

            let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(40))
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]

            return section
        }
        return UICollectionViewCompositionalLayout(sectionProvider: sectionProvider, configuration: config)
    }
}

extension PostDetailUI: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let section = sections[section]
        return section.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let section = sections[indexPath.section]
        let item = section.items[indexPath.row]
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: item.type.cellInfo.reuseId, for: indexPath) as! PostDetailBaseCell

        var cellPosstion:CellPosstion = (indexPath.item == 0) ? .top : (indexPath.item == (section.items.count - 1) ? .bottom : .middle)
        cellPosstion = (section.items.count == 1) ? .all : cellPosstion

        switch item.type {
        case .postBody(let post):
            cell.setupCell(post: post)
        case .userInfo(let item):
            cell.setupCell(user: item, cellPosstion: cellPosstion)
        case .comment(let comment):
            cell.setupCell(comment: comment)
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: SectionHeaderView.reuseId, for: indexPath) as! SectionHeaderView
        let section = sections[indexPath.section]
        let title:String
        switch section.type {
        case .comments:
            title = "\(section.type.title) (\(section.items.count))"
        case .post, .author:
            title = section.type.title
        }
        header.setup(title: title)
        return header
    }
}

extension PostDetailUI: UICollectionViewDelegate {}
