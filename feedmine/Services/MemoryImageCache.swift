import UIKit

/// In-memory image cache using NSCache. Thread-safe via @unchecked Sendable
/// (NSCache is internally thread-safe). Used by MediaAssetStore — never
/// consulted directly by views to decide whether to show an image.
final class MemoryImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 200 * 1024 * 1024  // 200 MB
        return c
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String, cost: Int? = nil) {
        if let cost {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            cache.setObject(image, forKey: key as NSString)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
