"""Adapt houji passthru code to pandora (popsicle-w-oss) API changes found at compile time."""
import sys

root = sys.argv[1]


def patch(rel, old, new, count=1):
    p = f'{root}/{rel}'
    s = open(p).read()
    n = s.count(old)
    if n != count:
        raise SystemExit(f'{rel}: expected {count} match(es), got {n}:\n{old}')
    open(p, 'w').write(s.replace(old, new))
    print('fixed', rel)


# hdd_validate_channel_and_bandwidth() gained ccfs1 (80+80/320 MHz segment); passthru uses <=80 MHz.
patch('qcacld-3.0/core/hdd/src/wlan_hdd_passthru_control.c',
      '''	ret = hdd_validate_channel_and_bandwidth(adapter, params->channel.freq,
						 width);''',
      '''	ret = hdd_validate_channel_and_bandwidth(adapter, params->channel.freq,
						 0, width);''')

# struct wma_txrx_node lost mac_id (log-only use).
patch('qcacld-3.0/core/hdd/src/wlan_hdd_passthru_control.c',
      '''		hdd_info("PT coexist firmware mapping vdev %u mac %u freq %u tx_streams %u",
			 vdev_id, wma->interfaces[vdev_id].mac_id,
			 wma->interfaces[vdev_id].ch_freq,''',
      '''		hdd_info("PT coexist firmware mapping vdev %u freq %u tx_streams %u",
			 vdev_id,
			 wma->interfaces[vdev_id].ch_freq,''')

# policy_mgr_incr_active_session() gained update_flow_pool_map; houji's base always mapped.
patch('qcacld-3.0/core/hdd/src/wlan_hdd_passthru_control.c',
      '''		policy_mgr_incr_active_session(iface->hdd->psoc,
					      QDF_PASSTHRU_MODE, vdev_id);''',
      '''		policy_mgr_incr_active_session(iface->hdd->psoc,
					      QDF_PASSTHRU_MODE, vdev_id, true);''')

# ol_txrx_vdev_del_notify_cb is now (osif_vdev, cdp_vdev *).
patch('qcacld-3.0/components/dp/core/src/wlan_dp_passthru.c',
      'static void wlan_dp_passthru_notify(void *context)\n',
      'static void wlan_dp_passthru_notify_ctx(void *context);\n\n'
      'static void wlan_dp_passthru_notify(struct ol_osif_vdev_t *osif,\n'
      '\t\t\t\t    struct cdp_vdev *vdev)\n{\n'
      '\twlan_dp_passthru_notify_ctx((void *)osif);\n}\n\n'
      'static void wlan_dp_passthru_notify_ctx(void *context)\n')

# policy_mgr_2_freq_same_mac_in_dbs() now takes psoc.
patch('qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_get_set_utils.c',
      'policy_mgr_2_freq_same_mac_in_dbs(policy_mgr_get_context(psoc),',
      'policy_mgr_2_freq_same_mac_in_dbs(psoc,')

# wlan_cfg_get_num_tx_desc() is per pool now; flow-pool mapping uses DP_TXDESC_POOL_ANY.
patch('qca-wifi-host-cmn/dp/wifi3.0/dp_tx_flow_control.c',
      'uint32_t count = wlan_cfg_get_num_tx_desc(soc->wlan_cfg_ctx);',
      'uint32_t count = wlan_cfg_get_num_tx_desc(soc->wlan_cfg_ctx,\n\t\t\t\t\t\t  DP_TXDESC_POOL_ANY);')

# AST cache mapping helper renamed / re-parameterised.
patch('qca-wifi-host-cmn/dp/wifi3.0/dp_peer.c',
      '''				dp_tx_ppeds_cfg_astidx_cache_mapping(soc, vdev,
								     peer_map);''',
      '''				dp_tx_cfg_astidx_cache_mapping_wrapper(soc,
								       peer,
								       vdev);''')

# dp_vdev_register_wifi3() returns struct cdp_vdev * on pandora.
patch('qca-wifi-host-cmn/dp/wifi3.0/dp_main.c',
      '''	if (vdev->opmode == wlan_op_mode_passthru) {
		dp_vdev_unref_delete(soc, vdev, DP_MOD_ID_CDP);
		return QDF_STATUS_E_NOSUPPORT;
	}''',
      '''	if (vdev->opmode == wlan_op_mode_passthru) {
		dp_vdev_unref_delete(soc, vdev, DP_MOD_ID_CDP);
		return NULL;
	}''')

# RX buffer SMMU mapping lock: pandora's generic helpers (IPA variant only exists with IPA offload).
patch('qca-wifi-host-cmn/dp/wifi3.0/dp_rx_err.c', 'dp_ipa_rx_buf_smmu_mapping_lock(soc);',
      'dp_rx_buf_smmu_mapping_lock(soc);')
patch('qca-wifi-host-cmn/dp/wifi3.0/dp_rx_err.c', 'dp_ipa_rx_buf_smmu_mapping_unlock(soc);',
      'dp_rx_buf_smmu_mapping_unlock(soc);', count=2)

# Kbuild: houji's -include of offline-build-declarations.h was for houji's tree only.
patch('qcacld-3.0/Kbuild',
      'CFLAGS_components/umac/mlme/connection_mgr/core/src/wlan_cm_vdev_connect.o += -include $(src)/offline-build-declarations.h\n',
      '')
