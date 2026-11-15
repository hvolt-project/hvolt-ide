// 把 IDE 自己的源码打进 rawfile/self/source.zip：应用在设备上打开这份源码、改完再构建装回自己。
//
// 以前是 scripts/pack-self.sh 在宿主机上用 rsync + zip 做的。设备上没有这两个二进制，
// 所以改成构建步骤：条目相对 project_dir（即 hvolt.toml 所在的 app/），归档写到 out_dir 下。
//
// 排除项沿用 pack-self.sh 的理由，一条都不能省：
//   signing/   密钥与口令。归档在应用内部，等于把「以本应用身份签名」的能力交出去。
//   sdk/       从 SDK 拷来的声明文件。
//   build/     产物。
//   resources/rawfile/self/  正在生成的这份归档本身；不排除就会把上一份包进新的，每打包一次翻一倍。
//   output/     上一轮打好的包。不排除时它会被打进新的 source.zip，再把 source.zip 打进新的包，
//               一次比一次大（实测 36.7 MB 的 HAP 进了归档）。
//   resources/rawfile/sdk/  SDK 声明文件的展开目录；归档里用的是同级的 sdk.zip。
//   navi/cpp 下的 libgit2/quickjs/ssh 与 *.a 是 native 编译期依赖。设备上没有 cmake 与 clang，
//               native 模块只能靠 src/libs 里的预编译 so，这些源码带上只增体积。
//
// src/libs/arm64-v8a/*.so 必须留下：设备上没有 cmake、clang、NDK，native 模块与两份预编译库
// 在手机上产不出来，带上它们才谈得上在手机上构建这份源码。

let OUT = "resources/rawfile/self/source.zip";

fn allowed(path) {
    if path.starts_with("signing/") { return false; }
    if path.starts_with("sdk/") { return false; }
    if path.starts_with("build/") { return false; }
    if path.starts_with("output/") { return false; }
    if path.starts_with("resources/rawfile/self/") { return false; }
    if path.starts_with("resources/rawfile/sdk/") { return false; }
    if path.starts_with("navi/cpp/libgit2/") { return false; }
    if path.starts_with("navi/cpp/quickjs/") { return false; }
    if path.starts_with("navi/cpp/ssh/") { return false; }
    if path.ends_with(".a") { return false; }
    if path.ends_with(".DS_Store") { return false; }
    true
}

fn collect(dir) {
    let out = [];
    for name in list(dir) {
        let path = if dir.len() == 0 { name } else { dir + "/" + name };
        if !allowed(path) { continue; }
        if is_dir(path) {
            for inner in collect(path) { out.push(inner); }
        } else {
            out.push(path);
        }
    }
    out
}

let entries = collect("");
if entries.len() == 0 {
    fail("self archive would be empty: nothing under " + project_dir());
}
let written = zip(OUT, entries);
// Declared so the packing stage keeps this file rather than dropping what it did not expect.
emit(OUT);
info("self archive: " + written + " file(s) → " + OUT);
