"""Add [PM_PASSTHRU_MODE] entries to pandora's policy-manager PCL tables where houji's hunks did not apply.

For each row lacking PM_PASSTHRU_MODE: use houji's value for the same (table kind, row name);
pandora-only rows get {PM_MAX_PCL_TYPE x3} (no channel preference).
usage: fill_pm_tables.py <houji_file> <pandora_file>
"""
import re, sys

# Row keys are connection states (PM_STA_24_1x1 ...); inner keys are modes (PM_..._MODE).
ROW = re.compile(r'^\t\[(PM_\w+?)\] = \{\s*$')


def _is_row(m):
    return m is not None and not m.group(1).endswith('_MODE')
TBL = re.compile(r'^static pm_dbs_pcl_(second|third)_connection_table_type')


def houji_values(path):
    vals, kind, row, buf = {}, None, None, None
    for line in open(path).read().split('\n'):
        m = TBL.match(line)
        if m:
            kind = (kind[0] + 1 if kind else 0, m.group(1))
        m = ROW.match(line)
        if _is_row(m):
            row = m.group(1)
        if '[PM_PASSTHRU_MODE]' in line:
            buf = [line]
        elif buf is not None:
            buf.append(line)
        if buf is not None and '}' in buf[-1]:
            vals[(kind, row)] = '\n'.join(buf)
            buf = None
    return vals


hv = houji_values(sys.argv[1])
lines = open(sys.argv[2]).read().split('\n')
out, kind, row, has_pt = [], None, None, False
added = {'houji': 0, 'default': 0}
default = '\t[PM_PASSTHRU_MODE] = {PM_MAX_PCL_TYPE, PM_MAX_PCL_TYPE,\n\t\t\t      PM_MAX_PCL_TYPE},'


def entry():
    v = hv.get((kind, row))
    added['houji' if v else 'default'] += 1
    return v or default


for line in lines:
    m = TBL.match(line)
    if m:
        kind = (kind[0] + 1 if kind else 0, m.group(1))
    m = ROW.match(line)
    if _is_row(m):
        row, has_pt = m.group(1), False
        out.append(line)
        continue
    if row and '[PM_PASSTHRU_MODE]' in line:
        has_pt = True
    if row and line.rstrip().endswith('} },'):
        if has_pt:
            out.append(line)
        else:
            out.append(line.rstrip()[:-len(' },')] + ',')
            out.append(entry())
            out.append('},')
        row = None
        continue
    if row and line.strip() == '},' and not line.startswith('\t'):
        if not has_pt:
            out.append(entry())
        out.append(line)
        row = None
        continue
    out.append(line)

open(sys.argv[2], 'w').write('\n'.join(out))
print('added', added)
