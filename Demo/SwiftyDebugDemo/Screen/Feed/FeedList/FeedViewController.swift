//
//  FeedViewController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class FeedViewController: BaseVC<FeedVM, FeedUI> {

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.delegate = self
        ui.delegate = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(createPostTapped))
        viewModel.fetchPosts()
    }

    @objc private func createPostTapped() {
        let alert = UIAlertController(title: "New Post", message: "Simulate a POST request", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Title" }
        alert.addTextField { $0.placeholder = "Body" }
        alert.addAction(UIAlertAction(title: "Post", style: .default) { [weak self] _ in
            let title = alert.textFields?[0].text ?? "Demo Post"
            let body  = alert.textFields?[1].text ?? "Demo body content"
            self?.viewModel.createPost(title: title, body: body)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

extension FeedViewController: FeedUIDelegate {

    func doActions(_ actions: FeedUIActions) {
        switch actions {
        case .selectPost(let post):
            let vc = PostDetailViewController(post: post)
            navigationController?.pushViewController(vc, animated: true)
        case .deletePost(let id):
            viewModel.deletePost(id: id)
        case .refresh:
            viewModel.fetchPosts()
        }
    }
}

extension FeedViewController: FeedVMDelegate {

    func doActions(_ actions: FeedVMActions) {
        switch actions {
        case .didFetchPosts(let posts):
            ui.setupPosts(posts)
        case .didCreatePost(let post):
            ui.addPost(post)
        case .didDeletePost(let id):
            ui.removePost(id: id)
        case .onError:
            ui.endRefreshing()
        }
    }
}
