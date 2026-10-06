import XCTest

@testable import Blink

/// 员工头像「内置像素图」这一层的契约测试。老板 2026-10-06 拍板团队头像走像素风
/// （原型 blink/avatar-v2 的 9 位工程师），落地方式是**打包**而不是运行时拉 URL：
/// ①9 张图真的进了 App 包；②尺寸是缩过的 128px（512px 原图单张 250KB+，
/// 进配置快照会肥死每次同步，这条断言就是防它悄悄被换回去）；③优先级是
/// 用户自设 > 内置像素图 > 交给调用方兜底。
final class PixelAvatarTests: XCTestCase {

  private let store = BlinkPeopleStore.shared

  /// 9 位工程师 —— 与 `BlinkPeopleStore.pixelNames` / 原型页点名的人一一对应。
  private let engineers = ["tom", "jack", "adam", "candy", "leo", "max", "quan", "peter", "tony"]

  // 这个测试会往员工头像 store 里写自定义头像来验优先级，跑完必须原样还回去，
  // 否则同一台模拟器上后续用例（或 App 本身）会看到一张多出来的脸。
  private var savedAvatars: Any?
  private var savedStyles: Any?
  private var savedNames: Any?

  override func setUp() {
    super.setUp()
    let d = UserDefaults.standard
    savedAvatars = d.object(forKey: "BlinkPeopleStore.avatars")
    savedStyles = d.object(forKey: "BlinkPeopleStore.styles")
    savedNames = d.object(forKey: "BlinkPeopleStore.names")
  }

  override func tearDown() {
    let d = UserDefaults.standard
    for (key, value) in [("BlinkPeopleStore.avatars", savedAvatars),
                         ("BlinkPeopleStore.styles", savedStyles),
                         ("BlinkPeopleStore.names", savedNames)] {
      if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }
    super.tearDown()
  }

  // MARK: - ① 资源真的打进包了

  func testAllNinePixelImagesAreBundled() {
    XCTAssertEqual(BlinkPeopleStore.pixelNames, engineers, "内置像素图的名单本身变了要一起改这里")
    for name in engineers {
      XCTAssertNotNil(UIImage(named: "\(name)-pixel"), "\(name)-pixel 没进 App 包（Media.xcassets）")
    }
  }

  func testBundledIconResolvesForEveryEngineer() {
    for name in engineers {
      XCTAssertNotNil(store.bundledIcon(for: name), "\(name) 在像素图名单里却取不到图")
    }
  }

  func testBundledIconToleratesCaseAndWhitespace() {
    // 团队页的 employee 来自 tab 的 workDir 名 / 服务端会话名，大小写不保证。
    XCTAssertNotNil(store.bundledIcon(for: "Tom"))
    XCTAssertNotNil(store.bundledIcon(for: "  JACK "))
    XCTAssertNotNil(store.bundledIcon(for: "Peter\n"))
  }

  func testBundledIconIsNilForUnknownName() {
    XCTAssertNil(store.bundledIcon(for: "bella"), "不在那 9 人里就该返 nil，交调用方兜首字母")
    XCTAssertNil(store.bundledIcon(for: ""))
  }

  // MARK: - ② 缩过了（512px 不进包）

  func testBundledImagesAreShrunkTo128Points() {
    // 128 是「看得清 + 单张 ~10KB」的折中。调大等于让每次同步都背着原图走，
    // 调小则团队页 34pt 卡片会糊 —— 要改这个数请连同决议一起改。
    for name in engineers {
      let img = store.bundledIcon(for: name)
      XCTAssertEqual(img?.size.width, 128, "\(name)-pixel 宽度不是 128（原图是 512）")
      XCTAssertEqual(img?.size.height, 128, "\(name)-pixel 高度不是 128（原图是 512）")
    }
  }

  // MARK: - ③ 优先级：用户自设 > 内置像素图

  func testDirectoryIconResolvesBundledPixelName() {
    // 没设过自定义头像时 directoryIcon 要给出内置像素图（设过则是那张，见下一条）。
    for name in engineers {
      XCTAssertNotNil(store.directoryIcon(for: name), "\(name) 应当有脸可显")
    }
  }

  func testCustomIconBeatsBundledPixel() {
    // 显式 scale = 1，免得解码出来的尺寸跟着模拟器屏幕倍率跑（1pt 会变成 2x2/3x3 像素）。
    let fmt = UIGraphicsImageRendererFormat.default()
    fmt.scale = 1
    let red = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: fmt).pngData { ctx in
      UIColor.red.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    store.setIcon(red, for: "tom")
    defer { store.removeName("tom") }

    let shown = store.customIcon(for: "tom")
    XCTAssertNotNil(shown, "自定义头像应当能读回")
    XCTAssertEqual(shown?.size.width, 8, "用户自设的图不能被内置像素图顶掉")
    XCTAssertEqual(store.directoryIcon(for: "tom")?.size.width, 8,
                   "directoryIcon 的优先级：用户自设 > 内置像素图")
  }

  func testDirectoryIconIsNilWhenNeitherIsAvailable() {
    XCTAssertNil(store.directoryIcon(for: "nobody-here"),
                 "两样都没有就返 nil（调用方兜首字母色块），别在这里偷偷走网络")
  }

  // MARK: - ④ 同步快路径不该等网络

  func testIconSyncResolvesBundledPixelWithoutNetwork() {
    // iconSync 是 UI 同步取图的口子：内置像素图必须在缓存/网络之前命中，
    // 否则员工卡片会先空一下再补图（DiceBear 那条路要走网络）。
    XCTAssertNotNil(store.iconSync(for: "candy"), "内置像素图应当命中同步快路径")
    XCTAssertEqual(store.iconSync(for: "candy")?.size.width, 128)
  }
}
