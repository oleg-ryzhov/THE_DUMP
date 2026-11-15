@echo off & chcp 65001 >nul & python -x "%~f0" %* & echo. & pause & exit /b
# ============================================================================
#  apply_structure.bat  ->  runs as Python via  `python -x "%~f0"`
#
#  Reads a structure .txt (as produced by dump_folders.bat, or hand-written in
#  the same tree format) and makes the folder this .bat lives in match it.
#
#  Behavior:
#    * Supported files not in the spec tree                -> deleted
#    * Unsupported files (png, exe, zip, ...)              -> never touched
#    * Dir in spec, not on disk                            -> created
#    * File in spec, not on disk                           -> created with
#                                                             FILE CONTENTS
#                                                             text (or empty)
#    * File on disk whose content differs from FILE
#      CONTENTS                                            -> overwritten
#    * Dir not in spec, empty after file pass              -> removed
#    * Top-level files, this .bat, and the spec itself     -> always preserved
#
#  Sentinel strings from the dumper ([Binary file — skipped],
#  [File too large...], [Error...], etc.) are recognized and never written
#  as literal content. For those, an existing file is left as-is and a
#  missing one is created empty.
#
#  CLI flags:
#    -n / --dry-run   show plan without touching anything
#    -y / --yes       skip the confirmation prompt
# ============================================================================

import os
import re
import sys

# ----------------------------- CONFIG -----------------------------
TEXT_EXTS = {
    '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.sh', '.bash', '.zsh', '.fish',
    '.py', '.pyw', '.pyi', '.ipynb',
    '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx',
    '.html', '.htm', '.xhtml', '.css', '.scss', '.sass', '.less', '.styl',
    '.vue', '.svelte', '.astro',
    '.java', '.kt', '.kts', '.scala', '.groovy', '.gradle',
    '.swift', '.dart', '.m', '.mm',
    '.c', '.h', '.cpp', '.cc', '.cxx', '.hpp', '.hxx', '.cs', '.csx',
    '.go', '.rs', '.rb', '.php', '.pl', '.pm', '.lua', '.r', '.jl',
    '.fs', '.fsx', '.hs', '.lhs', '.ex', '.exs', '.erl', '.hrl',
    '.clj', '.cljs', '.cljc', '.edn', '.nim', '.zig',
    '.v', '.sv', '.svh', '.vhdl', '.vhd', '.asm', '.s',
    '.json', '.jsonc', '.json5', '.xml', '.yml', '.yaml', '.toml',
    '.ini', '.cfg', '.conf', '.config', '.properties', '.env',
    '.sql', '.graphql', '.gql', '.proto', '.thrift',
    '.md', '.markdown', '.rst', '.adoc', '.asciidoc', '.tex', '.bib',
    '.txt', '.text', '.log', '.csv', '.tsv', '.rtf', '.srt', '.vtt',
    '.dockerfile', '.makefile', '.mk', '.cmake',
    '.gitignore', '.gitattributes', '.editorconfig', '.npmrc', '.nvmrc',
    '.lock', '.gitconfig', '.hgignore', '.svnignore',
    '.reg', '.inf', '.manifest',
    '.svg', '.diff', '.patch',
    '.docx',
}

SPECIAL_NAMES = {
    'dockerfile', 'makefile', 'cmakelists.txt', 'readme', 'license',
    'changelog', 'contributing', 'authors', 'notice',
}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def is_supported_file(name):
    lower = name.lower()
    base, ext = os.path.splitext(lower)
    return ext in TEXT_EXTS or lower in TEXT_EXTS or base in SPECIAL_NAMES


