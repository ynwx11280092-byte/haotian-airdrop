/* ---- pandora: PASSTHRU TSF query + WMI vdev channel-hop schedule (0x5042) ----
 * Reverse engineered from the Samsung S26U peach driver (official Qualcomm wondertap):
 *   wlan_hdd_wondertap_set_chan_sched -> wma_send_vdev_ch_hop_sched ->
 *   send_vdev_ch_hop_sched_cmd_tlv (cmd 0x5042):
 *     fixed TLV tag 0x570 len 0x10: vdev_id, next_chan_idx, dwell_time_ms, target_switch_tsf(lo32)
 *     ARRAY_UINT32 (empty), ARRAY_STRUC of n x {tag 0x575 len 0xc: freq_mhz, wmi_chan_width, flag}
 *   wma_passthru_get_tsf_timer: WMI_OCB_GET_TSF_TIMER_CMDID + RESP event.
 * Runtime only: /sys/module/qca_cld3_peach_v2/parameters/pt_tsf (read) and pt_ch_hop (write).
 */
#define PT_CH_HOP_CMDID		0x5042
#define PT_CH_HOP_TAG_FIXED	0x570
#define PT_CH_HOP_TAG_ENTRY	0x575
#define PT_CH_HOP_MAX		8

static int pt_cur_vdev = -1;
static bool pt_tsf_registered;
static DECLARE_COMPLETION(pt_tsf_done);
static u64 pt_tsf_value;
static u32 pt_tsf_vdev;
static DEFINE_MUTEX(pt_chhop_lock);

static int pt_tsf_resp_handler(ol_scn_t scn, uint8_t *data, uint32_t len)
{
	WMI_OCB_GET_TSF_TIMER_RESP_EVENTID_param_tlvs *p = (void *)data;
	wmi_ocb_get_tsf_timer_resp_event_fixed_param *f;

	if (!p || !p->fixed_param)
		return -EINVAL;
	f = p->fixed_param;
	pt_tsf_vdev = f->vdev_id;
	pt_tsf_value = ((u64)f->tsf_timer_high << 32) | f->tsf_timer_low;
	complete(&pt_tsf_done);
	return 0;
}

static int pt_query_tsf(tp_wma_handle wma, u8 vdev_id, u64 *tsf)
{
	wmi_ocb_get_tsf_timer_cmd_fixed_param *cmd;
	wmi_buf_t buf;
	QDF_STATUS st;

	if (!pt_tsf_registered) {
		st = wmi_unified_register_event_handler(wma->wmi_handle,
				wmi_ocb_get_tsf_timer_resp_event_id,
				pt_tsf_resp_handler, WMA_RX_WORK_CTX);
		if (QDF_IS_STATUS_ERROR(st))
			return -EIO;
		pt_tsf_registered = true;
	}
	buf = wmi_buf_alloc(wma->wmi_handle, sizeof(*cmd));
	if (!buf)
		return -ENOMEM;
	cmd = (void *)wmi_buf_data(buf);
	qdf_mem_zero(cmd, sizeof(*cmd));
	WMITLV_SET_HDR(&cmd->tlv_header,
		       WMITLV_TAG_STRUC_wmi_ocb_get_tsf_timer_cmd_fixed_param,
		       WMITLV_GET_STRUCT_TLVLEN(wmi_ocb_get_tsf_timer_cmd_fixed_param));
	cmd->vdev_id = vdev_id;
	reinit_completion(&pt_tsf_done);
	if (wmi_unified_cmd_send(wma->wmi_handle, buf, sizeof(*cmd),
				 WMI_OCB_GET_TSF_TIMER_CMDID)) {
		wmi_buf_free(buf);
		return -EIO;
	}
	if (!wait_for_completion_timeout(&pt_tsf_done, msecs_to_jiffies(500)))
		return -ETIMEDOUT;
	*tsf = pt_tsf_value;
	return 0;
}

static int pt_tsf_get(char *out, const struct kernel_param *kp)
{
	tp_wma_handle wma = cds_get_context(QDF_MODULE_ID_WMA);
	u64 tsf = 0;
	int ret;

	if (!wma || !wma->wmi_handle || pt_cur_vdev < 0)
		return scnprintf(out, PAGE_SIZE, "inactive\n");
	mutex_lock(&pt_chhop_lock);
	ret = pt_query_tsf(wma, pt_cur_vdev, &tsf);
	mutex_unlock(&pt_chhop_lock);
	if (ret)
		return scnprintf(out, PAGE_SIZE, "error=%d\n", ret);
	return scnprintf(out, PAGE_SIZE, "vdev=%u resp_vdev=%u tsf=%llu tsf_hex=0x%llx\n",
			 pt_cur_vdev, pt_tsf_vdev, tsf, tsf);
}
static const struct kernel_param_ops pt_tsf_ops = { .get = pt_tsf_get };
module_param_cb(pt_tsf, &pt_tsf_ops, NULL, 0400);

