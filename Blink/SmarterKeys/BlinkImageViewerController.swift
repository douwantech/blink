import UIKit

@objc(BlinkImageURLRouter) final class BlinkImageURLRouter: NSObject {
  @objc static func tryPresentImage(for url: URL) -> Bool {
    guard isImageURL(url) else { return false }
    guard let presenter = topViewController() else { return false }
    BlinkImageViewerController.present(url: url, from: presenter)
    return true
  }

  private static func isImageURL(_ url: URL) -> Bool {
    let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"]
    return exts.contains(url.pathExtension.lowercased())
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let window = scenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

@objc final class BlinkImageViewerController: UIViewController, UIScrollViewDelegate {
  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let activity = UIActivityIndicatorView(style: .large)
  private let messageLabel = UILabel()
  private var sourceURL: URL?

  @objc static func present(url: URL, from presenter: UIViewController) {
    let vc = BlinkImageViewerController()
    vc.sourceURL = url
    vc.modalPresentationStyle = .fullScreen
    presenter.present(vc, animated: true)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    scrollView.delegate = self
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 4
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)

    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(imageView)

    activity.color = .white
    activity.translatesAutoresizingMaskIntoConstraints = false
    activity.startAnimating()
    view.addSubview(activity)

    messageLabel.font = .systemFont(ofSize: 14)
    messageLabel.textColor = .systemGray
    messageLabel.numberOfLines = 0
    messageLabel.textAlignment = .center
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messageLabel)

    let close = UIButton(type: .system)
    close.setImage(
      UIImage(systemName: "xmark.circle.fill",
              withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)),
      for: .normal
    )
    close.tintColor = .white
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    view.addSubview(close)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

      activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      activity.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      messageLabel.topAnchor.constraint(equalTo: activity.bottomAnchor, constant: 16),
      messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      close.widthAnchor.constraint(equalToConstant: 40),
      close.heightAnchor.constraint(equalToConstant: 40),
    ])

    loadImage()
  }

  private func loadImage() {
    guard let url = sourceURL else {
      finishWithError("URL 为空")
      return
    }
    messageLabel.text = "正在加载…"
    URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.activity.stopAnimating()
        if let error {
          self.finishWithError("加载失败: \(error.localizedDescription)")
          return
        }
        guard let data, !data.isEmpty else {
          self.finishWithError("响应为空")
          return
        }
        guard let img = UIImage(data: data) else {
          self.finishWithError("不是图片或格式不支持")
          return
        }
        self.messageLabel.text = nil
        self.imageView.image = img
      }
    }.resume()
  }

  private func finishWithError(_ msg: String) {
    messageLabel.text = msg
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  @objc private func closeTapped() { dismiss(animated: true) }
}
