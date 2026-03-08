//
//  UIImage+GIF.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit
import ImageIO

@objc extension UIImage {

    /// Obtain the GIF image object according to the data data of a GIF image
    @objc static func imageWithGIFData(_ data: Data?) -> UIImage? {
        guard let data = data else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)

        if count <= 1 {
            return UIImage(data: data)
        }

        var images = [UIImage]()
        var duration: TimeInterval = 0.0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }

            let frameDuration = UIImage.ssz_frameDurationAtIndex(i, source: source)
            duration += Double(frameDuration)

            images.append(UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up))
        }

        if duration == 0 {
            duration = (1.0 / 10.0) * Double(count)
        }

        return UIImage.animatedImage(with: images, duration: duration)
    }

    /// Obtain the GIF image object according to the name of the local GIF image
    @objc static func imageWithGIFNamed(_ name: String?) -> UIImage? {
        guard let name = name else { return nil }
        let scale = Int(UIScreen.main.scale)
        return gifName(name, scale: scale)
    }

    /// Obtain the GIF image object according to the URL of a GIF image
    @objc static func imageWithGIFUrl(_ url: String?, gifImageBlock: ((UIImage?) -> Void)?) {
        guard let url = url, let gifUrl = URL(string: url) else { return }

        DispatchQueue.global().async {
            let gifData = try? Data(contentsOf: gifUrl)

            DispatchQueue.main.async {
                gifImageBlock?(UIImage.imageWithGIFData(gifData))
            }
        }
    }

    // MARK: - Private GIF Helpers

    private static func gifName(_ name: String, scale: Int) -> UIImage? {
        var scale = scale
        var imagePath = Bundle.main.path(forResource: "\(name)@\(scale)x", ofType: "gif")

        if imagePath == nil {
            if scale + 1 > 3 {
                scale -= 1
            } else {
                scale += 1
            }
            imagePath = Bundle.main.path(forResource: "\(name)@\(scale)x", ofType: "gif")
        }

        if let imagePath = imagePath {
            if let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                return UIImage.imageWithGIFData(imageData)
            }
        }

        // Try without scale suffix
        if let imagePath = Bundle.main.path(forResource: name, ofType: "gif") {
            if let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                return UIImage.imageWithGIFData(imageData)
            }
        }

        return UIImage(named: name)
    }

    private static func ssz_frameDurationAtIndex(_ index: Int, source: CGImageSource) -> Float {
        var frameDuration: Float = 0.1

        guard let cfFrameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) else {
            return frameDuration
        }

        let frameProperties = cfFrameProperties as NSDictionary
        let gifProperties = frameProperties[kCGImagePropertyGIFDictionary as String] as? NSDictionary

        if let delayTimeUnclamped = gifProperties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber {
            frameDuration = delayTimeUnclamped.floatValue
        } else if let delayTime = gifProperties?[kCGImagePropertyGIFDelayTime as String] as? NSNumber {
            frameDuration = delayTime.floatValue
        }

        if frameDuration < 0.011 {
            frameDuration = 0.100
        }

        return frameDuration
    }
}
