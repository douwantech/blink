// RustDesk 核心库(liblibrustdesk.a)的原生 C FFI 声明。
// 实现在 rustdesk-src/src/native_ffi.rs(rd_* 前缀)+ src/flutter.rs(session_get_rgba)。
// 事件回调 kind:0=JSON 事件 1=RGBA 帧就绪(n1=display) 2=Texture(忽略) 3=流关闭 4=错误("code|message")。
// 回调里的 s 指针仅在回调期间有效,必须同步拷贝;回调发生在 Rust 线程,不在主线程。

#ifndef rustdesk_native_h
#define rustdesk_native_h

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef void (*rd_event_cb)(int64_t port, int32_t kind, const char *s, int64_t n1, int64_t n2);

void rd_register_event_cb(rd_event_cb cb);
void rd_init(const char *device_id, const char *device_name, const char *home_dir, const char *app_dir);
bool rd_start_global_event_stream(int64_t port, const char *app_type);
void rd_stop_global_event_stream(const char *app_type);

void rd_main_set_option(const char *key, const char *value);
char *rd_main_get_option(const char *key);
void rd_free_cstring(char *p);

// 返回错误串(空串=成功),用 rd_free_cstring 释放
char *rd_session_add(const char *session_uuid, const char *id, bool force_relay, const char *password);
bool rd_session_start(int64_t port, const char *session_uuid, const char *id);
void rd_session_login(const char *session_uuid, const char *os_username, const char *os_password,
                      const char *password, bool remember);
void rd_session_close(const char *session_uuid);
void rd_session_reconnect(const char *session_uuid, bool force_relay);
void rd_session_refresh_video(const char *session_uuid, size_t display);

// 视频帧:Rgba 事件后取帧,消费完必须调 next 让 Rust 放行下一帧
size_t rd_session_get_rgba_size(const char *session_uuid, size_t display);
const uint8_t *session_get_rgba(const char *session_uuid, size_t display);
void rd_session_next_rgba(const char *session_uuid, size_t display);

// 输入(阶段 2)
void rd_session_send_mouse(const char *session_uuid, const char *msg_json);
void rd_session_send_pointer(const char *session_uuid, const char *msg_json);
void rd_session_input_key(const char *session_uuid, const char *name, bool down, bool press,
                          bool alt, bool ctrl, bool shift, bool command);
void rd_session_input_string(const char *session_uuid, const char *value);
void rd_session_set_view_style(const char *session_uuid, const char *value);
void rd_session_toggle_option(const char *session_uuid, const char *value);

#endif /* rustdesk_native_h */
