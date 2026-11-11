@echo off & python -x "%~f0" %* & echo. & pause & exit /b
# ============================================================================
#  dump_folders.bat  ->  runs as Python via  `python -x "%~f0"`
#
#  Place inside a folder. Scans every sibling subfolder (recursively),
#  writes a hierarchy tree + file contents to  folder_contents_output.txt
#  next to this file.
#
#  MAX_FILE_SIZE = -1  ->  no size cap
# ============================================================================

import os
import re
import zipfile

# ----------------------------- CONFIG -----------------------------
INCLUDE_CONTENTS   = True
MAX_FILE_SIZE      = -1                   # -1 = unlimited, 0 = only empty files, N = N bytes
OUTPUT_FILENAME    = 'folder_contents_output.txt'

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.path.join(SCRIPT_DIR, OUTPUT_FILENAME)

TEXT_EXTS = {
    # Windows / shell
    '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.sh', '.bash', '.zsh', '.fish',
    # Python
    '.py', '.pyw', '.pyi', '.ipynb',
    # JS / TS / web
    '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx',
    '.html', '.htm', '.xhtml', '.css', '.scss', '.sass', '.less', '.styl',
    '.vue', '.svelte', '.astro',
    # JVM / mobile
    '.java', '.kt', '.kts', '.scala', '.groovy', '.gradle',
    '.swift', '.dart', '.m', '.mm',
    # C family / .NET
    '.c', '.h', '.cpp', '.cc', '.cxx', '.hpp', '.hxx', '.cs', '.csx',
    # Systems / scripting
    '.go', '.rs', '.rb', '.php', '.pl', '.pm', '.lua', '.r', '.jl',
    '.fs', '.fsx', '.hs', '.lhs', '.ex', '.exs', '.erl', '.hrl',
    '.clj', '.cljs', '.cljc', '.edn', '.nim', '.zig',
    '.v', '.sv', '.svh', '.vhdl', '.vhd', '.asm', '.s',
    # Data / config / markup
    '.json', '.jsonc', '.json5', '.xml', '.yml', '.yaml', '.toml',
    '.ini', '.cfg', '.conf', '.config', '.properties', '.env',
    '.sql', '.graphql', '.gql', '.proto', '.thrift',
    # Docs / text
    '.md', '.markdown', '.rst', '.adoc', '.asciidoc', '.tex', '.bib',
    '.txt', '.text', '.log', '.csv', '.tsv', '.rtf', '.srt', '.vtt',
    # Build / misc
    '.dockerfile', '.makefile', '.mk', '.cmake',
    '.gitignore', '.gitattributes', '.editorconfig', '.npmrc', '.nvmrc',
    '.lock', '.gitconfig', '.hgignore', '.svnignore',
    '.reg', '.inf', '.manifest',
    '.svg', '.diff', '.patch',
}

SPECIAL_NAMES = {
    'dockerfile', 'makefile', 'cmakelists.txt', 'readme', 'license',
    'changelog', 'contributing', 'authors', 'notice',
}


# --------------------------- HELPERS ------------------------------
def extract_docx(path):
    try:
        with zipfile.ZipFile(path) as z:
            xml = z.read('word/document.xml').decode('utf-8', errors='replace')
        xml = xml.replace('</w:p>', '\n')
        xml = re.sub(r'<w:tab[^>]*/>', '\t', xml)
        xml = re.sub(r'<w:br[^>]*/>', '\n', xml)
        text = re.sub(r'<[^>]+>', '', xml)
        return text.strip() or '[Empty .docx]'
    except Exception as e:
        return f'[Could not extract .docx: {e}]'


def is_binary(path):
    try:
        with open(path, 'rb') as f:
            return b'\x00' in f.read(4096)
    except Exception:
        return True


def should_include(path):
    name  = os.path.basename(path)
    lower = name.lower()
    base, ext = os.path.splitext(lower)
    if ext in TEXT_EXTS or lower in TEXT_EXTS:
        return True
    if base in SPECIAL_NAMES:
        return True
    if ext == '.docx':
        return True
    return False


def read_file(path):
    ext = os.path.splitext(path.lower())[1]
    try:
        size = os.path.getsize(path)
    except OSError as e:
        return f'[Error: {e}]'

    # -1 disables the cap; 0 caps at 0 bytes; N caps at N bytes.
    if MAX_FILE_SIZE >= 0 and size > MAX_FILE_SIZE:
        return f'[File too large ({size:,} bytes) — skipped (cap = {MAX_FILE_SIZE:,})]'

    if ext == '.docx':
        return extract_docx(path)

    if is_binary(path):
        return '[Binary file — skipped]'

    for enc in ('utf-8-sig', 'utf-8', 'cp1252', 'latin-1'):
        try:
            with open(path, 'r', encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError:
            continue
        except Exception as e:
            return f'[Error reading file: {e}]'
    return '[Could not decode file]'


def build_tree(folder):
    lines = []

    def walk(path, prefix=''):
        try:
            entries = sorted(os.listdir(path))
        except PermissionError:
            lines.append(prefix + '└── [Permission denied]')
            return
        dirs  = [e for e in entries if os.path.isdir(os.path.join(path, e))]
        files = [e for e in entries if os.path.isfile(os.path.join(path, e))]
        items = dirs + files
        for i, entry in enumerate(items):
            full      = os.path.join(path, entry)
            last      = (i == len(items) - 1)
            connector = '└── ' if last else '├── '
            if os.path.isdir(full):
                lines.append(prefix + connector + entry + '/')
                walk(full, prefix + ('    ' if last else '│   '))
            else:
                lines.append(prefix + connector + entry)

    walk(folder)
    return '\n'.join(lines)


# ----------------------------- MAIN -------------------------------
def main():
    print(f'Scanning: {SCRIPT_DIR}')

    subfolders = []
    for entry in sorted(os.listdir(SCRIPT_DIR)):
        full = os.path.join(SCRIPT_DIR, entry)
        if os.path.isdir(full):
            subfolders.append((entry, full))

    if not subfolders:
        print('No subfolders found next to this file.')
        return

    for name, _ in subfolders:
        print(f'  + {name}/')

    cap_desc = 'unlimited' if MAX_FILE_SIZE < 0 else f'{MAX_FILE_SIZE:,} bytes'
    print(f'Max file size: {cap_desc}')

    parts = ['=' * 78, 'FOLDER HIERARCHY', '=' * 78]
    for name, full in subfolders:
        parts.append('')
        parts.append(name + '/')
        parts.append(build_tree(full))

    file_count = 0
    if INCLUDE_CONTENTS:
        parts.append('')
        parts.append('')
        parts.append('=' * 78)
        parts.append('FILE CONTENTS')
        parts.append('=' * 78)

        for name, full in subfolders:
            for root, dirs, files in os.walk(full):
                dirs.sort()
                for fname in sorted(files):
                    fpath = os.path.join(root, fname)
                    if not should_include(fpath):
                        continue
                    file_count += 1
                    rel = os.path.relpath(fpath, SCRIPT_DIR).replace('\\', '/')
                    print(f'  reading: {rel}')
                    parts.append('')
                    parts.append('-' * 78)
                    parts.append('FILE: ' + rel)
                    parts.append('-' * 78)
                    parts.append(read_file(fpath))

    text = '\n'.join(parts)
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write(text)

    print()
    print(f'Done. {len(subfolders)} subfolder(s), {file_count} file(s) dumped.')
    print(f'Output: {OUTPUT_FILE}')


if __name__ == '__main__':
    main()
