// NAPI bridge: exposes the Go Tailscale core (libtailscale_ohos.so) to ArkTS.
//
// The Go core is loaded via dlopen(RTLD_GLOBAL) rather than a link-time NEEDED
// dependency. Reason: the Go runtime's cgo TLS symbol (x_cgo_inittls) uses the
// initial-exec TLS model, which the OHOS musl loader cannot satisfy for a
// library pulled in as a dependency of a dlopen'd module. Loading it explicitly
// (and logging dlerror on failure) both makes the napi module itself register
// cleanly and surfaces the exact loader error.
#include "napi/native_api.h"
#include <hilog/log.h>
#include <dlfcn.h>
#include <string>

typedef char *(*fn_start)(int, char *, char *, char *, char *);
typedef char *(*fn_updateTun)(int);
typedef char *(*fn_str)(void);
typedef void (*fn_void)(void);
typedef void (*fn_free)(char *);

static fn_start     p_start = nullptr;
static fn_updateTun p_updateTun = nullptr;
static fn_str       p_loginUrl = nullptr;
static fn_str       p_status = nullptr;
static fn_str       p_version = nullptr;
static fn_void      p_stop = nullptr;
static fn_free      p_free = nullptr;
static bool         g_tried = false;
static bool         g_loaded = false;

static void EnsureCore() {
  if (g_tried) {
    return;
  }
  g_tried = true;
  void *h = dlopen("libtailscale_ohos.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "tsbridge",
                 "dlopen libtailscale_ohos.so FAILED: %{public}s", dlerror());
    return;
  }
  p_start = reinterpret_cast<fn_start>(dlsym(h, "TSStart"));
  p_updateTun = reinterpret_cast<fn_updateTun>(dlsym(h, "TSUpdateTun"));
  p_loginUrl = reinterpret_cast<fn_str>(dlsym(h, "TSLoginURL"));
  p_status = reinterpret_cast<fn_str>(dlsym(h, "TSStatus"));
  p_version = reinterpret_cast<fn_str>(dlsym(h, "TSVersion"));
  p_stop = reinterpret_cast<fn_void>(dlsym(h, "TSStop"));
  p_free = reinterpret_cast<fn_free>(dlsym(h, "TSFree"));
  g_loaded = (p_start && p_version && p_status);
  OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "tsbridge",
               "Go core loaded=%{public}d (start=%{public}p version=%{public}p)",
               g_loaded ? 1 : 0, reinterpret_cast<void *>(p_start),
               reinterpret_cast<void *>(p_version));
}

static std::string ArgToString(napi_env env, napi_value v) {
  size_t len = 0;
  napi_get_value_string_utf8(env, v, nullptr, 0, &len);
  std::string s(len, '\0');
  napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
  return s;
}

// Wrap a malloc'd C string from Go into a napi string, then free it.
static napi_value GoString(napi_env env, char *cs) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, cs ? cs : "", NAPI_AUTO_LENGTH, &out);
  if (cs && p_free) {
    p_free(cs);
  }
  return out;
}

static napi_value Start(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 5;
  napi_value args[5] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!p_start) {
    return GoString(env, nullptr);
  }
  int32_t fd = -1;
  napi_get_value_int32(env, args[0], &fd);
  std::string dir = ArgToString(env, args[1]);
  std::string host = ArgToString(env, args[2]);
  std::string ctrl = ArgToString(env, args[3]);
  std::string key = ArgToString(env, args[4]);
  char *r = p_start(fd, dir.data(), host.data(), ctrl.data(), key.data());
  return GoString(env, r);
}

static napi_value UpdateTun(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t fd = -1;
  napi_get_value_int32(env, args[0], &fd);
  return GoString(env, p_updateTun ? p_updateTun(fd) : nullptr);
}

static napi_value Version(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_version ? p_version() : nullptr);
}

static napi_value LoginUrl(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_loginUrl ? p_loginUrl() : nullptr);
}

static napi_value Status(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_status ? p_status() : nullptr);
}

static napi_value Stop(napi_env env, napi_callback_info info) {
  EnsureCore();
  if (p_stop) {
    p_stop();
  }
  napi_value undef = nullptr;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value Init(napi_env env, napi_value exports) {
  OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "tsbridge", "Init running, defining props");
  napi_property_descriptor desc[] = {
      {"start",     nullptr, Start,     nullptr, nullptr, nullptr, napi_default, nullptr},
      {"updateTun", nullptr, UpdateTun, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"version",   nullptr, Version,   nullptr, nullptr, nullptr, napi_default, nullptr},
      {"loginUrl",  nullptr, LoginUrl,  nullptr, nullptr, nullptr, napi_default, nullptr},
      {"status",    nullptr, Status,    nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop",      nullptr, Stop,      nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

static napi_module tsBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tsbridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTsBridgeModule(void) {
  OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "tsbridge", "constructor: registering module");
  napi_module_register(&tsBridgeModule);
}
