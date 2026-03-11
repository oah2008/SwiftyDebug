//
//  BaseImageView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import UIKit
import Kingfisher

class BaseImageView: UIImageView {

    var placeHolder:UIImage?
    var onFailureImage:UIImage?

    func loadImage(url:URL?, completed:(() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let url else {
                self?.image = self?.onFailureImage ?? self?.placeHolder
                completed?()
                return
            }
            guard let self else {
                completed?()
                return
            }
            kf.indicatorType = .activity
            var size = self.bounds.size
            if size == .zero {
                size = .init(width: 500, height: 500)
            }
            size = CGSize(width: size.width.rounded(), height: size.height.rounded())

            KF.url(url)
                .fade(duration: 0.4)
                .backgroundDecode(true)
                .cacheOriginalImage(true)
                .retry(maxCount: 1, interval: .accumulated(3))
                .diskCacheExpiration(.seconds(3600))
                .memoryCacheExpiration(.seconds(600))
                .downsampling(size: size)
                .scaleFactor(UIScreen.main.scale)
                .placeholder(self.placeHolder)
                .onFailureImage(self.onFailureImage)
                .onSuccess { _ in completed?() }
                .onFailure { _ in completed?() }
                .set(to: self)
        }
    }
}
