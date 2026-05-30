import UIKit
import WebKit

/// 用 WKWebView + rel="ar" 锚点直接触发 iOS AR Quick Look，
/// 完全跳过 QLPreviewController 的底部 sheet 预览弹层。
///
/// 原理：WKWebView 检测到 rel="ar" 的锚点点击时，
/// iOS 会直接全屏打开 AR Quick Look，而不走普通导航流程。
class ARQuickLookViewController: UIViewController {

    private let filePath: String
    private let flutterResult: FlutterResult
    private var webView: WKWebView!
    /// 是否已经历过第一次 viewDidAppear
    /// 第二次 viewDidAppear = AR Quick Look 关闭后返回 → 自动关闭本 VC
    private var firstAppearanceDone = false

    init(filePath: String, result: @escaping FlutterResult) {
        self.filePath = filePath
        self.flutterResult = result
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // ── WKWebView ──────────────────────────────────────────────────────
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        view.addSubview(webView)

        // ── 构造 HTML ──────────────────────────────────────────────────────
        // baseURL 设为 USDZ 所在目录，href 用相对文件名，
        // 让 WKWebView 有权访问本地文件
        let fileURL  = URL(fileURLWithPath: filePath)
        let dir      = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        </head>
        <body style="margin:0;padding:0;background:#000;width:100vw;height:100vh;">
          <!-- rel="ar" 让 WKWebView 直接拉起 iOS AR Quick Look，跳过 QLPreviewController sheet -->
          <a id="ar-link" rel="ar" href="\(filename)">
            <canvas style="display:block;width:1px;height:1px;"></canvas>
          </a>
          <script>
            window.addEventListener('load', function () {
              // 延迟 300ms 确保 WebView 完全就绪
              setTimeout(function () {
                document.getElementById('ar-link').click();
              }, 300);
            });
          </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: dir)

        // ── 关闭按钮（AR Quick Look 无法打开时的兜底）──────────────────────
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(
            UIImage(systemName: "xmark.circle.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)),
            for: .normal
        )
        closeBtn.tintColor = UIColor.white.withAlphaComponent(0.8)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeBtn)

        let safeTop = view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: safeTop, constant: 8),
            closeBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            closeBtn.widthAnchor.constraint(equalToConstant: 44),
            closeBtn.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// AR Quick Look 关闭后，iOS 会再次触发本 VC 的 viewDidAppear。
    /// 利用 firstAppearanceDone 区分"首次出现"和"AR 关闭后返回"。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if firstAppearanceDone {
            // 第二次出现 = AR Quick Look 已关闭 → 关闭本 VC
            flutterResult(["msg": "success"] as [String: Any])
            dismiss(animated: true)
        }
        firstAppearanceDone = true
    }

    @objc private func closeTapped() {
        flutterResult(["msg": "cancelled"] as [String: Any])
        dismiss(animated: true)
    }
}
