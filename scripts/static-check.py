#!/usr/bin/env python3
"""Offline static checks (no Salesforce org needed). These are heuristics, NOT a substitute for compiling in an org.
Checks: XML/JSON well-formedness, meta files for every class/trigger/lwc, brace balance in Apex, SOQL/DML inside loops
(heuristic), placeholder markers, hard-coded secrets, hard-coded record Ids, and field/object API names used in Apex vs metadata."""
import json, os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'force-app', 'main', 'default')
problems, notes = [], []

def walk(d):
    for r, _, fs in os.walk(d):
        for f in fs:
            yield os.path.join(r, f)

# 1. XML + JSON validity
for p in walk(ROOT):
    if '/.git/' in p or '/dist/' in p or '/node_modules/' in p:
        continue
    if p.endswith('.xml'):
        if subprocess.call(['xmllint', '--noout', p], stderr=subprocess.DEVNULL) != 0:
            problems.append('invalid XML: ' + os.path.relpath(p, ROOT))
    if p.endswith('.json'):
        try:
            json.load(open(p))
        except Exception as e:
            problems.append(f'invalid JSON: {os.path.relpath(p, ROOT)}: {e}')

# 2. meta files
for kind, ext in (('classes', '.cls'), ('triggers', '.trigger')):
    for f in os.listdir(os.path.join(SRC, kind)):
        if f.endswith(ext) and not os.path.exists(os.path.join(SRC, kind, f + '-meta.xml')):
            problems.append('missing meta: ' + f)
for c in os.listdir(os.path.join(SRC, 'lwc')):
    if not os.path.isdir(os.path.join(SRC, 'lwc', c)):
        continue
    if not os.path.exists(os.path.join(SRC, 'lwc', c, c + '.js-meta.xml')):
        problems.append('missing lwc meta: ' + c)

# 3. Apex heuristics
apex_files = [p for k in ('classes', 'triggers') for p in walk(os.path.join(SRC, k)) if p.endswith(('.cls', '.trigger'))]
fields = {}
for obj in os.listdir(os.path.join(SRC, 'objects')):
    d = os.path.join(SRC, 'objects', obj, 'fields')
    fields[obj] = set(f.split('.')[0] for f in os.listdir(d)) if os.path.isdir(d) else set()
all_custom_fields = set().union(*fields.values())
standard_ok = {'Case', 'Account'}
secret_pat = re.compile(r'(api[_-]?key|secret|token|password)\s*[:=]\s*[\'"][A-Za-z0-9_\-]{12,}[\'"]', re.I)
id_pat = re.compile(r"[\'\"](00[0-9A-Za-z]|001|005|500|0Hn)[0-9A-Za-z]{12,15}[\'\"]")
placeholder = re.compile(r'\b(TODO|FIXME|NotImplemented|UnsupportedOperationException|not implemented)\b', re.I)
for p in apex_files:
    rel = os.path.relpath(p, ROOT)
    text = open(p).read()
    no_str = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", text)  # strings first so '//' inside URLs/regexes is not a comment
    code = re.sub(r"//.*", "", no_str)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    stripped = code
    if stripped.count('{') != stripped.count('}'):
        problems.append('brace imbalance: ' + rel)
    if stripped.count('(') != stripped.count(')'):
        problems.append('paren imbalance: ' + rel)
    if placeholder.search(code):
        problems.append('placeholder marker: ' + rel)
    if secret_pat.search(text):
        problems.append('possible hard-coded secret: ' + rel)
    if 'Test' not in os.path.basename(p) and id_pat.search(text):
        problems.append('possible hard-coded Id: ' + rel)
    # SOQL/DML in loops: brace-depth tracking of for/while bodies
    lines = stripped.split('\n')
    depth, loop_stack = 0, []
    for i, line in enumerate(lines, 1):
        l = line.strip()
        if re.match(r'(for|while)\s*\(', l) or re.match(r'\}?\s*(for|while)\s*\(', l):
            loop_stack.append(depth)
        if loop_stack and (re.search(r'\[\s*SELECT\b', l, re.I) or re.search(r'\b(insert|update|delete|upsert)\s+(as\s+\w+\s+)?\w', l) and not l.startswith('//')) and 'Test' not in os.path.basename(p):
            if not re.match(r'(for|while)\s*\(', l) or '[SELECT' not in l.upper():
                notes.append(f'review (SOQL/DML inside loop?) {rel}:{i}: {l[:90]}')
        depth += line.count('{') - line.count('}')
        while loop_stack and depth <= loop_stack[-1] and '}' in line:
            loop_stack.pop()
    # custom field references exist in metadata
    for m in re.finditer(r'\b([A-Za-z][A-Za-z0-9_]*__c)\b', stripped):
        name = m.group(1)
        if name in all_custom_fields or name in {o for o in fields} or name.endswith('__mdt'):
            continue
        problems.append(f'unknown custom field/object {name} in {rel}')

# 3b. reserved identifiers (found by a real deployment: 'commit' and 'end' are rejected by the Apex compiler)
RES = set("""activate asc autonomous begin bigdecimal bulk by collect commit const convertcurrency desc end exit export final from future global goto group having hint inner into join limit loop merge nulls number object of on outer override package parallel pragma retrieve returning rollback savepoint search sort stat switch synchronized system testmethod then transaction type undelete virtual webservice when""".split())
decl = re.compile(r'(?:\b(?:Integer|String|Long|Decimal|Boolean|Id|Object|Datetime|Date|SObject|[A-Z][A-Za-z_.]*(?:<[^>]*>)?)\s+)(%s)\b\s*(?:[=;,)]|:)' % '|'.join(sorted(RES)))
for p in apex_files:
    txt = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", open(p).read())
    txt = re.sub(r"//.*", "", txt)
    for i, l in enumerate(txt.split('\n'), 1):
        m = decl.search(l)
        if m and m.group(1) not in ('delete', 'undelete'):
            problems.append(f'reserved identifier "{m.group(1)}" at {os.path.relpath(p, ROOT)}:{i}')
for p in walk(os.path.join(SRC, 'lwc')):
    if p.endswith('.js') and re.search(r'localStorage|sessionStorage|eval\(|innerHTML', open(p).read()):
        problems.append('risky browser API in ' + os.path.relpath(p, ROOT))

# 4. every Apex class referenced by the permission sets / controller exists
for p in walk(os.path.join(SRC, 'permissionsets')):
    for m in re.finditer(r'<apexClass>(\w+)</apexClass>', open(p).read()):
        if not os.path.exists(os.path.join(SRC, 'classes', m.group(1) + '.cls')):
            problems.append(f'permission set references missing class {m.group(1)}')

print(f'Apex/trigger files checked: {len(apex_files)}')
for n in sorted(set(notes)):
    print('NOTE ', n)
for pr in problems:
    print('FAIL ', pr)
print('RESULT:', 'FAIL' if problems else 'PASS', f'({len(problems)} problems, {len(set(notes))} review notes)')
sys.exit(1 if problems else 0)
