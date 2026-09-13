import Foundation
import AppKit

/// 剪贴板图片 → 匿名图床（uguu.se，失败退 tmpfiles.org）→ 返回 URL。
/// 与 iOS Blink 的 ImageHostUploader 同一套行为。远程会话贴图用这里；本机会话不走
/// （claude-code 直接读本机剪贴板，见 TerminalManager 的 uploadImageOnPaste 判断）。
enum ImageHostUploader {

    /// 粘贴入口：剪贴板若有图片，逐张上传、URL 换行拼接后 send 进终端；返回 true 表示已处理
    /// （调用方别再走原生粘贴）。没有图片返回 false。
    static func handlePaste(_ pb: NSPasteboard,
                            send: @escaping (String) -> Void,
                            toast: ((String) -> Void)?) -> Bool {
        let jpegs = pasteboardJPEGs(pb)
        guard !jpegs.isEmpty else { return false }
        let total = jpegs.count
        toast?(total == 1 ? "上传中…" : "正在上传 \(total) 张…")
        var urls = [String?](repeating: nil, count: total)   // 保序
        let group = DispatchGroup()
        for (i, data) in jpegs.enumerated() {
            group.enter()
            upload(jpegData: data) { url in
                DispatchQueue.main.async { urls[i] = url; group.leave() }
            }
        }
        group.notify(queue: .main) {
            let good = urls.compactMap { $0 }
            guard !good.isEmpty else { toast?("图片上传失败"); return }
            send(good.joined(separator: "\n"))
            if good.count == total {
                toast?(total == 1 ? "已插入图片链接" : "已插入 \(total) 个图片链接")
            } else {
                toast?("\(good.count)/\(total) 已插入，失败 \(total - good.count) 张")
            }
        }
        return true
    }

    /// 剪贴板里的图片转 JPEG(0.75)；没有图片返回空数组。
    private static func pasteboardJPEGs(_ pb: NSPasteboard) -> [Data] {
        guard let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !imgs.isEmpty else { return [] }
        return imgs.compactMap { jpeg(from: $0, quality: 0.75) }
    }

    private static func jpeg(from image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: 上传（uguu → tmpfiles，逐字对齐 iOS ImageHostUploader）

    static func upload(jpegData: Data, completion: @escaping (String?) -> Void) {
        uploadUguu(jpegData: jpegData) { url in
            if let url { completion(url); return }
            uploadTmpfiles(jpegData: jpegData, completion: completion)
        }
    }

    private static func uploadUguu(jpegData: Data, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://uguu.se/upload") else { completion(nil); return }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(fieldName: "files[]", filename: "image.jpg", mime: "image/jpeg", data: jpegData, boundary: boundary)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let link = files.first?["url"] as? String else { completion(nil); return }
            completion(link)
        }.resume()
    }

    private static func uploadTmpfiles(jpegData: Data, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://tmpfiles.org/api/v1/upload") else { completion(nil); return }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(fieldName: "file", filename: "image.jpg", mime: "image/jpeg", data: jpegData, boundary: boundary)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inner = json["data"] as? [String: Any],
                  var link = inner["url"] as? String else { completion(nil); return }
            link = link.replacingOccurrences(of: "http://", with: "https://")
            if !link.contains("/dl/") {
                link = link.replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/")
            }
            completion(link)
        }.resume()
    }

    private static func multipartBody(fieldName: String, filename: String, mime: String, data: Data, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
