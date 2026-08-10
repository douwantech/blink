// 没有 liblibrustdesk.a 的机器也能编译运行：
// - 有库的机器在 developer_setup.xcconfig 里定义 BLINK_RUSTDESK_* 四个变量
//   （SWIFT_FLAG 注入 BLINK_HAS_RUSTDESK 编译条件，C_FLAG 让 bridging header 引入真声明）
// - 没库的机器四个变量留空 → bridging header 跳过 rustdesk_native.h，这里的 no-op stub
//   顶上所有 rd_* 符号，链接不再需要 liblibrustdesk.a / vcpkg 的 aom/vpx/yuv/opus
// - 运行时用 RustDeskCore.isAvailable 判断，远程桌面入口弹提示不再进页面
#if !BLINK_HAS_RUSTDESK

import Foundation

typealias rd_event_cb = @convention(c) (Int64, Int32, UnsafePointer<CChar>?, Int64, Int64) -> Void

func rd_register_event_cb(_ cb: rd_event_cb?) {}
func rd_init(_ deviceId: UnsafePointer<CChar>?, _ deviceName: UnsafePointer<CChar>?,
             _ homeDir: UnsafePointer<CChar>?, _ appDir: UnsafePointer<CChar>?) {}
func rd_start_global_event_stream(_ port: Int64, _ appType: UnsafePointer<CChar>?) -> Bool { false }
func rd_stop_global_event_stream(_ appType: UnsafePointer<CChar>?) {}

func rd_main_set_option(_ key: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {}
func rd_main_get_option(_ key: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? { nil }
func rd_free_cstring(_ p: UnsafeMutablePointer<CChar>?) {}

func rd_session_add(_ sessionUUID: UnsafePointer<CChar>?, _ id: UnsafePointer<CChar>?,
                    _ forceRelay: Bool, _ password: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? { nil }
func rd_session_start(_ port: Int64, _ sessionUUID: UnsafePointer<CChar>?, _ id: UnsafePointer<CChar>?) -> Bool { false }
func rd_session_login(_ sessionUUID: UnsafePointer<CChar>?, _ osUsername: UnsafePointer<CChar>?,
                      _ osPassword: UnsafePointer<CChar>?, _ password: UnsafePointer<CChar>?, _ remember: Bool) {}
func rd_session_close(_ sessionUUID: UnsafePointer<CChar>?) {}
func rd_session_reconnect(_ sessionUUID: UnsafePointer<CChar>?, _ forceRelay: Bool) {}
func rd_session_refresh_video(_ sessionUUID: UnsafePointer<CChar>?, _ display: Int) {}

func rd_session_get_rgba_size(_ sessionUUID: UnsafePointer<CChar>?, _ display: Int) -> Int { 0 }
func session_get_rgba(_ sessionUUID: UnsafePointer<CChar>?, _ display: Int) -> UnsafePointer<UInt8>? { nil }
func rd_session_next_rgba(_ sessionUUID: UnsafePointer<CChar>?, _ display: Int) {}

func rd_session_send_mouse(_ sessionUUID: UnsafePointer<CChar>?, _ msgJson: UnsafePointer<CChar>?) {}
func rd_session_send_pointer(_ sessionUUID: UnsafePointer<CChar>?, _ msgJson: UnsafePointer<CChar>?) {}
func rd_session_input_key(_ sessionUUID: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?,
                          _ down: Bool, _ press: Bool, _ alt: Bool, _ ctrl: Bool, _ shift: Bool, _ command: Bool) {}
func rd_session_input_string(_ sessionUUID: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {}
func rd_session_set_view_style(_ sessionUUID: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {}
func rd_session_toggle_option(_ sessionUUID: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {}

#endif
