#!/usr/bin/env bash
# Calibration report for a tendrel research graph. Read-only: it never writes to graph/ or anywhere.
#
# Not a lint and not a test. It measures how checkable the numbers in a graph are against the
# artifacts they cite, so the question "would a number-verifying gate be trustworthy on THIS
# graph?" is answered by a re-runnable fact instead of a hand measurement. It reports competing
# rules side by side rather than picking one, because picking is the decision the evidence is for:
#   - checked surface        result:-only  vs  whole-node
#   - hedge scope            same-sentence vs  adjacent-token, with and without under/over
#   - seed source            config:/Full record:  vs  + inline body paths
#   - match rule             raw substring vs  boundary-anchored vs  + sci-notation canonicalized
# Section 10 is the one to read first: how often a node's numbers pass against an artifact that
# did NOT produce them. On the graph this was calibrated against, 40.9% of two-decimal claims
# did, which is why tendrel checks that provenance resolves and does not check the numbers.
#
# Section numbers are stable and cited elsewhere; add new sections at the end.
# Usage: bash graph-calibrate.sh [repo-dir]     (default: current directory)
set -uo pipefail
ROOT="${1:-.}"

ROOT="$ROOT" python3 <<'PY'
import os, re, sys, glob

root = os.environ.get("ROOT", ".")
graphdir = os.path.join(root, "graph")
if not os.path.isdir(graphdir):
    print("graph-calibrate: no graph/ directory at %s; nothing to measure." % root)
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

def provenance_paths(fm):
    """Paths declared under the `provenance:` key, the same three forms graph-lint reads (inline
    list, block list, bare scalar). Declared paths are not filtered by PATH_RX: the point of the
    key is that the author named the artifact, wherever it lives."""
    paths, lines = [], fm.split('\n')
    def clean(x):
        return re.sub(r'\s+#.*$', '', x).strip().strip('"\'')
    for i, ln in enumerate(lines):
        m = re.match(r'^provenance\s*:\s*(.*)$', ln)
        if not m:
            continue
        val = m.group(1).strip()
        if val.startswith('['):
            end = val.rfind(']')
            paths += [clean(x) for x in val[1:end if end >= 0 else None].split(',') if clean(x)]
        elif val:
            v = clean(val)
            if v and v not in ('null', '~'):
                paths.append(v)
        else:
            for nxt in lines[i + 1:]:
                if re.match(r'^\S', nxt):
                    break
                mm = re.match(r'^\s*-\s*(.+?)\s*$', nxt)
                if mm and clean(mm.group(1)):
                    paths.append(clean(mm.group(1)))
        break
    return paths

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

print('graph-calibrate: %s' % os.path.abspath(root))
print('nodes: %d' % total_nodes)

rule('1. CHECKED SURFACE  (which text is scanned for numbers)')
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

rule('2. HEDGE RULE  (when a stated number counts as approximate)')
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

rule('3. SEED SOURCE  (where a node\'s artifact paths are read from)')
seed_cfr, seed_body = {}, {}
for name, nd in nodes.items():
    if name not in wb:
        continue
    a = [p for p in provenance_paths(nd['fm']) + config_paths(nd['fm']) + fullrecord_paths(nd['body'])
         if resolves(p)]
    b = [p for p in body_paths(nd['body']) if resolves(p)]
    if a: seed_cfr[name] = sorted(set(a))
    if a or b: seed_body[name] = sorted(set(a + b))
n_cfg_key = sum(1 for nd in nodes.values() if re.search(r'^config:', nd['fm'], re.M))
n_cfg_path = sum(1 for nd in nodes.values() if config_paths(nd['fm']))
n_fr = sum(1 for nd in nodes.values() if fullrecord_paths(nd['body']))
n_prov = sum(1 for nd in nodes.values() if provenance_paths(nd['fm']))
print('  nodes declaring provenance: paths      : %d' % n_prov)
print('  nodes carrying a config: key           : %d' % n_cfg_key)
print('  ...whose config: actually names a path : %d' % n_cfg_path)
print('  nodes carrying a "Full record:" path   : %d' % n_fr)
print('  seedable from provenance:/config:/Full record: : %d of %d claim-bearing' % (len(seed_cfr), len(wb)))
print('  seedable incl. inline body paths       : %d of %d claim-bearing' % (len(seed_body), len(wb)))
print('  --> residual backlog, narrow source    : %d' % (len(wb) - len(seed_cfr)))
print('  --> residual backlog, wide source      : %d' % (len(wb) - len(seed_body)))

rule('4. MATCH RATE AFTER SEEDING  (numbers found in their cited artifacts)')
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

rule('5. MATCH RULE SENSITIVITY  (substring vs anchored vs canonicalized)')
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

