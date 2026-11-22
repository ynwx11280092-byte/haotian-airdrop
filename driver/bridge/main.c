// SPDX-License-Identifier: GPL-2.0-only
/*
 * Experimental standalone packaging of the retained CNSS Wonder broker.
 * Owns only a synthetic platform device; does not bind the WLAN PCI device.
 * Symbol consumers pin this module through their normal module dependencies.
 */
#include "wonder_lifecycle.inc"
#include <linux/mutex.h>
#include "pin_release.inc"

static struct platform_device *xos_wonder_device;

static int __init xos_wonder_bridge_init(void)
{
	struct platform_device *pdev;
	int ret;

	pdev = platform_device_register_simple("xos-wonder-provider",
					      PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);
	ret = cnss_vendor_wonder_dev_probe(pdev);
	if (ret) {
		platform_device_unregister(pdev);
		return ret;
	}
	xos_wonder_device = pdev;
	pr_info("xos_wonder_bridge: isolated broker ready\n");
	return 0;
}

static void __exit xos_wonder_bridge_exit(void)
{
	/* Importing WLAN/Wonder modules must already be absent: their symbol
	 * dependency refs prevent ordinary rmmod while they remain loaded.
	 */
	cnss_vendor_wonder_dev_remove(xos_wonder_device);
	platform_device_unregister(xos_wonder_device);
	pr_info("xos_wonder_bridge: isolated broker removed\n");
}

module_init(xos_wonder_bridge_init);
module_exit(xos_wonder_bridge_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Houji experimental standalone Wonder lifecycle broker");
