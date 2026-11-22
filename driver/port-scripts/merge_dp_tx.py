"""Hand-merge of houji dp_tx.c hunks that did not apply on pandora (popsicle-w-oss).

pandora differences: dp_tx_desc_update_fast_comp_flag -> dp_tx_desc_update_fast_flag,
new dp_tx_desc_update_bcast_flag(), tx_sw_drop_stats_inc() gained an extra argument.
The passthru implementation block is taken verbatim from the .rej file.
"""
import re, sys

root = sys.argv[1]
path = f'{root}/qca-wifi-host-cmn/dp/wifi3.0/dp_tx.c'
rej = open(path + '.rej').read()
s = open(path).read()


def sub1(old, new):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'expected 1 match, got {n}:\n{old}')
    s = s.replace(old, new)


# 1. Raw passthru frames: skip fast-completion, broadcast and mesh flag derivation
#    (bcast_flag would parse the 802.11 frame as an Ethernet header).
sub1('''	dp_tx_desc_update_fast_flag(soc, tx_desc,
				    !pdev->enhanced_stats_en);

	dp_tx_desc_update_bcast_flag(soc, tx_desc, nbuf);

	dp_tx_update_mesh_flags(soc, vdev, tx_desc);
''', '''	if (!dp_tx_desc_is_passthru(tx_desc)) {
		dp_tx_desc_update_fast_flag(soc, tx_desc,
					    !pdev->enhanced_stats_en);

		dp_tx_desc_update_bcast_flag(soc, tx_desc, nbuf);

		dp_tx_update_mesh_flags(soc, vdev, tx_desc);
	}
''')

# 2. success path stats
sub1('''	dp_tx_update_ts_on_enqueued(vdev, msdu_info, tx_desc);

	tx_sw_drop_stats_inc(pdev, nbuf, drop_code, enable_eapol_drop_stats);
	return NULL;
''', '''	dp_tx_update_ts_on_enqueued(vdev, msdu_info, tx_desc);

	if (!dp_tx_vdev_is_passthru(vdev))
		tx_sw_drop_stats_inc(pdev, nbuf, drop_code,
				     enable_eapol_drop_stats);
	return NULL;
''')

# 3. failure path stats
old_fail = '''fail_return:
	dp_tx_get_tid(vdev, nbuf, msdu_info);
	tx_sw_drop_stats_inc(pdev, nbuf, drop_code, enable_eapol_drop_stats);
	tid_stats = &pdev->stats.tid_stats.
		    tid_tx_stats[tx_q->ring_id][tid];
	tid_stats->swdrop_cnt[drop_code]++;
	return nbuf;
}
'''
# 4. passthru implementation block from the rejected hunk ("+" lines from #ifdef DRIVER_PASSTHRU_DP).
lines = rej.splitlines()
start = next(i for i, l in enumerate(lines) if l == '+#ifdef DRIVER_PASSTHRU_DP')
block = []
for l in lines[start:]:
    if not l.startswith('+'):
        break
    block.append(l[1:])
while block and block[-1] == '':
    block.pop()
assert block[-1] == '#endif', block[-3:]
impl = '\n'.join(block) + '\n'
sub1(old_fail, '''fail_return:
	if (!dp_tx_vdev_is_passthru(vdev)) {
		dp_tx_get_tid(vdev, nbuf, msdu_info);
		tx_sw_drop_stats_inc(pdev, nbuf, drop_code,
				     enable_eapol_drop_stats);
	}
	tid_stats = &pdev->stats.tid_stats.
		    tid_tx_stats[tx_q->ring_id][tid];
	tid_stats->swdrop_cnt[drop_code]++;
	return nbuf;
}

''' + impl)

open(path, 'w').write(s)
print(f'dp_tx.c merged, passthru block {len(block)} lines')
