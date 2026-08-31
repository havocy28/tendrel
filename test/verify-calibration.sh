#!/usr/bin/env bash
# Calibration harness for the tendrel:verify design (docs/plans/2026-08-29-2213-feat-verify-command-plan.md).
#
# Not a test. This measures a real graph so the plan's design parameters stop being assertions.
# Two rounds of document review failed partly because every number in that plan was a one-shot hand
# measurement that drifted between drafts. This script replaces them with one re-runnable fact.
#
# It reports COMPETING RULES side by side rather than picking one, because picking is the decision
# the plan has to make and this is the evidence for it:
#   - checked surface        result:-only  vs  whole-node
#   - hedge scope            same-sentence vs  adjacent-token, with and without under/over
#   - seed source            config:/Full record:  vs  + inline body paths
#   - match rule             raw substring vs  boundary-anchored vs  + sci-notation canonicalized
#
# Read-only. Never writes to the graph.
# Usage: bash test/verify-calibration.sh [graph-root]     (default: current directory)
set -uo pipefail
ROOT="${1:-.}"

ROOT="$ROOT" python3 <<'PY'
import os, re, sys, glob

root = os.environ.get("ROOT", ".")
graphdir = os.path.join(root, "graph")
if not os.path.isdir(graphdir):
    print("verify-calibration: no graph/ directory at %s; nothing to measure." % root)
    sys.exit(0)

# ---------------------------------------------------------------- node parsing
FENCE = re.compile(r'^```', re.M)

def split_node(text):
    """Return (frontmatter, body). Mirrors graph-lint's '---' fence convention."""
    if not text.startswith('---\n'):
        return '', text
    end = text.find('\n---\n', 3)
    if end < 0:
        return '', text
    return text[4:end + 1], text[end + len('\n---\n'):]

def result_field(fm):
    """The result: value, including a folded continuation, or '' when absent."""
    m = re.search(r'^result:\s*(.*)$', fm, re.M)
    if not m:
        return ''
    lines = [m.group(1)]
    for line in fm[m.end():].split('\n')[1:]:
        if re.match(r'^\S', line):
            break
        lines.append(line)
    return '\n'.join(lines)

nodes = {}
for path in sorted(glob.glob(os.path.join(graphdir, '*.md'))):
    name = os.path.basename(path)
    try:
        text = open(path, encoding='utf-8').read()
    except OSError:
        continue
    fm, body = split_node(text)
    nodes[name] = {'fm': fm, 'body': body, 'text': text, 'result': result_field(fm)}

# ---------------------------------------------------------------- claim extraction
# KTD4: a claim is a number with >= 2 decimal places.
CLAIM = re.compile(r'(?<![\w.])(\d[\d,]*\.\d{2,})(?![\w.])')
# The looser form the plan's KTD4 exclusion list does NOT currently exclude: numbers glued to an
# identifier (tool versions, parameter tokens, filenames).
CLAIM_LOOSE = re.compile(r'(\d[\d,]*\.\d{2,})')
ONE_DP = re.compile(r'(?<![\w.])(\d[\d,]*\.\d)(?![\d.])')

def claims(s, rx=CLAIM):
    return [m.group(1) for m in rx.finditer(s)]

# ---------------------------------------------------------------- hedge rules
MARKERS_FULL = ['roughly', 'about', 'approximately', 'circa', 'on the order of',
                'nearly', 'under', 'over']
MARKERS_TRIM = ['roughly', 'about', 'approximately', 'circa', 'on the order of', 'nearly']

def sentences(s):
    """Decimal-safe-ish split. Deliberately naive: the point is to show it does not work."""
    return re.split(r'(?<=[.!?])\s+(?=[A-Z])', s)

def hedged_sentence(text, markers):
    """A number is exempt if any marker appears anywhere in its 'sentence'."""
    out = 0
    for sent in sentences(text):
        low = sent.lower()
        hit = any(mk in low for mk in markers) or '~' in sent
        if hit:
            out += len(claims(sent))
    return out

def hedged_adjacent(text, markers):
    """A number is exempt only if a marker is the token immediately before it (or ~ prefixed)."""
    out = 0
    for m in CLAIM.finditer(text):
        pre = text[max(0, m.start() - 24):m.start()]
        if pre.rstrip().endswith('~') or pre.endswith('~'):
            out += 1
            continue
        tail = pre.lower().rstrip()
        if any(tail.endswith(mk) for mk in markers):
            out += 1
    return out

def table_line_claims(text):
    """Numbers on indented / table-shaped lines, which have no sentence boundary."""
    out = 0
    for line in text.split('\n'):
        if re.match(r'^(\s{2,}|\|)', line):
            out += len(claims(line))
    return out

# ---------------------------------------------------------------- seed sources
PATH_RX = re.compile(r'\b((?:scripts|results|work|raw|meta|data|docs)/[\w./-]+)')

