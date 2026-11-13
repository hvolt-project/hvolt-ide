---
name: arkts-strict
description: ArkTS 编译期的严格模式限制，以及哪些 TypeScript 写法在这里编不过或运行才炸
---

# ArkTS 的严格之处

这个项目的界面代码是 ArkTS（`.ets`），纯逻辑放在 `.ts` 里以便用 `node --test` 跑。两者的限制不同：
`.ts` 基本按 TypeScript 处理，`.ets` 走 ArkTS 的严格模式。

## 在 `.ets` 里不要做的事

- **对象字面量必须有明确的类型**：不能靠推断出一个匿名形状再传给别的函数，ArkTS 会拒绝
  `arkts-no-untyped-obj-literals`。要么写成 `class`/`interface` 的实例，要么给字面量标注类型。
- **不要用解构与展开**：`const { a, b } = obj`、`{ ...rest }`、`[...list]` 在 ArkTS 里受限，
  用逐字段赋值与循环 push 代替。
- **不要用 `any` / `unknown` 做逃逸**：编译会拦，改用 `Record<string, Object>` 或具体接口。
- **函数必须有显式返回类型**：递归调用或回调里缺返回类型会报错。

## 运行期才暴露的坑

- **未定义的标识符不报编译错**：删掉一个函数却留下调用点，编译通过，运行时 `X is not defined`。
  删函数前先全局搜它的调用点。
- **`undefined` 会穿过**：字段没初始化、可选参数没传，读到的是 `undefined`，第一次 `.length`
  或遍历时才炸。构造对象时每个字段都给默认值。
- **异步与 UI 线程**：`@Builder` 与状态更新在主线程；耗时调用要走异步并 await，不要阻塞。
  文件监听回调里抛出的异常不会冒到页面上，要显式 log。

## 验证方式

- 纯逻辑改到 `.ts` 里，写 `test/*.test.ts`，跑 `node --test test/`。
- 界面改动只能装到设备上看：编译通过不代表能跑，这两个错误类型（未定义标识符、undefined 穿透）
  都只在运行时出现。
