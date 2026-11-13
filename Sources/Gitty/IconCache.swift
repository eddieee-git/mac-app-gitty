import AppKit
import UniformTypeIdentifiers

/// 파일 아이콘을 기억해 둔다. 목록을 다시 그릴 때마다 파일마다 아이콘을 새로 가져오면 큰 폴더에서 느려진다.
/// 대부분은 확장자별로 같은 아이콘이라 확장자로 기억하고, 앱·사용자 아이콘처럼 파일마다 다른 것만 경로로 기억한다.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let perFileExtensions: Set<String> = ["app", "icns", "webloc", "alias", ""]

    static func icon(for item: FileItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let key: String
        if item.isDirectory {
            key = "dir:" + item.url.path          // 폴더는 Google Drive·다운로드처럼 특별한 아이콘이 있을 수 있다
        } else if perFileExtensions.contains(ext) {
            key = "file:" + item.url.path
        } else {
            key = "ext:" + ext
        }
        if let image = cache.object(forKey: key as NSString) { return image }
        let image: NSImage
        if key.hasPrefix("ext:"), let type = UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
