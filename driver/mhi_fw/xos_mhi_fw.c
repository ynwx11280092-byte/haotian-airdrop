// SPDX-License-Identifier: GPL-2.0-only
/*
 * xos_mhi_fw: let the WLAN MHI controller re-size its firmware (FBC) buffer.
 *
 * Qualcomm mhi.ko + cnss2 keep the BHIe image buffers allocated by the first successful
 * power-up after boot (cnss2 sets mhi_cntrl->img_pre_alloc = true), sized for that boot's
 * amss20.bin. A later, larger firmware overflows it in mhi_firmware_copy() (kernel panic,
 * seen with the 45 KiB larger Samsung S26U peach firmware).
 *
 * Writing 1 to /sys/module/xos_mhi_fw/parameters/realloc clears img_pre_alloc. Do it
 * while the chip is powered: the next MHI power-down then frees fbc_image/rddm_image through
 * the normal non-prealloc path, the next power-up allocates them for the new firmware size,
 * and cnss2 sets img_pre_alloc again after that power-up succeeds.
 *
 * Offsets below are for the haotian phone's mhi.ko (6.6.118 kernel, mhi.ko built for
 * 6.6.57 vendor tree). They were derived on 2026-11-22 from the module's own .BTF
 * (CONFIG_DEBUG_INFO_BTF_MODULES=y) plus disassembly of mhi_alloc_bhie_table /
 * mhi_free_bhie_table / mhi_prepare_for_power_up / mhi_fw_load_handler:
 *
 *   struct mhi_controller (size 680):
 *     +0x70 rddm_size (base type, 64-bit)
 *     +0x78 sbl_size
 *     +0x80 seg_len
 *     +0x90 fbc_image        (struct image_info *)
 *     +0x98 rddm_image       (struct image_info *)
 *     +0x288 buffer_len
 *     +0x294 img_pre_alloc   (bool; cleared by us)
 *     +0x296 fbc_download    (bool)
 *   struct image_info (size 24):
 *     +0x00 mhi_buf (struct mhi_buf_info *)
 *     +0x08 bhi_vec
 *     +0x10 entries (u32)
 *
 *  (pandora 6.12's mhi.ko has the same field order with different offsets:
 *   0x78/0x80/0x88/0x98/0xa0/0x264 — do not mix them up.)
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>
#include <linux/sizes.h>

struct mhi_controller;
struct mhi_controller *mhi_bdf_to_controller(u32 domain, u32 bus, u32 slot, u32 dev_id);

#define OFF_RDDM_SIZE	0x70
#define OFF_SBL_SIZE	0x78
#define OFF_SEG_LEN	0x80
#define OFF_FBC_IMAGE	0x90
#define OFF_RDDM_IMAGE	0x98
#define OFF_BUFFER_LEN	0x288
#define OFF_PRE_ALLOC	0x294
#define OFF_FBC_DOWNLOAD 0x296
#define IMG_ENTRIES	0x10

static u32 wlan_dev_id = 0x110e;	/* mhi_110e_00.01.00 */
module_param(wlan_dev_id, uint, 0400);

static DEFINE_MUTEX(lock);

static void *ctrl_get(void)
{
	return mhi_bdf_to_controller(0, 1, 0, wlan_dev_id);
}

static int sane(u8 *c)
{
	size_t seg = *(size_t *)(c + OFF_SEG_LEN);
	u8 pre = READ_ONCE(c[OFF_PRE_ALLOC]);

	if (seg < SZ_4K || seg > SZ_16M || (seg & (seg - 1)))
		return -EPROTO;
	if (pre > 1)
		return -EPROTO;
	return 0;
}

static u32 entries(u8 *c, int off)
{
	u8 *img = READ_ONCE(*(u8 **)(c + off));

	return img ? *(u32 *)(img + IMG_ENTRIES) : 0;
}

static int realloc_get(char *buf, const struct kernel_param *kp)
{
	u8 *c;
	size_t seg;
	u32 fe;
	int ret;

	mutex_lock(&lock);
	c = ctrl_get();
	if (!c) {
		ret = scnprintf(buf, PAGE_SIZE, "no_controller\n");
		goto out;
	}
	if (sane(c)) {
		ret = scnprintf(buf, PAGE_SIZE, "layout_mismatch\n");
		goto out;
	}
	seg = *(size_t *)(c + OFF_SEG_LEN);
	fe = entries(c, OFF_FBC_IMAGE);
	ret = scnprintf(buf, PAGE_SIZE,
			"pre_alloc=%u seg_len=%zu sbl_size=%zu fbc_entries=%u fbc_capacity=%zu rddm_entries=%u rddm_size=%zu buffer_len=%zu fbc_download=%u\n",
			c[OFF_PRE_ALLOC], seg, *(size_t *)(c + OFF_SBL_SIZE), fe, fe ? (size_t)(fe - 1) * seg : 0,
			entries(c, OFF_RDDM_IMAGE), *(size_t *)(c + OFF_RDDM_SIZE),
			*(size_t *)(c + OFF_BUFFER_LEN), c[OFF_FBC_DOWNLOAD]);
out:
	mutex_unlock(&lock);
	return ret;
}

static int realloc_set(const char *val, const struct kernel_param *kp)
{
	bool on;
	u8 *c;
	int ret = kstrtobool(val, &on);

	if (ret)
		return ret;
	if (!on)
		return -EINVAL;
	mutex_lock(&lock);
	c = ctrl_get();
	ret = c ? sane(c) : -ENODEV;
	if (!ret) {
		WRITE_ONCE(c[OFF_PRE_ALLOC], 0);
		pr_info("xos_mhi_fw: img_pre_alloc cleared; buffers re-sized at next power cycle\n");
	}
	mutex_unlock(&lock);
	return ret;
}

static const struct kernel_param_ops realloc_ops = {
	.set = realloc_set,
	.get = realloc_get,
};
module_param_cb(realloc, &realloc_ops, NULL, 0600);
MODULE_PARM_DESC(realloc, "write 1 (chip powered) to let MHI re-size BHIe firmware buffers");

static int __init xos_mhi_fw_init(void)
{
	u8 *c = ctrl_get();

	if (!c || sane(c)) {
		pr_err("xos_mhi_fw: WLAN MHI controller %s\n", c ? "layout mismatch" : "not found");
		return -ENODEV;
	}
	pr_info("xos_mhi_fw: ready (pre_alloc=%u)\n", c[OFF_PRE_ALLOC]);
	return 0;
}
module_init(xos_mhi_fw_init);

static void __exit xos_mhi_fw_exit(void)
{
}
module_exit(xos_mhi_fw_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("haotian: allow WLAN MHI firmware buffer re-size for alternate amss20.bin");
MODULE_SOFTDEP("pre: mhi");
