// 模型写的 JS 在这台设备上执行：每次调用新建 runtime/context，跑完即销毁。
//
// quickjs 静态链进 libnavi.so：宿主包加载时不会因为额外的共享库依赖把整个 native 模块拖死
// （实测 NEEDED libquickjs.so 会让页面模块整体无法求值），调用也由编译器检查类型。
// 用户代码包进 try/catch 的 eval 求值，语法与运行错误变成返回值，不走异常态。

#include "js_eval.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <map>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

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
std::atomic<int64_t> g_deadlineMs{0};

int InterruptHandler(JSRuntime *rt, void *opaque)
{
    (void)rt;
    (void)opaque;
    if (g_deadlineMs.load() != 0 && NowMs() > g_deadlineMs.load()) {
        g_deadlineMs.store(0);
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
// 把返回值编成信封 {ok,t,j}，类型如实标注。
//
// 早先只有「JSON.stringify 成功 / 失败」两条路，失败就贴 circular——于是 BigInt 被误标成
// 循环引用、Map 静默变 {}、Infinity 静默变 null（设备上的模型逐条测出了这些）。这里按类型
// 分别处理：能如实表达的如实表达，表达不了的明确标出来，不再塞兜底标签。
static const char *kEncodeHelper =
    "function __norm(v,d,seen){"
    "if(v===null){return null;}"
    "var t=typeof v;"
    "if(t==='undefined'){return {__t:'undefined'};}"
    // 字符串与布尔必须在这里短路：漏掉它们会一路走到最后的 for-in，字符串被按索引遍历成
    // {0:'a',1:'b'} 这种数字键对象（设备上的模型发现并实测出了这一条）。
    "if(t==='string'||t==='boolean'){return v;}"
    "if(t==='bigint'){return {__t:'bigint',v:v.toString()};}"
    "if(t==='function'||t==='symbol'){return {__t:t,v:String(v)};}"
    "if(t==='number'){if(v!==v){return {__t:'number',v:'NaN'};}"
    "if(v===Infinity||v===-Infinity){return {__t:'number',v:String(v)};}return v;}"
    // 深度限制下沉到容器分支之前，超限时给可读的标记而不是裸字符串。
    "if(d>8){return {__t:'truncated',v:String(v)};}"
    "if(v instanceof Date){return {__t:'date',v:v.toISOString()};}"
    "if(v instanceof RegExp){return {__t:'regexp',v:String(v)};}"
    // 真环检测：同一对象出现在当前路径上才算环，共享引用不是。
    "if(seen.indexOf(v)>=0){return {__t:'circular-ref'};}"
    "seen.push(v);"
    "var out;"
    "if(v instanceof Map){out={__t:'map',v:Array.from(v.entries()).map(function(e){"
    "return [__norm(e[0],d+1,seen),__norm(e[1],d+1,seen)];})};}"
    "else if(v instanceof Set){out={__t:'set',v:Array.from(v.values()).map(function(x){"
    "return __norm(x,d+1,seen);})};}"
    "else if(ArrayBuffer.isView(v)){out={__t:(v.constructor&&v.constructor.name)||'typedarray',"
    "v:Array.from(v)};}"
    "else if(Array.isArray(v)){out=v.map(function(x){return __norm(x,d+1,seen);});}"
    // 用户对象里的 __t 键改名为 $__t：否则 {__t:'map',v:[...]} 这种普通数据与真 Map 无法区分
    // （设备上的模型指出过这一点）。
    "else{out={};for(var k in v){if(Object.prototype.hasOwnProperty.call(v,k)){"
    "var key=(k==='__t')?'$__t':k;"
    "out[key]=__norm(v[k],d+1,seen);}}}"
    "seen.pop();"
    "return out;}"
    "function __enc(v){var t=typeof v;var body;"
    "try{body=JSON.stringify(__norm(v,0,[]));}catch(e){"
    "return {ok:false,error:'unserializable: '+String(e&&e.message?e.message:e)};}"
    "if(body===undefined){return {ok:true,t:t};}"
    "return {ok:true,t:t,j:body};};";

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
    // 返回带类型标记的信封，而不是 "ok:"+JSON 文本：
    //   · 原先的写法让调用方拿到的是「JSON 塞进 JSON」，类型信息全在字符串里，undefined 被
    //     JSON.stringify 抹成 null，两者无法区分（设备上的模型实测记录了这一条）；
    //   · 循环引用会让 JSON.stringify 抛错，整次调用退化成异常——这里降级成字符串，标 circular。
    return std::string(kEncodeHelper) + "(function(){try{var r=(0,eval)(" + lit +
           ");return __enc(r);}" +
           "catch(e){return {ok:false,error:String(e&&e.message?e.message:e)};}})()";
}

/**
 * 脚本里出现 await / tool( 时走 async 函数体：eval 的代码不能 await 外层，只能把用户代码
 * 直接放进 async 函数里。代价是这种模式下要自己写 return——最后表达式的值拿不到。
 * 不含这两样的脚本仍走原来的 eval 包装，保持「最后表达式的值就是结果」。
 */
std::string WrapSourceAsync(const std::string &source)
{
    return std::string(kEncodeHelper) + "(async function(){try{" + source +
        "\n}catch(e){return {ok:false,error:String(e&&e.message?e.message:e)};}})()";
}

/** 去掉行注释与块注释：注释里出现 tool( 不该改变执行路径（设备上的模型提过这条）。 */
std::string WithoutComments(const std::string &source)
{
    std::string out;
    out.reserve(source.size());
    size_t i = 0;
    while (i < source.size()) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            while (i < source.size() && source[i] != '\n') {
                i++;
            }
            continue;
        }
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/')) {
                i++;
            }
            i = i + 2 < source.size() ? i + 2 : source.size();
            continue;
        }
        out.push_back(source[i]);
        i++;
    }
    return out;
}