# ----------------------- PARSE HIERARCHY --------------------------
def parse_structure(text):
    has_marker   = 'FOLDER HIERARCHY' in text
    has_contents = 'FILE CONTENTS'    in text
    if has_contents and not has_marker:
        return set()

    items   = set()
    section = None
    stack   = []
    in_hier = not has_marker

    for raw in text.splitlines():
        s = raw.rstrip()
        if not s.strip():
            continue
        if s.strip() == 'FOLDER HIERARCHY':
            in_hier = True
            continue
        if s.strip() == 'FILE CONTENTS':
            in_hier = False
            break
        if not in_hier:
            continue
        if s.startswith('=') or s.startswith('-'):
            continue

        if s[0] not in ' \t│├└':
            name = s.strip().rstrip('/')
            if name:
                section = name
                stack   = []
                items.add((name, True))
            continue
        if section is None:
            continue

        depth = 0
        pos   = 0
        n     = len(s)
        while pos < n:
            if s[pos:pos+4] == '│   ':
                depth += 1; pos += 4
            elif s[pos:pos+4] == '    ':
                depth += 1; pos += 4
            elif s[pos] in '├└':
                pos += 1
                while pos < n and s[pos] in '-─ ':
                    pos += 1
                break
            else:
                break

        rest = s[pos:].strip()
        if not rest:
            continue
        is_dir = rest.endswith('/')
        name   = rest.rstrip('/')
        if not name:
            continue

        while stack and stack[-1][0] >= depth:
            stack.pop()
        parts = [section] + [d for _, d in stack] + [name]
        path  = '/'.join(parts)
        items.add((path, is_dir))
        if is_dir:
            stack.append((depth, name))

    return items


# ------------------------ PARSE CONTENTS --------------------------
SENTINEL_RES = [
    re.compile(r'^\[Binary file'),
    re.compile(r'^\[File too large'),
    re.compile(r'^\[Could not extract'),
    re.compile(r'^\[Could not decode'),
    re.compile(r'^\[Error[:\s]'),
    re.compile(r'^\[Error reading file'),
    re.compile(r'^\[Empty \.docx\]'),
    re.compile(r'^\[Permission denied'),
]


def is_sentinel(content):
    s = content.strip()
    return any(r.match(s) for r in SENTINEL_RES)


def parse_contents(text, tree_items):
    """Return dict {path: content} for files in FILE CONTENTS that also
    appear in the tree. Sentinel-only entries are still returned — callers
    decide what to do with them."""
    m = re.search(r'^=+\r?\nFILE CONTENTS\r?\n=+\r?\n', text, re.MULTILINE)
    if not m:
        return {}
    section    = text[m.end():]
    tree_files = {p for p, d in tree_items if not d}

    header_re = re.compile(
        r'^-{78}\r?\nFILE: (.+?)\r?\n-{78}\r?\n',
        re.MULTILINE,
    )
    matches = list(header_re.finditer(section))

    result = {}
    for i, mm in enumerate(matches):
        path = mm.group(1).strip()
        if path not in tree_files:
            # A `---` + `FILE:` sequence inside someone's file content —
            # not a real header. Skip.
            continue
        start = mm.end()
        end   = matches[i + 1].start() if i + 1 < len(matches) else len(section)
        raw   = section[start:end]

        # The dumper joins every element with '\n' and inserts an empty
        # separator between a file's content and the next header. That
        # adds exactly two '\n' after the real content. Strip them.
        if raw.endswith('\r\n\r\n'):
            content = raw[:-4]
        elif raw.endswith('\n\n'):
            content = raw[:-2]
        elif raw.endswith('\r\n'):
            content = raw[:-2]
        elif raw.endswith('\n'):
            content = raw[:-1]
        else:
            content = raw

        result[path] = content

    return result


