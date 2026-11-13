---
name: hvolt-build
description: hvolt 工程的构建、签名与部署顺序，以及几类只在设备上才暴露的失败
---

# hvolt 的构建与部署

## 顺序

`sign → build → push`。三者顺序颠倒会得到「签名未产出包」：`build` 只有在工程已有
`[app.signing]` 表时才签名，否则只出 `entry-unsigned.hap`。

## 每次改完代码

1. `build`，看输出里是否有 `✓ packed`；有 `✗` 就先解决，不要带着失败去 `push`。
2. `push --hap build/entry-signed.hap`。
3. `start`（或 `aa force-stop` 再 `aa start`）让新包真正跑起来——不重启可能还是旧进程。

## 只在设备上才暴露的失败

- **`the requested module ... does not provide an export name X`**：某个命名导入在源模块里不存在。
  编译期不报，启动即崩。这个项目在 `hvolt build` 里内置了导入图检查，正常情况会在构建时就拦下；
  若见到它出现在日志里，说明检查没覆盖到那条路径。
- **`is not defined`**：调用了未定义的同文件函数。ArkTS 编译不报未定义标识符，所以这类错误同样
  只在运行时出现。改完代码如果日志里有这句，先看是不是删函数时漏了调用点。
- **`Error Code:10106102 The device screen is locked`**：设备锁屏。开发者模式下系统不会自动解锁，
  需要人解锁，命令行无法代解。
- **`generated ECDSA signature did not verify with leaf certificate`**：`.p12` 与 `.cer`/`.p7b`
  不是同一次申请的产物。判据是 `.p12` 的修改时间晚于 `.cer`。
- **`fail to verify pkcs7 file`**：签名链不被该设备信任，通常是换了签名材料或 bundle 名不匹配。

## 读日志

优先用落盘的历史日志而不是实时流：应用切后台或被杀都不丢。要确认某个改动是否真的进了包，
用 `abc-records` 读 `modules.abc` 的 record 表，比看构建日志更直接。