def config_paths(fm):
    m = re.search(r'^config:\s*(.*(?:\n\s+.*)*)$', fm, re.M)
    return PATH_RX.findall(m.group(1)) if m else []

def fullrecord_paths(body):
    m = re.search(r'Full record:\s*(.*(?:\n\s+\S.*)?)', body)
    return PATH_RX.findall(m.group(1)) if m else []

def body_paths(body):
    return PATH_RX.findall(body)

def resolves(p):
    return os.path.exists(os.path.join(root, p))

SCRIPT_EXT = ('.py', '.sh', '.R', '.r', '.pl', '.rb')

# ---------------------------------------------------------------- matching rules
def canon_sci(s):
    """Rewrite scientific notation to plain decimal so a claim string can be found."""
    def rep(m):
        try:
            return ('%.12f' % float(m.group(0))).rstrip('0').rstrip('.')
        except ValueError:
            return m.group(0)
    return re.sub(r'\d+\.?\d*[eE][+-]?\d+', rep, s)

def match(claim, blob, anchored=True, sci=True):
    c = claim.replace(',', '')
    hay = blob.replace(',', '')
    if sci:
        hay = hay + '\n' + canon_sci(hay)
    if not anchored:
        return c in hay
    return re.search(r'(?<![\d.])' + re.escape(c) + r'(?![\d])', hay) is not None

ART_CACHE = {}
def read_artifact(p, ceiling=8 * 1024 * 1024):
    if p in ART_CACHE:
        return ART_CACHE[p]
    full = os.path.join(root, p)
    val = None
    try:
        if os.path.isfile(full) and os.path.getsize(full) <= ceiling:
            val = open(full, encoding='utf-8', errors='replace').read()
    except OSError:
        val = None
    ART_CACHE[p] = val
    return val

# ================================================================= measurements
def rule(t):
    print('\n' + t)
    print('-' * len(t))

total_nodes = len(nodes)
whole_claims, result_claims = {}, {}
for name, nd in nodes.items():
    whole_claims[name] = claims(nd['fm'] + '\n' + nd['body'])
    result_claims[name] = claims(nd['result'])

wb = {n for n, c in whole_claims.items() if c}
rb = {n for n, c in result_claims.items() if c}
n_whole = sum(len(c) for c in whole_claims.values())

print('verify-calibration: %s' % os.path.abspath(root))
print('nodes: %d' % total_nodes)

rule('1. CHECKED SURFACE  (KTD3)')
print('  claim-bearing nodes, whole-node rule   : %d' % len(wb))
print('  claim-bearing nodes, result:-only rule : %d' % len(rb))
print('  qualifying numbers, whole node         : %d' % n_whole)
print('  qualifying numbers, result: only       : %d' % sum(len(c) for c in result_claims.values()))
prose_only = sum(1 for n in wb if not result_claims[n])
print('  nodes whose claims are all outside result: %d' % prose_only)
fenced = sum(1 for nd in nodes.values() if FENCE.search(nd['body']))
print('  nodes containing any fenced block      : %d' % fenced)
loose = sum(len(claims(nd['fm'] + nd['body'], CLAIM_LOOSE)) for nd in nodes.values())
print('  identifier-glued numbers (version/param/filename): %d' % (loose - n_whole))

rule('2. HEDGE RULE  (KTD3 escape hatch)')
allt = {n: nd['fm'] + '\n' + nd['body'] for n, nd in nodes.items()}
hs_full = sum(hedged_sentence(t, MARKERS_FULL) for t in allt.values())
hs_trim = sum(hedged_sentence(t, MARKERS_TRIM) for t in allt.values())
ha_full = sum(hedged_adjacent(t, MARKERS_FULL) for t in allt.values())
ha_trim = sum(hedged_adjacent(t, MARKERS_TRIM) for t in allt.values())
tbl = sum(table_line_claims(t) for t in allt.values())
def pct(x): return '%5.1f%%' % (100.0 * x / n_whole) if n_whole else '   n/a'
print('  same-sentence scope, full marker list  : %4d  %s' % (hs_full, pct(hs_full)))
print('  same-sentence scope, no under/over     : %4d  %s' % (hs_trim, pct(hs_trim)))
print('  adjacent-token scope, full marker list : %4d  %s' % (ha_full, pct(ha_full)))
print('  adjacent-token scope, no under/over    : %4d  %s' % (ha_trim, pct(ha_trim)))
print('  --> fail-open gap (sentence - adjacent): %4d  %s' % (hs_full - ha_full, pct(hs_full - ha_full)))
print('  numbers on table/indented lines (no sentence boundary): %d  %s' % (tbl, pct(tbl)))

rule('3. SEED SOURCE  (U5 / OD3)')
seed_cfr, seed_body = {}, {}
for name, nd in nodes.items():
    if name not in wb:
        continue
    a = [p for p in config_paths(nd['fm']) + fullrecord_paths(nd['body']) if resolves(p)]
    b = [p for p in body_paths(nd['body']) if resolves(p)]
    if a: seed_cfr[name] = sorted(set(a))
    if a or b: seed_body[name] = sorted(set(a + b))
