obj-m := rc80211_minstrel_ht.o
rc80211_minstrel_ht-y := minstrel_ht_main.o rc80211_compat.o
ccflags-y += -I$(src) -I/root/haotian-build/kernel/net/mac80211 \
  -DCONFIG_MAC80211_RC_MINSTREL=1 -DCONFIG_MAC80211_RC_MINSTREL_HT=1 '-DCONFIG_MAC80211_RC_DEFAULT="minstrel_ht"'
KERNEL := /root/haotian-build/kernel
all:
	$(MAKE) -C $(KERNEL) O=/root/haotian-build/kernel-out ARCH=arm64 LLVM=1 M=$(PWD) \
	  KBUILD_EXTRA_SYMBOLS="$(PWD)/mac80211.symvers" modules
