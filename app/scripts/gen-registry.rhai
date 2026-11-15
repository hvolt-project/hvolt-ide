// 生成工具注册表：扫描 tools/*.ets，把标了 MCP_EXPOSE 的文件拼成一份注册调用清单。
//
// 为什么要生成而不是手写：新增一个能力时，手写的清单要同步改，漏改不会报错——工具就是
// 静默地不出现。生成之后「新增文件即暴露」，而是否暴露由文件自己的 MCP_EXPOSE 决定。
//
// 为什么在 pre 阶段跑：ArkTS 编译在 packaging 之前读源码树，post 阶段写出的 .ets 不参与
// 本次编译。
//
// 参数个数从签名里读：有 (registry, ctx) 两个参数就把 ctx 传进去，只有 (registry) 的少传
// 一个。靠这个而不是靠一张名单，是为了让签名本身就是唯一事实。

// 路径相对 project_dir，而 project_dir 是 hvolt.toml 所在的 app/（pipeline.rs:204 用
// project_dir.join("hvolt.toml") 定位工程），所以不带 app/ 前缀。
let TOOLS_DIR = "src/pages/harness/tools";
let OUT_DIR = "src/pages/harness";
let OUT_FILE = OUT_DIR + "/Registry.generated.ets";

fn trim(text) {
    let out = text;
    while out.starts_with(" ") || out.starts_with("\t") || out.starts_with("\r") {
        out = out.sub_string(1, out.len() - 1);
    }
    while out.ends_with(" ") || out.ends_with("\t") || out.ends_with("\r") {
        out = out.sub_string(0, out.len() - 1);
    }
    out
}

/// 从一行里取出 `export const MCP_EXPOSE: string[] = ['a', 'b'];` 的工具名。
fn exposed_names(line) {
    let names = [];
    // 从 `=` 之后开始找第一个 `[`：类型标注 `string[]` 里已经有一对方括号，
    // 从头找会取到 `string[` 与 `]` 之间的空串。
    let eq = line.index_of("=");
    if eq < 0 { return names; }
    let tail = line.sub_string(eq, line.len() - eq);
    let at = tail.index_of("[");
    let end = tail.index_of("]");
    if at < 0 || end < 0 || end <= at { return names; }
    let inner = tail.sub_string(at + 1, end - at - 1);
    for piece in inner.split(",") {
        let item = trim(piece);
        if item.starts_with("\"") || item.starts_with("'") {
            item = item.sub_string(1, item.len() - 2);
        }
        if item.len() > 0 {
            names.push(item);
        }
    }
    names
}

/// 从 `export function registerXxx(registry...)` 取出函数名与是否吃 ctx。
fn register_fn(line) {
    let marker = "export function register";
    let at = line.index_of(marker);
    if at < 0 { return []; }
    let rest = line.sub_string(at + marker.len(), line.len() - at - marker.len());
    let paren = rest.index_of("(");
    if paren < 0 { return []; }
    let name = "register" + rest.sub_string(0, paren);
    let takes_ctx = rest.index_of("ctx") > 0;
    return [name, takes_ctx];
}

let modules = [];
let seen = 0;
for file in list(TOOLS_DIR) {
    if !file.ends_with(".ets") { continue; }
    seen += 1;
    let path = join(TOOLS_DIR, file);
    let source = read(path);
    let names = [];
    let registrar = [];
    for line in source.split("\n") {
        let trimmed = trim(line);
        // 注释行不参与：注销一个工具最常见的做法就是把那行 export 注释掉，若在这里照匹配，
        // 已注销的工具仍会被注册（验收第 2 条会假通过）。
        if trimmed.starts_with("//") || trimmed.starts_with("*") { continue; }
        if trimmed.index_of("MCP_EXPOSE") >= 0 {
            names = exposed_names(trimmed);
        }
        if trimmed.index_of("export function register") >= 0 && registrar.len() == 0 {
            registrar = register_fn(trimmed);
        }
    }
    if names.len() == 0 {
        info("skip " + file + " (no MCP_EXPOSE)");
        continue;
    }
    if registrar.len() == 0 {
        fail(file + " declares MCP_EXPOSE but has no register function");
    }
    let stem = file.sub_string(0, file.len() - 4);
    modules.push([stem, registrar[0], registrar[1], names]);
    info("expose " + file + ": " + names);
}

if modules.len() == 0 {
    fail("no tool file declares MCP_EXPOSE; refusing to write an empty registry");
}

let out = "// 生成文件，不要手改。来源：app/scripts/gen-registry.rhai\n";
out += "// 只有导出 MCP_EXPOSE 的工具文件会出现在这里。\n\n";
out += "import { ToolRegistry } from './mcp/Registry';\n";
out += "import { FileContext } from './tools/Files';\n";
for m in modules {
    out += "import { " + m[1] + " } from './tools/" + m[0] + "';\n";
}
out += "\n/** 由构建步骤按 tools/*.ets 的 MCP_EXPOSE 生成。 */\n";
out += "export function registerExposedTools(registry: ToolRegistry, ctx: FileContext): void {\n";
for m in modules {
    if m[2] {
        out += "  " + m[1] + "(registry, ctx);\n";
    } else {
        out += "  " + m[1] + "(registry);\n";
    }
}
out += "}\n";
write(OUT_FILE, out);
info("registry written: " + modules.len() + " module(s) from " + seen + " tool file(s)");