bool NeedsAsync(const std::string &source)
{
    const std::string code = WithoutComments(source);
    return code.find("await") != std::string::npos ||
        code.find("tool(") != std::string::npos ||
        code.find("__callTool(") != std::string::npos;
}


// --- 异步桥：脚本里 await tool(name, argsJson) ------------------------------------------------
//
// 为什么要分阶段重入，而不是在 native 里挂 napi 回调：工具 handler 在 ArkTS 侧是 Promise，
// 而这里每次 napi 调用都是同步的。于是把执行切成几步——脚本挂起时把「要调哪些工具」交回
// ArkTS，ArkTS 跑完再把结果灌回来继续。QuickJS 的 job queue 与 runtime 在两次调用之间留着，
// 脚本侧的 await 因此是真正的挂起/恢复。
//
// 会话有上限且带超时：ArkTS 侧若不 resume（异常路径），会话不会无限堆积。

constexpr int MAX_SESSIONS = 4;

struct PendingCall {
    int id = 0;
    std::string name;
    std::string args;
};

struct CallSession {
    JSRuntime *rt = nullptr;
    JSContext *ctx = nullptr;
    JSValue promise = JS_UNDEFINED;
    std::vector<PendingCall> need;
    std::map<int, JSValue> resolvers;  // call id -> resolve 函数
    int nextId = 1;
    int64_t deadlineMs = 0;
};

std::map<int, CallSession *> g_sessions;
// The table is reached from the NAPI entry points as well as from the JS thread, so
// every lookup and insert takes this lock.
std::mutex g_sessionsLock;
int g_nextSessionId = 1;
CallSession *g_active = nullptr;

JSValue ToolCallHost(JSContext *ctx, JSValueConst thisVal, int argc, JSValueConst *argv)
{
    (void)thisVal;
    if (g_active == nullptr) {
        return JS_ThrowInternalError(ctx, "tool() called outside a js_eval session");
    }
    const char *name = argc > 0 ? JS_ToCString(ctx, argv[0]) : nullptr;
    const char *args = argc > 1 ? JS_ToCString(ctx, argv[1]) : nullptr;
    JSValue funcs[2] = {JS_UNDEFINED, JS_UNDEFINED};
    JSValue promise = JS_NewPromiseCapability(ctx, funcs);
    PendingCall call;
    call.id = g_active->nextId++;
    call.name = name == nullptr ? "" : name;
    call.args = args == nullptr ? "" : args;
    g_active->resolvers[call.id] = JS_DupValue(ctx, funcs[0]);
    JS_FreeValue(ctx, funcs[0]);
    JS_FreeValue(ctx, funcs[1]);
    g_active->need.push_back(call);
    if (name != nullptr) {
        JS_FreeCString(ctx, name);
    }
    if (args != nullptr) {
        JS_FreeCString(ctx, args);
    }
    return promise;
}

/** 跑完所有 pending job。返回 false 表示 job 里抛了未捕获异常。 */
bool DrainJobs(CallSession *session)
{
    JSContext *ctx = nullptr;
    for (;;) {
        int rc = JS_ExecutePendingJob(session->rt, &ctx);
        if (rc == 0) {
            return true;
        }
        if (rc < 0) {
            return false;
        }
    }
}

