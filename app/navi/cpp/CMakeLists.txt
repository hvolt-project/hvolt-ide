cmake_minimum_required(VERSION 3.5.0)
project(navi)
set(CMAKE_CXX_STANDARD 17)
add_library(navi SHARED napi_init.cpp sandbox_sh.cpp js_eval.cpp git_napi.cpp rewind_napi.cpp)
target_include_directories(navi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/quickjs ${CMAKE_CURRENT_SOURCE_DIR}/libgit2)
# libgit2 从 app/src/libs/arm64-v8a 取：那是打包进 HAP 的那一份，链接与运行用同一文件，
# 不会出现「链接到一个版本、装进包里另一个版本」。
set(GIT2_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../src/libs/arm64-v8a/libgit2.so)
target_link_libraries(navi PUBLIC libace_napi.z.so libhilog_ndk.z.so dl m ${CMAKE_CURRENT_SOURCE_DIR}/quickjs/libquickjs.a ${GIT2_LIB})
