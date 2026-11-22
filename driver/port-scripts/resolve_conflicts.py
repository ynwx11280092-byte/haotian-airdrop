"""Resolve diff3 conflicts (pandora | base | houji) from git merge-file, per an explicit spec.

Modes per conflict index (1-based, per file):
  p   pandora side
  u   pandora + houji
  a   pandora + lines houji *inserted* relative to base (aborts if houji deleted/replaced base lines)
  ('text', s)    literal replacement
  ('fn', f)      f(pandora_lines, base_lines, houji_lines) -> lines
Every conflict in a listed file must have a spec entry; unlisted conflicted files abort.
usage: resolve_conflicts.py <wlan root>
"""
import difflib, sys

root = sys.argv[1]


def houji_inserts(base, houji):
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, base, houji, autojunk=False).get_opcodes():
        if op == 'insert':
            out += houji[j1:j2]
        elif op in ('delete', 'replace'):
            raise ValueError(f'houji {op}s base lines:\n' + '\n'.join(base[i1:i2][:8]))
    return out


T = lambda s: ('text', s)


def drop_last(n):
    return lambda p, b, h: p[:-n] if n else p


SPEC = {
    'qcacld-3.0/Kconfig': {1: T('config DRIVER_PASSTHRU_SESSION\n\tbool "PASSTHRU control-session candidate"\n\tdefault n\n\thelp\n\t  Build isolated control-session support. No HDD/DP/provider backend.\n')},
    'qcacld-3.0/core/mac/inc/wni_api.h': {1: ('fn', lambda p, b, h: p + [
        '#ifdef DRIVER_PASSTHRU_SESSION',
        '\teWNI_SME_PASSTHRU_INIT_SESSION = SIR_SME_MSG_TYPES_BEGIN + 187,',
        '\teWNI_SME_PASSTHRU_DEINIT_SESSION = SIR_SME_MSG_TYPES_BEGIN + 188,',
        '\teWNI_SME_PASSTHRU_EVENT = SIR_SME_MSG_TYPES_BEGIN + 189,',
        '#endif',
        '#ifdef DRIVER_PASSTHRU_OWNER',
        '\teWNI_SME_PASSTHRU_CREATE_REQUEST = SIR_SME_MSG_TYPES_BEGIN + 190,',
        '\teWNI_SME_PASSTHRU_DELETE_REQUEST = SIR_SME_MSG_TYPES_BEGIN + 191,',
        '#endif'])},
    'qcacld-3.0/core/sme/inc/sme_api.h': {1: 'u'},
    'qcacld-3.0/core/sme/inc/sme_internal.h': {1: 'u'},
    'qcacld-3.0/core/wma/inc/wma_api.h': {1: 'u'},
    'qca-wifi-host-cmn/umac/mlme/include/wlan_vdev_mlme.h': {1: 'p'},
    'qca-wifi-host-cmn/dp/inc/cdp_txrx_ops.h': {1: 'u'},
    'qcacld-3.0/components/umac/mlme/connection_mgr/dispatcher/inc/wlan_cm_roam_public_struct.h':
        {1: ('fn', lambda p, b, h: p + ['\tRSO_PASSTHRU_SET_CHANNEL = BIT(7),'])},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_tx.h': {1: 'u'},
    'qca-wifi-host-cmn/hal/wifi3.0/hal_internal.h': {1: 'u'},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_types.h': {1: 'u', 2: 'u', 3: 'u'},
    'qcacld-3.0/core/wma/src/wma_utils.c': {1: 'a'},
    'qcacld-3.0/core/sme/src/common/sme_api.c': {1: 'a'},
    'qcacld-3.0/core/mac/src/pe/lim/lim_utils.c': {1: 'a'},
    'qca-wifi-host-cmn/umac/mlme/vdev_mgr/core/src/vdev_mlme_sm.c': {1: 'p', 2: 'p'},
    'qca-wifi-host-cmn/umac/mlme/vdev_mgr/core/src/vdev_mgr_ops.c': {1: 'u'},
    'qca-wifi-host-cmn/wmi/src/wmi_unified_tlv.c': {1: 'p'},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_tx.c': {
        1: T('\tif (!dp_tx_vdev_is_passthru(vdev) &&\n\t    qdf_unlikely(nbuf->protocol == QDF_NBUF_TRAC_EAPOL_ETH_TYPE))'),
        # raw 802.11 passthru frames: skip fast/bcast/mesh flag derivation (bcast parses Ethernet)
        2: T('\tif (!dp_tx_desc_is_passthru(tx_desc)) {\n\t\tdp_tx_desc_update_fast_flag(soc, tx_desc,\n\t\t\t\t\t    !pdev->enhanced_stats_en);\n\n\t\tdp_tx_desc_update_bcast_flag(soc, tx_desc, nbuf);\n\n\t\tdp_tx_update_mesh_flags(soc, vdev, tx_desc);\n\t}'),
        3: T('\tif (!dp_tx_vdev_is_passthru(vdev))\n\t\ttx_sw_drop_stats_inc(pdev, nbuf, drop_code,\n\t\t\t\t     enable_eapol_drop_stats);'),
        4: T('\tif (!dp_tx_vdev_is_passthru(vdev)) {\n\t\tdp_tx_get_tid(vdev, nbuf, msdu_info);\n\t\ttx_sw_drop_stats_inc(pdev, nbuf, drop_code,\n\t\t\t\t     enable_eapol_drop_stats);\n\t}'),
        5: 'u'},
    'qca-wifi-host-cmn/dp/wifi3.0/be/dp_be_tx.c': {1: 'p', 2: 'p', 3: 'p', 4: 'p', 5: 'p'},  # re-done by hand
    'qca-wifi-host-cmn/dp/wifi3.0/dp_main.c': {
        1: 'u',
        # houji's passthru register/managed functions, then pandora's (changed) dp_vdev_register_wifi3 header
        2: ('fn', lambda p, b, h: h[:-4] + p),
        # receipt end after both pandora delete callbacks
        3: T('#ifdef DRIVER_PASSTHRU_OWNER\n\t/* Not detach acceptance or ID removal: memory and both callbacks done.\n\t * No later soc access; outer teardown still joins ref-put caller tails.\n\t */\n\tif (receipt_owed)\n\t\tdp_passthru_receipts_end(&soc->passthru_receipts);\n#endif')},
    'qcacld-3.0/core/wma/src/wma_dev_if.c': {
        1: T('\tdetach_status = wma_cdp_vdev_detach(soc, wma_handle, vdev_id);\n\tif (wma_is_passthru_vdev(iface->vdev) &&\n\t    QDF_IS_STATUS_ERROR(detach_status))\n\t\treturn detach_status;'),
        2: ('fn', lambda p, b, h: p[:-2] + h[:-2] + p[-2:]),
        3: 'p'},
    'qcacld-3.0/components/dp/core/src/wlan_dp_softap_txrx.c': {1: 'p', 2: 'p'},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_rx.c': {1: ('fn', lambda p, b, h: p + ['#include <linux/moduleparam.h>']), 2: 'u'},
    'qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_get_set_utils.c': {1: 'u', 2: 'a'},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_tx_flow_control.c': {
        1: ('fn', lambda p, b, h: [l for l in p if l.strip() != 'vdev->pool = pool;'])},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_rx_err.c': {1: 'a'},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_rx_buffer_pool.c': {
        1: ('fn', lambda p, b, h: [l.replace('qdf_nbuf_map_nbytes_single(', 'dp_rx_map_buffer(') for l in p])},
    'qca-wifi-host-cmn/dp/wifi3.0/dp_peer.c': {1: 'u'},
    'qca-wifi-host-cmn/dp/wifi3.0/be/dp_be_rx.c': {1: 'a'},
    'qcacld-3.0/core/hdd/src/wlan_hdd_sysfs.c': {1: 'p'},
    'qcacld-3.0/core/hdd/src/wlan_hdd_main.c': {1: ('fn', lambda p, b, h: p[:-1] + h)},
    'qcacld-3.0/core/hdd/src/wlan_hdd_driver_ops.c': {1: ('fn', lambda p, b, h: p[:-1] + h)},
    'qcacld-3.0/core/hdd/src/wlan_hdd_cfg80211.c': {1: 'p'},
    'qcacld-3.0/components/dp/core/src/wlan_dp_txrx.c': {1: 'p'},
}