/** 把信封 {ok,t,j} 或 {ok:false,error} 转成对外的 JSON 文本。 */
std::string DescribeResult(JSContext *ctx, JSValue value, int64_t elapsedMs)
{
    JSValue okValue = JS_GetPropertyStr(ctx, value, "ok");
    const bool ok = JS_ToBool(ctx, okValue) == 1;
    JS_FreeValue(ctx, okValue);
    if (!ok) {
        JSValue errValue = JS_GetPropertyStr(ctx, value, "error");
        const char *errText = JS_ToCString(ctx, errValue);
        std::string out = "{\"ok\":false,\"error\":\"" + JsonEscape(errText) + "\",\"ms\":" +
            std::to_string(elapsedMs) + "}";
        if (errText != nullptr) {
            JS_FreeCString(ctx, errText);
        }
        JS_FreeValue(ctx, errValue);
        return out;
    }
    JSValue typeValue = JS_GetPropertyStr(ctx, value, "t");
    const char *typeText = JS_ToCString(ctx, typeValue);
    JSValue payload = JS_GetPropertyStr(ctx, value, "j");
    const char *payloadText = JS_ToCString(ctx, payload);
    std::string out = "{\"ok\":true,\"type\":\"" + JsonEscape(typeText) + "\"";
    if (payloadText != nullptr) {
        out += ",\"value\":";
        out += payloadText;
    }
    out += ",\"ms\":" + std::to_string(elapsedMs) + "}";
    if (typeText != nullptr) {
        JS_FreeCString(ctx, typeText);
    }
    if (payloadText != nullptr) {
        JS_FreeCString(ctx, payloadText);
    }
    JS_FreeValue(ctx, typeValue);
    JS_FreeValue(ctx, payload);
    return out;
}

void DisposeSession(int id)
{
    CallSession *session = nullptr;
    {
        std::lock_guard<std::mutex> guard(g_sessionsLock);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end()) {
            return;
        }
        session = it->second;
        g_sessions.erase(it);
    }
    // Everything below frees JS values, which must not happen under the table lock.
    if (g_active == session) {
        g_active = nullptr;
    }
    for (auto &entry : session->resolvers) {
        JS_FreeValue(session->ctx, entry.second);
    }
    if (!JS_IsUndefined(session->promise)) {
        JS_FreeValue(session->ctx, session->promise);
    }
    JS_FreeContext(session->ctx);
    JS_FreeRuntime(session->rt);
    delete session;
}

/** 推进会话：跑 job、看 promise 状态，产出对 ArkTS 的应答 JSON。 */
std::string AdvanceSession(int id, CallSession *session, int64_t startedAt)
{
    g_active = session;
    g_deadlineMs.store(session->deadlineMs);
    const bool drained = DrainJobs(session);
    g_active = nullptr;
    g_deadlineMs.store(0);
    const int64_t elapsed = NowMs() - startedAt;
    if (!drained) {
        DisposeSession(id);
        return "{\"status\":\"error\",\"message\":\"job threw\"}";
    }
    const JSPromiseStateEnum state = JS_PromiseState(session->ctx, session->promise);
    if (state == JS_PROMISE_FULFILLED) {
        JSValue value = JS_PromiseResult(session->ctx, session->promise);
        std::string result = DescribeResult(session->ctx, value, elapsed);
        JS_FreeValue(session->ctx, value);
        DisposeSession(id);
        return std::string("{\"status\":\"done\",\"result\":") + result + "}";
    }
    if (state == JS_PROMISE_REJECTED) {
        JSValue value = JS_PromiseResult(session->ctx, session->promise);
        const char *text = JS_ToCString(session->ctx, value);
        std::string message = text == nullptr ? "rejected" : text;
        if (text != nullptr) {
            JS_FreeCString(session->ctx, text);
        }
        JS_FreeValue(session->ctx, value);
        DisposeSession(id);
        return std::string("{\"status\":\"error\",\"message\":\"") + JsonEscape(message.c_str()) + "\"}";
    }
    if (session->need.empty()) {
        // 脚本停在一个永远不会 settle 的等待上：没有待办调用，也没有结果。
        DisposeSession(id);
        return "{\"status\":\"error\",\"message\":\"script suspended with nothing pending\"}";
    }
    std::string calls;
    for (size_t i = 0; i < session->need.size(); i++) {
        const PendingCall &call = session->need[i];
        if (i > 0) {
            calls += ",";
        }
        calls += "{\"id\":" + std::to_string(call.id) + ",\"name\":\"" + JsonEscape(call.name.c_str()) +
            "\",\"args\":" + (call.args.empty() ? std::string("{}") : call.args) + "}";
    }
    session->need.clear();
    return "{\"status\":\"need\",\"session\":" + std::to_string(id) + ",\"calls\":[" + calls +
        "],\"ms\":" + std::to_string(elapsed) + "}";
}