rule('6. ONE-DECIMAL PRESSURE  (what a looser precision threshold would add)')
od_whole = sum(len(ONE_DP.findall(nd['fm'] + '\n' + nd['body'])) for nd in nodes.values())
od_result = sum(len(ONE_DP.findall(nd['result'])) for nd in nodes.values())
od_nodes = sum(1 for nd in nodes.values() if ONE_DP.search(nd['fm'] + '\n' + nd['body']))
print('  one-decimal numbers, whole node        : %d across %d nodes' % (od_whole, od_nodes))
print('  one-decimal numbers, result: only      : %d' % od_result)

rule('7. BACKLOG DEFINITIONS AND OVERLAP  (nodes with numbers but no provenance)')
declared = {n for n, nd in nodes.items() if re.search(r'^provenance\s*:', nd['fm'], re.M)}
verify_backlog = wb - declared
crude = {n for n in wb if not [p for p in body_paths(nodes[n]['body']) + config_paths(nodes[n]['fm'])
                               + provenance_paths(nodes[n]['fm']) if resolves(p)]}
print('  nodes declaring provenance:            : %d' % len(declared))
print('  A. verify backlog (claims, no provenance:) : %d' % len(verify_backlog))
print('  B. crude scan (claims, no resolving path)  : %d' % len(crude))
print('  overlap |A n B|                            : %d' % len(verify_backlog & crude))
print('  --> comparing |A| to |B| is only meaningful when the overlap is near the smaller set.')

rule('8. ARTIFACT CORPUS  (readable artifacts under results/, work/, meta/)')
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
rule('9. UNMATCHED RESIDUE  (numbers not found in their artifacts, and why)')
# Every unmatched claim under the best measured settings (wide seed source, scripts searched,
# adjacent-token hedging, anchored + sci matching) is classified mechanically. The buckets decide
# whether R3 is fixable by better matching, by better declaration, or not at all.

# Index every qualifying number appearing anywhere in the repo's text artifacts, once.
repo_index = {}
for base in ('results', 'work', 'meta', 'scripts', 'raw'):
    bd = os.path.join(root, base)
    if not os.path.isdir(bd):
        continue
    for dp, _, fns in os.walk(bd):
        for fn in fns:
            p = os.path.join(dp, fn)
            try:
                if os.path.getsize(p) > 8 * 1024 * 1024:
                    continue
                s = open(p, encoding='utf-8', errors='strict').read()
            except (OSError, UnicodeDecodeError):
                continue
            s = s + '\n' + canon_sci(s)
            for c in set(claims(s)):
                repo_index.setdefault(c.replace(',', ''), set()).add(
                    os.path.relpath(p, root))

NUM_ANY = re.compile(r'(?<![\w.])(\d[\d,]*\.\d+)(?![\w.])')

def rounds_to(blob, claim):
    """Does any number in blob round to claim at the claim's own precision?"""
    if '.' not in claim:
        return False
    k = len(claim.split('.')[1])
    try:
        target = float(claim.replace(',', ''))
    except ValueError:
        return False
    for m in NUM_ANY.finditer(blob):
        tok = m.group(1).replace(',', '')
        if len(tok.split('.')[1]) <= k:
            continue
        try:
            if abs(round(float(tok), k) - target) < 10 ** -(k + 3):
                return True
        except ValueError:
            continue
    return False

ATTRIB = ['first read', 'originally', 'previously', 'superseded', 'corrected',
          'the original', 'earlier', 'retracted', 'was reported', 'pre-registered',
          'must not be restated', 'instead of']

def on_table_line(text, claim):
    for line in text.split('\n'):
        if re.match(r'^(\s{2,}|\|)', line) and claim in line:
            return True
    return False

def attributed(text, claim):
    for sent in sentences(text):
        if claim in sent and any(a in sent.lower() for a in ATTRIB):
            return True
    return False

buckets = {'rounding-recoverable': 0, 'declared-wrong': 0, 'nowhere-in-repo': 0}
spread = {'1-3 candidate files (real missing declaration)': 0,
          '4-10 candidate files': 0,
          '>10 candidate files (likely coincidental)': 0}
cross = {'on-table-line': 0, 'attributed': 0}
residue_total = 0
for name, paths in seed_body.items():
    searched = paths
    blob = '\n'.join(filter(None, (read_artifact(p) for p in searched)))
    txt = allt[name]
    hedged = set()
    for m in CLAIM.finditer(txt):
        pre = txt[max(0, m.start() - 24):m.start()]
        tail = pre.lower().rstrip()
        if pre.endswith('~') or any(tail.endswith(mk) for mk in MARKERS_TRIM):
            hedged.add(m.start())
    for m in CLAIM.finditer(txt):
        if m.start() in hedged:
            continue
        c = m.group(1)
        if match(c, blob):
            continue
        residue_total += 1
        key = c.replace(',', '')
        if rounds_to(blob, c):
            buckets['rounding-recoverable'] += 1
        elif key in repo_index:
            buckets['declared-wrong'] += 1
            nc = len(repo_index[key])
            if nc <= 3:
                spread['1-3 candidate files (real missing declaration)'] += 1
            elif nc <= 10:
                spread['4-10 candidate files'] += 1
            else:
                spread['>10 candidate files (likely coincidental)'] += 1
        else:
            buckets['nowhere-in-repo'] += 1
        if on_table_line(txt, c):
            cross['on-table-line'] += 1
        if attributed(txt, c):
            cross['attributed'] += 1

