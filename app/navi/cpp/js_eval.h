#ifndef NAVI_JS_EVAL_H
#define NAVI_JS_EVAL_H

#include "napi/native_api.h"

// jsEval(source, timeoutMs, memLimitMb) -> JSON 文本 {ok, value|error, ms}
napi_value JsEval(napi_env env, napi_callback_info info);

#endif  // NAVI_JS_EVAL_H