total = 0
for rel, spec in SPEC.items():
    path = f'{root}/{rel}'
    L = open(path).read().split('\n')
    out, i, k = [], 0, 0
    while i < len(L):
        if not L[i].startswith('<<<<<<< pandora'):
            out.append(L[i]); i += 1; continue
        k += 1
        j = i
        while not L[j].startswith('||||||| base'): j += 1
        m = j
        while L[m] != '=======': m += 1
        e = m
        while not L[e].startswith('>>>>>>> houji'): e += 1
        p, b, h = L[i + 1:j], L[j + 1:m], L[m + 1:e]
        mode = spec.get(k)
        if mode is None:
            raise SystemExit(f'{rel}: no spec for conflict #{k}')
        if mode == 'p':
            res = p
        elif mode == 'u':
            res = p + h
        elif mode == 'a':
            try:
                res = p + houji_inserts(b, h)
            except ValueError as ex:
                raise SystemExit(f'{rel} #{k}: {ex}')
        elif mode[0] == 'text':
            res = mode[1].split('\n')
        else:
            res = mode[1](p, b, h)
        out += res
        total += 1
        i = e + 1
    if k != len(spec):
        raise SystemExit(f'{rel}: spec has {len(spec)} entries but file has {k} conflicts')
    open(path, 'w').write('\n'.join(out))
print(f'resolved {total} conflicts in {len(SPEC)} files')