# ------------------------ READ EXISTING ---------------------------
def read_text_file(path):
    for enc in ('utf-8-sig', 'utf-8', 'cp1252', 'latin-1'):
        try:
            with open(path, 'r', encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError:
            continue
        except Exception:
            return None
    return None


# ---------------------------- PLAN --------------------------------
def plan_sync(target_dir, spec_items, spec_contents, preserve_paths):
    spec_norm     = {(p.lower(), d) for p, d in spec_items}
    preserve_norm = {os.path.normcase(os.path.abspath(p)) for p in preserve_paths}

    # ---- 1. files to delete
    deletes_f = []
    for root, _dirs, files in os.walk(target_dir):
        rel_root = os.path.relpath(root, target_dir).replace('\\', '/')
        if rel_root == '.':
            continue
        for f in files:
            full = os.path.join(root, f)
            if os.path.normcase(os.path.abspath(full)) in preserve_norm:
                continue
            if not is_supported_file(f):
                continue
            rel = (rel_root + '/' + f) if rel_root else f
            if (rel.lower(), False) not in spec_norm:
                deletes_f.append(rel)

    # ---- 2. files that will remain
    deleting        = {(p.lower(), False) for p in deletes_f}
    remaining_files = set()
    for root, _dirs, files in os.walk(target_dir):
        rel_root = os.path.relpath(root, target_dir).replace('\\', '/')
        if rel_root == '.':
            continue
        for f in files:
            full = os.path.join(root, f)
            rel  = (rel_root + '/' + f) if rel_root else f
            if os.path.normcase(os.path.abspath(full)) in preserve_norm:
                remaining_files.add(rel.lower()); continue
            if not is_supported_file(f):
                remaining_files.add(rel.lower()); continue
            if (rel.lower(), False) not in deleting:
                remaining_files.add(rel.lower())

    # ---- 3. directories to remove (deepest first)
    deletes_d      = []
    deleted_dirs   = set()
    for root, _dirs, files in os.walk(target_dir, topdown=False):
        if os.path.abspath(root) == os.path.abspath(target_dir):
            continue
        rel_root = os.path.relpath(root, target_dir).replace('\\', '/')
        if (rel_root.lower(), True) in spec_norm:
            continue
        has_files = any(
            os.path.isfile(os.path.join(root, f)) and
            ((rel_root + '/' + f) if rel_root else f).lower() in remaining_files
            for f in os.listdir(root)
        )
        if has_files:
            continue
        has_children = any(
            os.path.isdir(os.path.join(root, d)) and
            ((rel_root + '/' + d) if rel_root else d).lower() not in deleted_dirs
            for d in os.listdir(root)
        )
        if has_children:
            continue
        deletes_d.append(rel_root)
        deleted_dirs.add(rel_root.lower())

    # ---- 4. dirs and files to create / update
    creates_d = []
    creates_f = []   # list of (path, content, action)
    for path, is_dir in sorted(spec_items, key=lambda x: (x[0].count('/'), x[0])):
        full = os.path.join(target_dir, path.replace('/', os.sep))

        if is_dir:
            if os.path.isfile(full):
                continue
            if not os.path.isdir(full):
                creates_d.append(path)
            continue

        name = os.path.basename(path)
        if not is_supported_file(name):
            continue
        if name.lower().endswith('.docx'):
            continue                          # can't recreate a .docx from text
        if os.path.isdir(full):
            continue

        content     = spec_contents.get(path)
        has_content = content is not None and not is_sentinel(content)

        if os.path.exists(full):
            if has_content:
                existing = read_text_file(full)
                if existing != content:
                    creates_f.append((path, content, 'update'))
            # else: spec has only a sentinel (or nothing) for this file —
            # leave the existing file untouched.
        else:
            if has_content:
                creates_f.append((path, content, 'create'))
            else:
                creates_f.append((path, '', 'create empty'))

    return deletes_f, deletes_d, creates_d, creates_f


# ---------------------------- DISPLAY -----------------------------
def preview(title, items, marker, limit=25):
    if not items:
        return
    print(f'  {title}: {len(items)}')
    for p in items[:limit]:
        if isinstance(p, tuple):
            label  = p[0]
            suffix = f' ({p[2]})' if len(p) > 2 else ''
        else:
            label, suffix = p, ''
        print(f'    {marker} {label}{suffix}')
    if len(items) > limit:
        print(f'    ... and {len(items) - limit} more')


# ---------------------------- APPLY -------------------------------
def apply_plan(target_dir, deletes_f, deletes_d, creates_d, creates_f):
    for rel in deletes_f:
        full = os.path.join(target_dir, rel.replace('/', os.sep))
        try:
            os.remove(full)
            print(f'  - {rel}')
        except OSError as e:
            print(f'  ! could not delete {rel}: {e}')

    for rel in deletes_d:
        full = os.path.join(target_dir, rel.replace('/', os.sep))
        try:
            if not os.listdir(full):
                os.rmdir(full)
                print(f'  - {rel}/')
        except OSError as e:
            print(f'  ! could not remove {rel}/: {e}')

    for rel in creates_d:
        full = os.path.join(target_dir, rel.replace('/', os.sep))
        try:
            os.makedirs(full, exist_ok=True)
            print(f'  + {rel}/')
        except OSError as e:
            print(f'  ! could not create {rel}/: {e}')

    for path, content, action in creates_f:
        full = os.path.join(target_dir, path.replace('/', os.sep))
        try:
            parent = os.path.dirname(full)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(full, 'w', encoding='utf-8') as f:
                f.write(content)
            verb = '~' if action == 'update' else '+'
            print(f'  {verb} {path}')
        except OSError as e:
            print(f'  ! could not write {path}: {e}')


# ----------------------------- MAIN -------------------------------
def pick_spec(argv):
    dry_run = assume_yes = False
    spec_arg = None
    for a in argv:
        if a in ('-n', '--dry-run'):
            dry_run = True
        elif a in ('-y', '--yes'):
            assume_yes = True
        else:
            spec_arg = a

    if not spec_arg:
        raw = input('Enter the structure .txt name (or drag it here): ').strip()
        spec_arg = raw.strip('"').strip("'")
    if not spec_arg:
        return None, dry_run, assume_yes

    if os.path.isfile(spec_arg):
        return os.path.abspath(spec_arg), dry_run, assume_yes
    cand = os.path.join(SCRIPT_DIR, spec_arg)
    if os.path.isfile(cand):
        return cand, dry_run, assume_yes
    print(f'Error: spec "{spec_arg}" not found.')
    return None, dry_run, assume_yes


def main():
    spec_path, dry_run, assume_yes = pick_spec(sys.argv[1:])
    if not spec_path:
        return

    print(f'Spec  : {spec_path}')
    print(f'Target: {SCRIPT_DIR}')

    try:
        with open(spec_path, 'r', encoding='utf-8') as f:
            text = f.read()
    except UnicodeDecodeError:
        with open(spec_path, 'r', encoding='cp1252') as f:
            text = f.read()

    spec_items = parse_structure(text)
    if not spec_items:
        print('\nNo structure found in spec (missing FOLDER HIERARCHY section?)')
        return

    spec_contents = parse_contents(text, spec_items)
    print(f'Parsed {len(spec_items)} tree items, {len(spec_contents)} file contents from spec.')

    preserve = [__file__, spec_path]

    d_f, d_d, c_d, c_f = plan_sync(SCRIPT_DIR, spec_items, spec_contents, preserve)

    print('\n--- Plan ----------------------------------------------------------')
    preview('Delete files',           d_f, '-')
    preview('Remove empty dirs',      d_d, '-')
    preview('Create dirs',            c_d, '+')
    preview('Create/update files',    c_f, '+')
    if not (d_f or d_d or c_d or c_f):
        print('  Folder already matches spec. Nothing to do.')
        return

    if any(p.lower().endswith('.docx') for p in d_f):
        print('\n  WARNING: .docx files will be deleted and their contents lost.')

    print('-------------------------------------------------------------------')
    if dry_run:
        print('[DRY RUN] No changes made.')
        return
    if not assume_yes:
        if input('\nApply these changes? [y/N]: ').strip().lower() not in ('y', 'yes'):
            print('Aborted.')
            return

    print('\nApplying...')
    apply_plan(SCRIPT_DIR, d_f, d_d, c_d, c_f)
    print('Done.')


if __name__ == '__main__':
    main()
