// standalone rc80211_minstrel_ht：补上 mac80211 内置但未导出的 frame_duration
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ieee80211.h>
#include <net/mac80211.h>

int ieee80211_frame_duration(enum nl80211_band band, size_t len,
			     int rate, int erp, int short_preamble,
			     int shift)
{
	int dur;

	if (band == NL80211_BAND_5GHZ || erp) {
		dur = 16 + 16 + 4;
		dur *= 1 << shift;
		dur += 4 * DIV_ROUND_UP((16 + 8 * (len + 4) + 6) * 10, 4 * rate);
	} else {
		dur = 10;
		dur += short_preamble ? (72 + 24) : (144 + 48);
		dur += DIV_ROUND_UP((len + 4) * 8 * 10, rate);
	}
	return dur;
}

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("haotian standalone minstrel_ht (compat for stock mac80211 without RC)");

/* ???????? mac80211 ???? main.c ??? rc80211_minstrel_init ????? init */
extern int __init rc80211_minstrel_init(void);
extern void rc80211_minstrel_exit(void);

static int __init rc80211_compat_init(void)
{
	return rc80211_minstrel_init();
}

static void __exit rc80211_compat_exit(void)
{
	rc80211_minstrel_exit();
}

module_init(rc80211_compat_init);
module_exit(rc80211_compat_exit);