/** 起一个会话并跑到第一次挂起（或结束）。 */
std::string StartSession(const std::string &source, int timeoutMs, int memLimitMb, int64_t startedAt)
{
    {
        std::lock_guard<std::mutex> guard(g_sessionsLock);
        if (static_cast<int>(g_sessions.size()) >= MAX_SESSIONS) {
            return "{\"status\":\"error\",\"message\":\"too many concurrent js_eval sessions\"}";
        }
    }
    JSRuntime *rt = JS_NewRuntime();
    if (rt == nullptr) {
        return "{\"status\":\"error\",\"message\":\"runtime alloc failed\"}";
    }
    JS_SetMemoryLimit(rt, static_cast<size_t>(memLimitMb) * 1024 * 1024);
    JS_SetInterruptHandler(rt, InterruptHandler, nullptr);
    JSContext *ctx = JS_NewContext(rt);
    if (ctx == nullptr) {
        JS_FreeRuntime(rt);
        return "{\"status\":\"error\",\"message\":\"context alloc failed\"}";
    }
    CallSession *session = new CallSession();
    session->rt = rt;
    session->ctx = ctx;
    session->deadlineMs = startedAt + timeoutMs;
    JSValue global = JS_GetGlobalObject(ctx);
    // 脚本里写的是 tool(...)；__callTool 是内部名，两个都挂上。只注册后者时，模型照文档
    // 写 tool() 会直接 undefined is not a function（设备上的模型指出了这一点）。
    JSValue toolFn = JS_NewCFunction(ctx, ToolCallHost, "tool", 2);
    JS_SetPropertyStr(ctx, global, "tool", JS_DupValue(ctx, toolFn));
    JS_SetPropertyStr(ctx, global, "__callTool", toolFn);
    JS_FreeValue(ctx, global);
    const int id = g_nextSessionId++;
    {
        std::lock_guard<std::mutex> guard(g_sessionsLock);
        g_sessions[id] = session;
    }
    // 脚本包成 async 函数：内部的 await 才能把执行权交回 job queue。
    // 统一成 promise：同步脚本包一层 Promise.resolve，异步脚本用 async 函数体。
    const std::string wrapped = NeedsAsync(source) ? WrapSourceAsync(source)
        : "Promise.resolve(" + WrapSource(source) + ")";
    // 求值本身也要受中断保护：带 await 的脚本可能先跑一段同步死循环再等到挂起点，而
    // g_deadlineMs 只在 AdvanceSession 里设过——那条路径上的死循环会一直占着主线程。
    // g_active 也要设：脚本第一次执行到 tool() 就在这里，缺了它 ToolCallHost 直接判空抛错。
    g_active = session;
    g_deadlineMs.store(session->deadlineMs);
    JSValue result = JS_Eval(ctx, wrapped.c_str(), wrapped.size(), "<js_eval>", JS_EVAL_TYPE_GLOBAL);
    g_active = nullptr;
    g_deadlineMs.store(0);
    if (JS_IsException(result)) {
        JSValue exc = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, exc);
        std::string message = text == nullptr ? "eval failed" : text;
        if (text != nullptr) {
            JS_FreeCString(ctx, text);
        }
        JS_FreeValue(ctx, exc);
        JS_FreeValue(ctx, result);
        DisposeSession(id);
        return std::string("{\"status\":\"error\",\"message\":\"") + JsonEscape(message.c_str()) + "\"}";
    }
    session->promise = JS_DupValue(ctx, result);
    JS_FreeValue(ctx, result);
    return AdvanceSession(id, session, startedAt);
}

