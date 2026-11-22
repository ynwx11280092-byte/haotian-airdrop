"""Hand-merge of houji dp_be_tx.c hunks on pandora.

pandora differences: dp_tx_attempt_coalescing -> dp_tx_attempt_coalescing_wrapper, new
dp_tx_update_proto_stats() (parses Ethernet/IP, so raw 802.11 passthru frames skip it too).
"""
import sys

path = f'{sys.argv[1]}/qca-wifi-host-cmn/dp/wifi3.0/be/dp_be_tx.c'
s = open(path).read()


def sub1(old, new):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'expected 1 match, got {n}:\n{old}')
    s = s.replace(old, new)


# Per-remote-peer AST selection for passthru unicast (houji multi-peer TX A-MPDU path).
sub1('''	uint16_t ast_hash = vdev->bss_ast_hash;
	uint32_t hp;

	be_vdev = dp_get_be_vdev_from_dp_vdev(vdev);
''', '''	uint16_t ast_hash = vdev->bss_ast_hash;
	uint32_t hp;

#ifdef DRIVER_PASSTHRU_OWNER
	if (msdu_info->passthru_ast_override) {
		ast_idx = msdu_info->passthru_ast_idx;
		if (pt_remote_hash_override)
			ast_hash = msdu_info->passthru_ast_hash;
		pt_record_ast_selection(vdev, msdu_info, ast_idx, ast_hash);
	}
#endif

	be_vdev = dp_get_be_vdev_from_dp_vdev(vdev);
''')

# pandora: dp_sawf_config_be() takes tx_desc and no longer does peer stats here.
sub1('''	if (dp_sawf_tag_valid_get(tx_desc->nbuf)) {
		dp_sawf_config_be(soc, hal_tx_desc_cached,
				  &fw_metadata, tx_desc, msdu_info);
	}
''', '''	if (!dp_tx_desc_is_passthru(tx_desc) &&
	    dp_sawf_tag_valid_get(tx_desc->nbuf)) {
		dp_sawf_config_be(soc, hal_tx_desc_cached,
				  &fw_metadata, tx_desc, msdu_info);
	}
''')

sub1('''	dp_tx_set_min_rates_for_critical_frames(soc, hal_tx_desc_cached,
						tx_desc->nbuf);
	dp_tx_set_particular_tx_queue(soc, hal_tx_desc_cached,
				      tx_desc->nbuf);

	if (!dp_tx_desc_set_ktimestamp(vdev, tx_desc))''', '''	if (!dp_tx_desc_is_passthru(tx_desc)) {
		dp_tx_set_min_rates_for_critical_frames(soc, hal_tx_desc_cached,
							tx_desc->nbuf);
		dp_tx_set_particular_tx_queue(soc, hal_tx_desc_cached,
					      tx_desc->nbuf);
	}

	if (!dp_tx_desc_set_ktimestamp(vdev, tx_desc))''')

sub1('''			     1);
		dp_sawf_tx_enqueue_fail_peer_stats(soc, tx_desc);
		goto ring_access_fail;
	}

	tx_desc->flags |= DP_TX_DESC_FLAG_QUEUED_TX;
	dp_vdev_peer_stats_update_protocol_cnt_tx(vdev, tx_desc->nbuf);

	/* Sync cached descriptor with HW */
	hal_tx_desc_sync(hal_tx_desc_cached, hal_tx_desc, num_desc_bytes);

	dp_tx_update_proto_stats(vdev, tx_desc->nbuf, ring_id,
				 TX_ENQUEUE_HW);

	coalesce = dp_tx_attempt_coalescing_wrapper(soc, vdev, tx_desc, tid,
						    msdu_info, ring_id);
''', '''			     1);
		if (!dp_tx_desc_is_passthru(tx_desc))
			dp_sawf_tx_enqueue_fail_peer_stats(soc, tx_desc);
		goto ring_access_fail;
	}

	tx_desc->flags |= DP_TX_DESC_FLAG_QUEUED_TX;
	if (!dp_tx_desc_is_passthru(tx_desc))
		dp_vdev_peer_stats_update_protocol_cnt_tx(vdev, tx_desc->nbuf);

	/* Sync cached descriptor with HW */
	hal_tx_desc_sync(hal_tx_desc_cached, hal_tx_desc, num_desc_bytes);

	/* Raw control traffic is submitted immediately, without Ethernet policy. */
	if (!dp_tx_desc_is_passthru(tx_desc)) {
		dp_tx_update_proto_stats(vdev, tx_desc->nbuf, ring_id,
					 TX_ENQUEUE_HW);

		coalesce = dp_tx_attempt_coalescing_wrapper(soc, vdev, tx_desc,
							    tid, msdu_info,
							    ring_id);
	}
''')

sub1('''	if (vdev->search_type == HAL_TX_ADDR_INDEX_SEARCH &&
	    vdev->opmode == wlan_op_mode_sta) {''', '''	if (vdev->search_type == HAL_TX_ADDR_INDEX_SEARCH &&
	    (vdev->opmode == wlan_op_mode_sta
#ifdef DRIVER_PASSTHRU_DP
	     || vdev->opmode == wlan_op_mode_passthru
#endif
	    )) {''')

open(path, 'w').write(s)
print('dp_be_tx.c merged')