n_cfg_key = sum(1 for nd in nodes.values() if re.search(r'^config:', nd['fm'], re.M))
n_cfg_path = sum(1 for nd in nodes.values() if config_paths(nd['fm']))
n_fr = sum(1 for nd in nodes.values() if fullrecord_paths(nd['body']))
print('  nodes carrying a config: key           : %d' % n_cfg_key)
print('  ...whose config: actually names a path : %d' % n_cfg_path)
print('  nodes carrying a "Full record:" path   : %d' % n_fr)
print('  seedable from config:/Full record:     : %d of %d claim-bearing' % (len(seed_cfr), len(wb)))
print('  seedable incl. inline body paths       : %d of %d claim-bearing' % (len(seed_body), len(wb)))
print('  --> residual backlog, narrow source    : %d' % (len(wb) - len(seed_cfr)))
print('  --> residual backlog, wide source      : %d' % (len(wb) - len(seed_body)))

rule('4. MATCH RATE AFTER SEEDING  (KTD6 / KTD7 / reachability of strict)')
for label, src in (('narrow (config:/Full record:)', seed_cfr), ('wide (+ body paths)', seed_body)):
    for skip_scripts in (True, False):
        tot = un = 0
        clean_nodes = 0
        for name, paths in src.items():
            searched = [p for p in paths
                        if not (skip_scripts and p.endswith(SCRIPT_EXT))]
            blob = '\n'.join(filter(None, (read_artifact(p) for p in searched)))
            hedge_ex = hedged_adjacent(allt[name], MARKERS_TRIM)
            cl = whole_claims[name]
            node_un = sum(1 for c in cl if not match(c, blob))
            node_un = max(0, node_un - hedge_ex)
            tot += len(cl); un += node_un
            if node_un == 0:
                clean_nodes += 1
        r = ('%5.1f%%' % (100.0 * un / tot)) if tot else '   n/a'
        print('  %-30s scripts %-7s unmatched %4d/%-4d %s   clean nodes %d/%d'
              % (label, 'skipped' if skip_scripts else 'searched', un, tot, r, clean_nodes, len(src)))

rule('5. MATCH RULE SENSITIVITY  (KTD6)')
sample = [(n, c) for n, cs in whole_claims.items() for c in cs]
for anchored, sci, lab in ((False, False, 'raw substring          '),
                           (True,  False, 'boundary-anchored      '),
                           (True,  True,  'anchored + sci-notation')):
    hit = 0
    for name, c in sample:
        paths = seed_body.get(name, [])
        blob = '\n'.join(filter(None, (read_artifact(p) for p in paths)))
        if blob and match(c, blob, anchored=anchored, sci=sci):
            hit += 1
    print('  %s  matched %d/%d' % (lab, hit, len(sample)))

rule('6. ONE-DECIMAL PRESSURE  (KTD4 threshold)')
od_whole = sum(len(ONE_DP.findall(nd['fm'] + '\n' + nd['body'])) for nd in nodes.values())
od_result = sum(len(ONE_DP.findall(nd['result'])) for nd in nodes.values())
od_nodes = sum(1 for nd in nodes.values() if ONE_DP.search(nd['fm'] + '\n' + nd['body']))
print('  one-decimal numbers, whole node        : %d across %d nodes' % (od_whole, od_nodes))
print('  one-decimal numbers, result: only      : %d' % od_result)

rule('7. BACKLOG DEFINITIONS AND OVERLAP  (U3 calibration)')
declared = {n for n, nd in nodes.items() if re.search(r'^provenance:', nd['fm'], re.M)}
verify_backlog = wb - declared
crude = {n for n in wb if not [p for p in body_paths(nodes[n]['body']) + config_paths(nodes[n]['fm'])
                               if resolves(p)]}
print('  nodes declaring provenance:            : %d' % len(declared))
print('  A. verify backlog (claims, no provenance:) : %d' % len(verify_backlog))
print('  B. crude scan (claims, no resolving path)  : %d' % len(crude))
print('  overlap |A n B|                            : %d' % len(verify_backlog & crude))
print('  --> comparing |A| to |B| is only meaningful when the overlap is near the smaller set.')

rule('8. ARTIFACT CORPUS  (KTD6 denominators)')
arts, sci_n = 0, 0
for base in ('results', 'work', 'meta'):
    for dp, _, fns in os.walk(os.path.join(root, base)):
        for fn in fns:
            p = os.path.join(dp, fn)
            try:
                if os.path.getsize(p) > 8 * 1024 * 1024:
                    continue
                s = open(p, encoding='utf-8', errors='strict').read()
            except (OSError, UnicodeDecodeError):
                continue
            arts += 1
            if re.search(r'\d\.?\d*[eE][+-]\d', s):
                sci_n += 1
print('  readable text artifacts                : %d' % arts)
print('  ...using scientific notation           : %d' % sci_n)
print()
PY