/** 把一次工具调用的结果灌回对应的 promise。resultsJson 形如 [{"id":1,"result":"文本"}]。 */
std::string ResumeSession(int id, const std::string &resultsJson)
{
    CallSession *session = nullptr;
    {
        std::lock_guard<std::mutex> guard(g_sessionsLock);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end()) {
            return "{\"status\":\"error\",\"message\":\"no such session\"}";
        }
        session = it->second;
    }
    g_active = session;
    g_deadlineMs.store(session->deadlineMs);
    // 结果文本本身是 JSON；用 JS 侧解析，省得在 C 里再写一个解析器。
    const std::string parse = std::string("(function(){var a=(") + resultsJson +
        ");var o={};for(var i=0;i<a.length;i++){o[a[i].id]=String(a[i].result);}return o;})()";
    JSValue mapValue = JS_Eval(session->ctx, parse.c_str(), parse.size(), "<resume>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(mapValue)) {
        JSValue exc = JS_GetException(session->ctx);
        JS_FreeValue(session->ctx, exc);
        g_active = nullptr;
        g_deadlineMs.store(0);
        DisposeSession(id);
        return "{\"status\":\"error\",\"message\":\"bad results payload\"}";
    }
    for (auto &entry : session->resolvers) {
        JSValue text = JS_GetPropertyStr(session->ctx, mapValue, std::to_string(entry.first).c_str());
        JSValue global = JS_GetGlobalObject(session->ctx);
        JSValue resolve = entry.second;
        JSValue callResult = JS_Call(session->ctx, resolve, JS_UNDEFINED, 1, &text);
        JS_FreeValue(session->ctx, callResult);
        JS_FreeValue(session->ctx, text);
        JS_FreeValue(session->ctx, global);
        JS_FreeValue(session->ctx, resolve);
    }
    session->resolvers.clear();
    JS_FreeValue(session->ctx, mapValue);
    g_active = nullptr;
    g_deadlineMs.store(0);
    const int64_t startedAt = NowMs();
    return AdvanceSession(id, session, startedAt);
}

std::string BeginEntryImpl(const std::string &source, int timeoutMs, int memLimitMb)
{
    return StartSession(source, timeoutMs, memLimitMb, NowMs());
}

std::string ResumeEntryImpl(int session, const std::string &results)
{
    return ResumeSession(session, results);
}

void AbortSessionImpl(int session)
{
    DisposeSession(session);
}

}  // namespace

// 异步桥的三个出口：begin 起会话并跑到第一次挂起，resume 灌结果继续，abort 直接释放。
void AbortSessionEntry(int session);

void AbortSessionEntry(int session)
{
    AbortSessionImpl(session);
}

napi_value JsEvalBeginEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
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
    return MakeString(env, BeginEntryImpl(source, timeoutMs, memLimitMb));
}

napi_value JsEvalResumeEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int session = 0;
    if (argc > 0) {
        napi_get_value_int32(env, argv[0], &session);
    }
    const std::string results = argc > 1 ? ReadString(env, argv[1]) : std::string("[]");
    return MakeString(env, ResumeEntryImpl(session, results));
}

napi_value JsEvalAbortEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int session = 0;
    if (argc > 0) {
        napi_get_value_int32(env, argv[0], &session);
    }
    AbortSessionEntry(session);
    return MakeString(env, std::string("{\"aborted\":true}"));
}

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
        // 信封：{ok, t, j} 或 {ok:false, error}。value 是 JSON 文本，原样嵌入外壳——再转义一次
        // 就回到「二次编码」，调用方得 parse 两遍，类型也跟着丢。
        JSValue okValue = JS_GetPropertyStr(ctx, result, "ok");
        const bool ok = JS_ToBool(ctx, okValue) == 1;
        JS_FreeValue(ctx, okValue);
        if (!ok) {
            JSValue errValue = JS_GetPropertyStr(ctx, result, "error");
            const char *errText = JS_ToCString(ctx, errValue);
            out = "{\"ok\":false,\"error\":\"" + JsonEscape(errText) + "\",\"ms\":" +
                  std::to_string(elapsed) + "}";
            if (errText != nullptr) {
                JS_FreeCString(ctx, errText);
            }
            JS_FreeValue(ctx, errValue);
        } else {
            JSValue typeValue = JS_GetPropertyStr(ctx, result, "t");
            const char *typeText = JS_ToCString(ctx, typeValue);
            JSValue payload = JS_GetPropertyStr(ctx, result, "j");
            const char *payloadText = JS_ToCString(ctx, payload);
            out = "{\"ok\":true,\"type\":\"" + JsonEscape(typeText) + "\"";
            if (payloadText != nullptr) {
                out += ",\"value\":";
                out += payloadText;
            }
            out += ",\"ms\":" + std::to_string(elapsed) + "}";
            if (typeText != nullptr) {
                JS_FreeCString(ctx, typeText);
            }
            if (payloadText != nullptr) {
                JS_FreeCString(ctx, payloadText);
            }
            JS_FreeValue(ctx, payload);
        }
    }
    JS_FreeValue(ctx, result);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    g_deadlineMs.store(0);
    return MakeString(env, out);
}