def share(x):
    return '%5.1f%%' % (100.0 * x / residue_total) if residue_total else '   n/a'

print('  unmatched claims at best settings      : %d' % residue_total)
print()
print('  MUTUALLY EXCLUSIVE -- what would fix each:')
print('    rounding-recoverable (precision-aware match) : %4d  %s'
      % (buckets['rounding-recoverable'], share(buckets['rounding-recoverable'])))
print('    declared-wrong (number IS elsewhere in repo) : %4d  %s'
      % (buckets['declared-wrong'], share(buckets['declared-wrong'])))
print('    nowhere-in-repo (derived or external)        : %4d  %s'
      % (buckets['nowhere-in-repo'], share(buckets['nowhere-in-repo'])))
print()
print('  declared-wrong, by how many repo files hold that number:')
for k in ('1-3 candidate files (real missing declaration)', '4-10 candidate files',
          '>10 candidate files (likely coincidental)'):
    print('    %-44s : %4d  %s' % (k, spread[k], share(spread[k])))
print()
print('  OVERLAPPING CONTEXT -- why the number is there:')
print('    on a table/indented line                     : %4d  %s'
      % (cross['on-table-line'], share(cross['on-table-line'])))
print('    in an attribution/supersession sentence      : %4d  %s'
      % (cross['attributed'], share(cross['attributed'])))
print()
print('  --> rounding-recoverable is fixable by precision-aware matching alone.')
print('  --> declared-wrong is fixable by declaration or wider seeding.')
print('  --> nowhere-in-repo is what no artifact check can reach.')

rule('10. MATCHING PRECISION -- null test  (passes against artifacts that did NOT produce the claim)')
# The question a raw match rate cannot answer: how often does a claim pass against an artifact that
# did NOT produce it? Each node's claims are tested against ANOTHER node's declared artifacts.
names = sorted(seed_body)
byprec = {}
tot_ex = tot_rd = tot_n = 0
for i, name in enumerate(names):
    other = names[(i + 1) % len(names)] if len(names) > 1 else None
    if other is None or other == name:
        continue
    blob = '\n'.join(filter(None, (read_artifact(p) for p in seed_body[other])))
    if not blob:
        continue
    for c in whole_claims[name]:
        k = len(c.split('.')[1]) if '.' in c else 0
        key = '2dp' if k == 2 else ('3dp' if k == 3 else '4dp+')
        d = byprec.setdefault(key, [0, 0, 0])
        d[2] += 1; tot_n += 1
        if match(c, blob):
            d[0] += 1; tot_ex += 1
        elif rounds_to(blob, c):
            d[1] += 1; tot_rd += 1

def rate(x, n):
    return '%5.1f%%' % (100.0 * x / n) if n else '   n/a'

print('  claims tested against a NON-producing artifact : %d' % tot_n)
print('    pass under exact matching                    : %4d  %s' % (tot_ex, rate(tot_ex, tot_n)))
print('    additional pass under precision-aware        : %4d  %s' % (tot_rd, rate(tot_rd, tot_n)))
print('    combined coincidental pass rate              : %4d  %s'
      % (tot_ex + tot_rd, rate(tot_ex + tot_rd, tot_n)))
print()
print('  by claim precision (exact / +rounding / total):')
for k in ('2dp', '3dp', '4dp+'):
    if k in byprec:
        ex, rd, nn = byprec[k]
        print('    %-5s  %3d %s   %3d %s   of %d'
              % (k, ex, rate(ex, nn), rd, rate(rd, nn), nn))
print()
print('  --> a rounding match that clears a claim carries little provenance information.')

rule('11. SUGGESTION PRECISION  (would naming the file holding a number name the right file)')
# For claims whose true source is known (they match exactly in one of the node's own declared
# artifacts), would the candidate suggestion have named that artifact? Precision is measured at
# each cap: fraction of NAMED files that are actually a true source.
for cap in (1, 2, 3, 5):
    fired = named = correct = 0
    for name, paths in seed_body.items():
        truth = set()
        for p in paths:
            b = read_artifact(p)
            if b:
                for c in whole_claims[name]:
                    if match(c, b):
                        truth.add((c, p))
        for c in whole_claims[name]:
            tset = {p for (cc, p) in truth if cc == c}
            if not tset:
                continue
            cands = sorted(repo_index.get(c.replace(',', ''), set()))
            if not cands or len(cands) > cap:
                continue
            fired += 1
            named += len(cands)
            correct += sum(1 for p in cands if p in tset)
    print('  cap %d: fires on %4d claims, names %4d files, %4d are a true source  -> precision %s'
          % (cap, fired, named, correct, rate(correct, named)))
print()
print('  --> precision collapses at the first step past a unique holder, not at high fan-out.')

print()
PY
