import PDFKit
import SwiftUI

struct PageThumbnail: View {
    let url: URL
    let pageIndex: Int
    @State private var thumbnail: UIImage?

    private var cacheKey: String {
        "\(url.path)#\(pageIndex)"
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: cacheKey) {
            thumbnail = nil
            let result = await ThumbnailCache.shared.image(url: url, pageIndex: pageIndex)
            guard !Task.isCancelled else { return }
            thumbnail = result.image
        }
        .accessibilityHidden(true)
    }
}

private struct ThumbnailImage: @unchecked Sendable {
    let image: UIImage?
}

private actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(url: URL, pageIndex: Int) -> ThumbnailImage {
        let key = "\(url.path)#\(pageIndex)" as NSString
        if let image = cache.object(forKey: key) {
            return ThumbnailImage(image: image)
        }
        guard !Task.isCancelled else { return ThumbnailImage(image: nil) }
        return autoreleasepool {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: pageIndex) else { return ThumbnailImage(image: nil) }
            let image = page.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            return ThumbnailImage(image: image)
        }
    }
}
