// Strip // and /* */ comments from .ets/.ts files under src/, line by line.
// Blank lines are kept so line numbers in stack traces still match the source.
//
// Two constraints shape this file:
//   · rhai caps expression complexity by AST depth — and that cap counts nesting, so even
//     `rest.len() - at - 2` inside a call argument is too deep. Every arithmetic step gets its
//     own `let` and every call takes plain names;
//   · `//` inside a string literal is not a comment, so quoted spans are copied verbatim
//     before any comment marker is considered.

/// The earliest non-negative offset, or -1 when all are absent.
fn earliest(values) {
    let best = -1;
    for value in values {
        if value < 0 { continue; }
        if best < 0 { best = value; continue; }
        if value < best { best = value; }
    }
    best
}

/// Remove one line's comments. Returns [text, still_in_block].
fn strip_line(line, in_block) {
    let out = "";
    let rest = line;
    if in_block {
        let close_at = rest.index_of("*/");
        if close_at < 0 {
            return ["", true];
        }
        let start = close_at + 2;
        let total = rest.len();
        let length = total - start;
        rest = rest.sub_string(start, length);
    }
    while true {
        let dq = rest.index_of("\"");
        let sq = rest.index_of("'");
        let lc = rest.index_of("//");
        let bc = rest.index_of("/*");
        let at = earliest([dq, sq, lc, bc]);
        if at < 0 {
            return [out + rest, false];
        }
        let head = rest.sub_string(0, at);
        if at == lc {
            // Line comment: everything after it on this line goes away.
            return [out + head, false];
        }
        if at == bc {
            // Block comment: either it closes on this line or the rest of the line is inside.
            let start = at + 2;
            let total = rest.len();
            let length = total - start;
            let after = rest.sub_string(start, length);
            let close_at = after.index_of("*/");
            if close_at < 0 {
                return [out + head, true];
            }
            let resume = close_at + 2;
            let after_total = after.len();
            let after_length = after_total - resume;
            out += head;
            rest = after.sub_string(resume, after_length);
            continue;
        }
        // A quoted span: copy it through untouched, including the closing quote.
        let marker = rest.sub_string(at, 1);
        let start = at + 1;
        let total = rest.len();
        let length = total - start;
        let after_open = rest.sub_string(start, length);
        let close_at = after_open.index_of(marker);
        if close_at < 0 {
            // Unterminated on this line; keep the remainder and stop looking.
            return [out + rest, false];
        }
        let quoted_end = close_at + 1;
        let quoted = after_open.sub_string(0, quoted_end);
        out += head + marker + quoted;
        let after_open_total = after_open.len();
        let remaining = after_open_total - quoted_end;
        rest = after_open.sub_string(quoted_end, remaining);
    }
    [out, false]
}

fn strip_file(path) {
    let before = read(path);
    let after = "";
    let in_block = false;
    for line in before.split("\n") {
        let result = strip_line(line, in_block);
        in_block = result[1];
        let kept = result[0];
        after += kept + "\n";
    }
    // split("\n") leaves a trailing empty segment for a file that ends with a newline.
    let total = after.len();
    let keep = total - 1;
    after = after.sub_string(0, keep);
    if after != before {
        write(path, after);
        info("stripped " + path);
        return 1;
    }
    return 0;
}

let changed = 0;
if exists("src") {
    for name in list("src") {
        let is_ets = name.ends_with(".ets");
        let is_ts = name.ends_with(".ts");
        if is_ets || is_ts {
            let path = join("src", name);
            changed += strip_file(path);
        }
    }
}
info("files changed: " + changed);
