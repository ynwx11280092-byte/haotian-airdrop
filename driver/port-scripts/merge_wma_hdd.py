"""Hand-merge of houji hunks in wma_dev_if.c and wlan_hdd_driver_ops.c on pandora.

wma_dev_if.c: pandora turned the peer-delete response if/else chain into a switch.
wlan_hdd_driver_ops.c: pandora added hdd_ddr_bw_mitigation_unregister() (kept).
"""
import sys

root = sys.argv[1]


def patch(rel, old, new):
    p = f'{root}/{rel}'
    s = open(p).read()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{rel}: expected 1 match, got {n}:\n{old}')
    open(p, 'w').write(s.replace(old, new))
    print('merged', rel)


patch('qcacld-3.0/core/wma/src/wma_dev_if.c', '''	case WMA_DEL_P2P_SELF_STA_RSP_START:
		data = (struct del_sta_self_rsp_params *)req_msg->user_data;
		wma_debug("Calling vdev detach handler");
		wma_handle_vdev_detach(wma, data->self_sta_param);
		mlme_vdev_self_peer_delete_resp(data->self_sta_param);
		qdf_mem_free(data);
		break;
''', '''	case WMA_DEL_P2P_SELF_STA_RSP_START: {
		QDF_STATUS detach_status;

		data = (struct del_sta_self_rsp_params *)req_msg->user_data;
		wma_debug("Calling vdev detach handler");
		detach_status = wma_complete_vdev_detach(wma,
						data->self_sta_param, false);
		if (QDF_IS_STATUS_ERROR(detach_status) &&
		    wma_is_passthru_vdev(
			    wma->interfaces[event->vdev_id].vdev))
			status = qdf_status_to_os_return(detach_status);
		qdf_mem_free(data);
		break;
	}
''')

patch('qcacld-3.0/core/hdd/src/wlan_hdd_driver_ops.c', '''	if (hdd_get_conparam() == QDF_GLOBAL_EPPING_MODE) {
		hdd_wlan_stop_modules(hdd_ctx, false);
		qdf_nbuf_deinit_replenish_timer();
	} else {
		hdd_thermal_mitigation_unregister(hdd_ctx, dev);
		hdd_ddr_bw_mitigation_unregister(hdd_ctx, dev);
		hdd_wlan_exit(hdd_ctx);
	}
''', '''	if (hdd_get_conparam() == QDF_GLOBAL_EPPING_MODE) {
		ret = hdd_wlan_stop_modules(hdd_ctx, false);
#ifdef DRIVER_PASSTHRU_RUNTIME
		if (ret)
			return ret;
#endif
		qdf_nbuf_deinit_replenish_timer();
	} else {
		hdd_thermal_mitigation_unregister(hdd_ctx, dev);
		hdd_ddr_bw_mitigation_unregister(hdd_ctx, dev);
		ret = hdd_wlan_exit(hdd_ctx);
		if (ret)
			return ret;
	}
''')