static char pt_ch_hop_last[160];

/* "<dwell_ms> <next_idx> <offset_us|=abs_tsf32> <freq>:<wmi_width>:<flag>[,...]"
 * offset_us: target_switch_time = query_tsf + offset (0 -> sent as 0).
 */
static int pt_ch_hop_set(const char *val, const struct kernel_param *kp)
{
	tp_wma_handle wma = cds_get_context(QDF_MODULE_ID_WMA);
	u32 dwell, next, freq[PT_CH_HOP_MAX], width[PT_CH_HOP_MAX], flag[PT_CH_HOP_MAX];
	char tbuf[24], list[120], *p, *tok;
	u32 switch_tsf = 0, n = 0, i, len, *w;
	u64 tsf = 0, off = 0;
	bool absolute = false;
	wmi_buf_t buf;
	int ret;

	if (!wma || !wma->wmi_handle || pt_cur_vdev < 0)
		return -ENODEV;
	if (sscanf(val, "%u %u %23s %119s", &dwell, &next, tbuf, list) != 4)
		return -EINVAL;
	if (tbuf[0] == '=') {
		absolute = true;
		if (kstrtou64(tbuf + 1, 0, &off))
			return -EINVAL;
	} else if (kstrtou64(tbuf, 0, &off)) {
		return -EINVAL;
	}
	p = list;
	while ((tok = strsep(&p, ",")) && n < PT_CH_HOP_MAX) {
		if (sscanf(tok, "%u:%u:%u", &freq[n], &width[n], &flag[n]) != 3)
			return -EINVAL;
		n++;
	}
	if (!n || next >= n)
		return -EINVAL;

	mutex_lock(&pt_chhop_lock);
	if (absolute) {
		switch_tsf = (u32)off;
	} else if (off) {
		ret = pt_query_tsf(wma, pt_cur_vdev, &tsf);
		if (ret)
			goto out;
		switch_tsf = (u32)(tsf + off);
	}
	len = 0x1c + n * 16;
	buf = wmi_buf_alloc(wma->wmi_handle, len);
	if (!buf) {
		ret = -ENOMEM;
		goto out;
	}
	w = (u32 *)wmi_buf_data(buf);
	qdf_mem_zero(w, len);
	w[0] = (PT_CH_HOP_TAG_FIXED << 16) | 0x10;
	w[1] = pt_cur_vdev;
	w[2] = next;
	w[3] = dwell;
	w[4] = switch_tsf;
	w[5] = WMITLV_TAG_ARRAY_UINT32 << 16;
	w[6] = (WMITLV_TAG_ARRAY_STRUC << 16) | (n << 4);
	for (i = 0; i < n; i++) {
		w[7 + i * 4] = (PT_CH_HOP_TAG_ENTRY << 16) | 0xc;
		w[8 + i * 4] = freq[i];
		w[9 + i * 4] = width[i];
		w[10 + i * 4] = flag[i];
	}
	ret = qdf_status_to_os_return(wmi_unified_cmd_send(wma->wmi_handle, buf,
							   len, PT_CH_HOP_CMDID));
	if (ret)
		wmi_buf_free(buf);
	scnprintf(pt_ch_hop_last, sizeof(pt_ch_hop_last),
		  "vdev=%d n=%u next=%u dwell=%u tsf=%llu switch=%u ret=%d",
		  pt_cur_vdev, n, next, dwell, tsf, switch_tsf, ret);
	pr_info("PT_CH_HOP %s\n", pt_ch_hop_last);
out:
	mutex_unlock(&pt_chhop_lock);
	return ret;
}

static int pt_ch_hop_get(char *out, const struct kernel_param *kp)
{
	return scnprintf(out, PAGE_SIZE, "%s\n", pt_ch_hop_last);
}
static const struct kernel_param_ops pt_ch_hop_ops = {
	.set = pt_ch_hop_set,
	.get = pt_ch_hop_get,
};
module_param_cb(pt_ch_hop, &pt_ch_hop_ops, NULL, 0600);
/* ---- end pandora ch hop ---- */

