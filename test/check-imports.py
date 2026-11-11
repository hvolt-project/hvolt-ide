"""Verify every named import resolves to a declared export in its source module.

The device build does not check cross-module exports: a moved symbol keeps compiling and fails at
run time with "does not provide an export name". This checks the import graph directly.
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "src")
EXTS = ('.ets', '.ts')

# module path (relative dir, stem) -> set of exported names
modules = {}
files = []
for dirpath, _, names in os.walk(ROOT):
    for name in names:
        if name.endswith(EXTS):
            files.append(os.path.join(dirpath, name))

export_re = re.compile(r'^export\s+(?:declare\s+)?(?:type\s+)?(?:async\s+)?(?:function|class|struct|interface|const|let|var|enum|type)\s+([A-Za-z0-9_]+)', re.M)
export_default = re.compile(r'^export\s+default\b', re.M)
export_brace = re.compile(r'^export\s*\{([^}]*)\}', re.M)
export_from = re.compile(r'^export\s+\*\s+from\s+[\'"]([^\'"]+)[\'"]', re.M)

for path in files:
    text = open(path, encoding='utf-8').read()
    names = set(export_re.findall(text))
    for group in export_brace.findall(text):
        for part in group.split(','):
            part = part.strip()
            if not part:
                continue
            names.add(part.split(' as ')[-1].strip())
    modules[os.path.abspath(path)] = names

import_re = re.compile(r'^import\s+(?:type\s+)?\{([^}]*)\}\s+from\s+[\'"]([^\'"]+)[\'"];?', re.M)

problems = []
for path in files:
    text = open(path, encoding='utf-8').read()
    for group, target in import_re.findall(text):
        if not target.startswith('.'):
            continue
        base = os.path.normpath(os.path.join(os.path.dirname(path), target))
        candidates = [base]
        candidates += [base + e for e in EXTS if not base.endswith(e)]
        candidates += [os.path.join(base, 'index' + e) for e in EXTS]
        resolved = next((c for c in candidates if os.path.abspath(c) in modules), None)
        if resolved is None:
            problems.append((path, target, '*', 'module not found'))
            continue
        exported = modules[os.path.abspath(resolved)]
        for part in group.split(','):
            part = part.strip()
            if not part:
                continue
            name = part.split(' as ')[0].strip()
            if name and name not in exported:
                problems.append((path, target, name, 'not exported'))

if problems:
    for path, target, name, why in problems:
        print(f'{path}: {name} <- {target} ({why})')
    sys.exit(1)
print(f'ok: {len(files)} modules, every named import resolves')
