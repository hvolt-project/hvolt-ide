// 模型写的 JS 在这台设备上执行：每次调用新建 runtime/context，跑完即销毁。
//
// quickjs 静态链进 libnavi.so：宿主包加载时不会因为额外的共享库依赖把整个 native 模块拖死
// （实测 NEEDED libquickjs.so 会让页面模块整体无法求值），调用也由编译器检查类型。
// 用户代码包进 try/catch 的 eval 求值，语法与运行错误变成返回值，不走异常态。

#include "js_eval.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>

extern "C" {
#include "quickjs.h"
}

namespace {

int64_t NowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// 中断回调只拿到 runtime 与 opaque，deadline 放全局；执行串行，单槽够用。
// 只触发一次：持续返回 1 会让 catch 里的代码立刻被再次中断，异常就传不出来。
int64_t g_deadlineMs = 0;

int InterruptHandler(JSRuntime *rt, void *opaque)
{
    (void)rt;
    (void)opaque;
    if (g_deadlineMs != 0 && NowMs() > g_deadlineMs) {
        g_deadlineMs = 0;
        return 1;
    }
    return 0;
}

std::string JsonEscape(const char *in)
{
    std::string out;
    if (in == nullptr) {
        return out;
    }
    for (const char *p = in; *p != '\0'; p++) {
        const unsigned char c = static_cast<unsigned char>(*p);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::string ReadString(napi_env env, napi_value value)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, value, &out[0], len + 1, &len);
    return out;
}

napi_value MakeString(napi_env env, const std::string &text)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

/** 把用户源码包成 try/catch 表达式：语法与运行错误都变成返回值。 */
std::string WrapSource(const std::string &source)
{
    std::string lit = "\"";
    for (const char *p = source.c_str(); *p != '\0'; p++) {
        const unsigned char c = static_cast<unsigned char>(*p);
        switch (c) {
            case '"': lit += "\\\""; break;
            case '\\': lit += "\\\\"; break;
            case '\n': lit += "\\n"; break;
            case '\r': lit += "\\r"; break;
            case '\t': lit += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    lit += buf;
                } else {
                    lit += static_cast<char>(c);
                }
        }
    }
    lit += "\"";
    return std::string("(function(){try{var r=(0,eval)(") + lit +
           ");return \"ok:\"+JSON.stringify(r===undefined?null:r);}" +
           "catch(e){return \"err:\"+String(e&&e.message?e.message:e);}})()";
}

}  // namespace

// jsEval(source, timeoutMs, memLimitMb) -> JSON 文本 {ok, value|error, ms}
napi_value JsEval(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    const std::string source = argc > 0 ? ReadString(env, argv[0]) : std::string();
    int timeoutMs = 5000;
    int memLimitMb = 64;
    if (argc > 1) {
        napi_get_value_int32(env, argv[1], &timeoutMs);
    }
    if (argc > 2) {
        napi_get_value_int32(env, argv[2], &memLimitMb);
    }
    if (timeoutMs <= 0 || timeoutMs > 600000) {
        timeoutMs = 600000;
    }
    if (memLimitMb <= 0) {
        memLimitMb = 64;
    }

    const int64_t startedAt = NowMs();
    g_deadlineMs = startedAt + timeoutMs;

    JSRuntime *rt = JS_NewRuntime();
    if (rt == nullptr) {
        return MakeString(env, std::string("{\"ok\":false,\"error\":\"runtime alloc failed\"}"));
    }
    JS_SetMemoryLimit(rt, static_cast<size_t>(memLimitMb) * 1024 * 1024);
    JS_SetInterruptHandler(rt, InterruptHandler, nullptr);

    JSContext *ctx = JS_NewContext(rt);
    if (ctx == nullptr) {
        JS_FreeRuntime(rt);
        return MakeString(env, std::string("{\"ok\":false,\"error\":\"context alloc failed\"}"));
    }

    const std::string wrapped = WrapSource(source);
    JSValue result = JS_Eval(ctx, wrapped.c_str(), wrapped.size(), "<js_eval>", JS_EVAL_TYPE_GLOBAL);
    const int64_t elapsed = NowMs() - startedAt;

    std::string out;
    if (JS_IsException(result)) {
        JSValue exc = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, exc);
        out = "{\"ok\":false,\"error\":\"" + JsonEscape(text) + "\",\"ms\":" +
              std::to_string(elapsed) + "}";
        if (text != nullptr) {
            JS_FreeCString(ctx, text);
        }
        JS_FreeValue(ctx, exc);
    } else {
        const char *text = JS_ToCString(ctx, result);
        const std::string body(text == nullptr ? "" : text);
        if (text != nullptr) {
            JS_FreeCString(ctx, text);
        }
        if (body.rfind("err:", 0) == 0) {
            out = "{\"ok\":false,\"error\":\"" + JsonEscape(body.substr(4).c_str()) + "\",\"ms\":" +
                  std::to_string(elapsed) + "}";
        } else {
            const std::string value = body.rfind("ok:", 0) == 0 ? body.substr(3) : body;
            out = "{\"ok\":true,\"value\":\"" + JsonEscape(value.c_str()) + "\",\"ms\":" +
                  std::to_string(elapsed) + "}";
        }
    }
    JS_FreeValue(ctx, result);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    g_deadlineMs = 0;
    return MakeString(env, out);
}
