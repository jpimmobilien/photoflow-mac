#!/usr/bin/env python3
"""Extracts localization keys from the Swift sources (String(localized:), Text("…") literals,
LocalizationValue literals for presets/workflows) and checks that every key has a German translation.
Interpolations are converted to format specifiers using a type map (see TYPE_HINTS)."""
import re, sys, os, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'Sources', 'PhotoFlow')

def swift_string_literals(text, start):
    """Parse a Swift string literal starting at text[start] == '"'. Returns (content, end_index)."""
    assert text[start] == '"'
    i = start + 1; out = []; depth = 0
    while i < len(text):
        c = text[i]
        if c == '\\' and i + 1 < len(text) and text[i+1] == '(':
            # interpolation: capture balanced parens
            j = i + 2; d = 1
            while d:
                if text[j] == '(': d += 1
                elif text[j] == ')': d -= 1
                elif text[j] == '"':
                    # nested string inside interpolation
                    _, j = swift_string_literals(text, j); continue
                j += 1
            out.append('\\(' + text[i+2:j-1] + ')'); i = j; continue
        if c == '\\':
            out.append(text[i:i+2]); i += 2; continue
        if c == '"':
            return ''.join(out), i + 1
        out.append(c); i += 1
    raise ValueError('unterminated')

PATTERNS = [r'String\(localized:\s*', r'(?<![A-Za-z.])Text\(', r'LocalizationValue\]\s*=\s*\[', r'Text\(verbatim:']

def keys_from(text):
    found = []
    for m in re.finditer(r'String\(localized:\s*"', text):
        s, _ = swift_string_literals(text, m.end() - 1); found.append(s)
    for m in re.finditer(r'(?<![A-Za-z.])Text\("', text):
        s, _ = swift_string_literals(text, m.end() - 1); found.append(s)
    # preset name keys array
    m = re.search(r'_presetNameKeys: \[String\.LocalizationValue\] = \[(.*?)\]', text, re.S)
    if m:
        found += re.findall(r'"([^"]+)"', m.group(1))
    # workflow names/summaries
    for m in re.finditer(r'BatchWorkflow\(id: "[^"]+", name: "([^"]+)", symbol: "[^"]+",\s*summary: "([^"]+)"', text, re.S):
        found += [m.group(1), m.group(2)]
    return found

TYPE_HINTS_FILE = os.path.join(ROOT, 'Scripts', 'interpolation_types.json')

def to_key(s, hints):
    def rep(m):
        expr = m.group(1)
        t = hints.get(expr)
        if t is None:
            raise KeyError(expr)
        return {'int': '%lld', 'string': '%@'}[t]
    return re.sub(r'\\\((.*?)\)(?=[^)]*?(?:\\\(|$))', rep, s) if False else interp_replace(s, hints)

def interp_replace(s, hints):
    # Swift's LocalizationValue / LocalizedStringKey interpolation escapes literal "%" as "%%"
    # (only when the literal contains at least one interpolation).
    has_interp = '\\(' in s
    out = []; i = 0
    while i < len(s):
        if s.startswith('\\(', i):
            j = i + 2; d = 1
            while d:
                if s[j] == '(': d += 1
                elif s[j] == ')': d -= 1
                j += 1
            expr = s[i+2:j-1]
            t = hints.get(expr)
            if t is None: raise KeyError(expr)
            out.append({'int': '%lld', 'string': '%@'}[t]); i = j
        else:
            out.append('%%' if (has_interp and s[i] == '%') else s[i]); i += 1
    return ''.join(out)

def main():
    all_keys = {}
    for dp, _, fs in os.walk(SRC):
        for f in fs:
            if f.endswith('.swift'):
                p = os.path.join(dp, f)
                for k in keys_from(open(p, encoding='utf-8').read()):
                    all_keys.setdefault(k, set()).add(os.path.relpath(p, SRC))
    hints = json.load(open(TYPE_HINTS_FILE)) if os.path.exists(TYPE_HINTS_FILE) else {}
    missing_hints = sorted({e for k in all_keys for e in re.findall(r'\\\((.*?)\)(?![^(]*\))', k) if e not in hints})
    if '--interpolations' in sys.argv:
        exprs = set()
        for k in all_keys:
            i = 0
            while True:
                i = k.find('\\(', i)
                if i < 0: break
                j = i + 2; d = 1
                while d:
                    if k[j] == '(': d += 1
                    elif k[j] == ')': d -= 1
                    j += 1
                exprs.add(k[i+2:j-1]); i = j
        for e in sorted(exprs): print(json.dumps(e), ':', json.dumps(hints.get(e)))
        return
    keys = {}
    for k, files in all_keys.items():
        keys[interp_replace(k, hints)] = files
    # unescape Swift escapes to the .strings form (\" stays escaped, \n stays)
    if '--list' in sys.argv:
        for k in sorted(keys): print(k)
        return
    de_path = os.path.join(ROOT, 'Resources', 'de.lproj', 'Localizable.strings')
    de = parse_strings(open(de_path, encoding='utf-8').read()) if os.path.exists(de_path) else {}
    missing = [k for k in sorted(keys) if k not in de]
    unused = [k for k in de if k not in keys]
    print(f'{len(keys)} keys, {len(de)} German translations, {len(missing)} missing, {len(unused)} unused')
    for k in missing: print('MISSING:', k)
    for k in unused: print('UNUSED:', k)
    # format specifier consistency
    bad = [k for k in keys if k in de and sorted(re.findall(r'%(?:lld|@)', k)) != sorted(re.sub(r'%\d\$', '%', x) for x in re.findall(r'%(?:\d\$)?(?:lld|@)', de[k]))]
    for k in bad: print('SPECIFIER MISMATCH:', k, '=>', de[k])
    if '--write-en' in sys.argv:
        en_path = os.path.join(ROOT, 'Resources', 'en.lproj', 'Localizable.strings')
        os.makedirs(os.path.dirname(en_path), exist_ok=True)
        with open(en_path, 'w', encoding='utf-8') as f:
            f.write('/* PhotoFlow – English (development language). Generated by Scripts/extract_strings.py */\n\n')
            for k in sorted(keys):
                f.write(f'"{k}" = "{k}";\n')
    sys.exit(1 if (missing or bad) else 0)

def parse_strings(text):
    d = {}
    for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text, re.M):
        d[m.group(1)] = m.group(2)
    return d

if __name__ == '__main__':
    main()
