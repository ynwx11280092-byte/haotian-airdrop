"""Hand-merge of houji's __hdd_vdev_destroy() record tracking on pandora's body.

pandora differences kept: qdf_atomic_test_bit(SME_SESSION_OPENED, ...) and the
hdd_create_p2p_device_vdev_during_sta_vdev_destroy() step.
"""
import sys

p = f'{sys.argv[1]}/qcacld-3.0/core/hdd/src/wlan_hdd_main.c'
s = open(p).read()
start = s.index('static int\n__hdd_vdev_destroy(struct wlan_hdd_link_info *link_info,')
end = s.index('\nvoid\nhdd_store_nss_chains_cfg_in_vdev(', start)
f = s[start:end]


def sub1(old, new):
    global f
    n = f.count(old)
    if n != 1:
        raise SystemExit(f'expected 1 match, got {n}:\n{old}')
    f = f.replace(old, new)


sub1('''	enum QDF_OPMODE op_mode;

	vdev_id = link_info->vdev_id;''', '''	enum QDF_OPMODE op_mode;

#ifdef DRIVER_PASSTHRU_OWNER
	if (record) {
		if (record->steps & HDD_PT_VDEV_DELETE_CALLED)
			return -EALREADY;
		record->steps |= HDD_PT_VDEV_DELETE_CALLED;
		record->delete_result = -EINPROGRESS;
	}
#endif
	vdev_id = link_info->vdev_id;''')
sub1('''		hdd_nofl_debug("vdev %u does not exist", vdev_id);
		return -EINVAL;''', '''		hdd_nofl_debug("vdev %u does not exist", vdev_id);
		return hdd_vdev_delete_return(record, -EINVAL);''')
sub1('''	if (!vdev)
		return -EINVAL;''', '''	if (!vdev)
		return hdd_vdev_delete_return(record, -EINVAL);''')
sub1('''		hdd_err("invalid psoc");
		return -EINVAL;''', '''		hdd_err("invalid psoc");
#ifdef DRIVER_PASSTHRU_OWNER
		if (record)
			hdd_objmgr_put_vdev_by_user(vdev, WLAN_OSIF_ID);
#endif
		return hdd_vdev_delete_return(record, -EINVAL);''')
sub1('''	wlan_objmgr_vdev_release_ref(vdev, WLAN_HDD_ID_OBJ_MGR);
''', '''	wlan_objmgr_vdev_release_ref(vdev, WLAN_HDD_ID_OBJ_MGR);
#ifdef DRIVER_PASSTHRU_OWNER
	if (record)
		record->steps |= HDD_PT_VDEV_HDD_REF_RELEASED;
#endif
''')
sub1('ret = hdd_vdev_destroy_event_wait(hdd_ctx, vdev);',
     'ret = hdd_vdev_destroy_event_wait(hdd_ctx, vdev, record);')
sub1('''	qdf_runtime_pm_allow_suspend(&hdd_ctx->runtime_context.vdev_destroy);
	return ret;
}
''', '''	qdf_runtime_pm_allow_suspend(&hdd_ctx->runtime_context.vdev_destroy);
	return hdd_vdev_delete_return(record, ret);
}

int hdd_vdev_destroy(struct wlan_hdd_link_info *link_info)
{
	return __hdd_vdev_destroy(link_info, NULL);
}

#ifdef DRIVER_PASSTHRU_OWNER
int hdd_pt_vdev_destroy(struct wlan_hdd_link_info *link_info,
			struct hdd_pt_vdev_record *record)
{
	if (!link_info || !link_info->adapter || !record ||
	    link_info->adapter->device_mode != QDF_PASSTHRU_MODE ||
	    !record->generation ||
	    record->link != link_info)
		return -EINVAL;
#ifdef DRIVER_PASSTHRU_MODE
	if (record->generation != link_info->adapter->passthru_generation)
		return -EINVAL;
#endif
	if (record->steps & HDD_PT_VDEV_DELETE_CALLED)
		return -EALREADY;
	if (!(record->steps & HDD_PT_VDEV_CREATE_RETURNED))
		return -EBUSY;
	if (!(record->steps & HDD_PT_VDEV_OBTAINED))
		return -ENOENT;
	if (record->vdev_id != link_info->vdev_id)
		return -ESTALE;
	return __hdd_vdev_destroy(link_info, record);
}
#endif
''')

s = s[:start] + f + s[end:]
open(p, 'w').write(s)
print('__hdd_vdev_destroy merged')
