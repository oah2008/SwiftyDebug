//
//  PostDetailViewController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class PostDetailViewController: BaseVC<PostDetailVM, PostDetailUI> {

    private let post:Post

    init(post:Post) {
        self.post = post
        super.init(nibName: nil, bundle: nil)
        title = "Post #\(post.id ?? 0)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        viewModel.delegate = self
        viewModel.load(post: post)
    }
}

extension PostDetailViewController: PostDetailVMDelegate {

    func doActions(_ actions: PostDetailVMActions) {
        switch actions {
        case .didFetchData(let user, let comments):
            ui.setup(post: post, user: user, comments: comments)
        }
    }
}
