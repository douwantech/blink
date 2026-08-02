// windowat —— 远端窗口命中测试助手(被控 Mac 上运行)。
//
// 用途:RustDesk 客户端点了屏幕某点,想缩放到那个窗口。RustDesk 协议不带窗口信息,
// 所以由远端跑这个助手:给定像素坐标,用 CGWindowList 找出该点最上层的普通窗口,
// 返回它的边界(像素)。客户端拿到 rect 再缩放。
//
// 用法:  windowat <x_px> <y_px>
// 输出:  命中 → {"x":..,"y":..,"w":..,"h":..,"owner":"..","title":".."}(像素,全局左上原点)
//        未命中 → {}
//
// 权限:CGWindowList 的 bounds/owner 不需要额外权限;窗口标题(title)需要屏幕录制权限,
//      RustDesk 被控端本来就有,拿不到时 title 留空、不影响 rect。

import Foundation
import CoreGraphics
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let px = Double(args[1]), let py = Double(args[2]) else {
  FileHandle.standardError.write(Data("usage: windowat <x_px> <y_px>\n".utf8))
  exit(2)
}

// RustDesk 传的是像素;CGWindowBounds 是点(point)。按主屏 backingScale 换算。
// 单显示器 + 主屏假设:多屏原点偏移暂不处理。
let scale = NSScreen.main?.backingScaleFactor ?? 2.0
let ptX = px / scale
let ptY = py / scale

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
  print("{}")
  exit(0)
}

// 列表按前后顺序(前面的在更上层)。取第一个 layer==0(普通应用窗口)且包含该点的。
for w in list {
  guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
  guard let b = w[kCGWindowBounds as String] as? [String: Any],
        let x = b["X"] as? Double, let y = b["Y"] as? Double,
        let ww = b["Width"] as? Double, let hh = b["Height"] as? Double,
        ww > 1, hh > 1 else { continue }
  if ptX >= x, ptX <= x + ww, ptY >= y, ptY <= y + hh {
    let out: [String: Any] = [
      "x": (x * scale).rounded(),
      "y": (y * scale).rounded(),
      "w": (ww * scale).rounded(),
      "h": (hh * scale).rounded(),
      "owner": w[kCGWindowOwnerName as String] as? String ?? "",
      "title": w[kCGWindowName as String] as? String ?? "",
    ]
    if let d = try? JSONSerialization.data(withJSONObject: out) {
      print(String(decoding: d, as: UTF8.self))
    }
    exit(0)
  }
}

print("{}")
