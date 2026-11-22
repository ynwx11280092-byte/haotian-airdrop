"""Add madrid's /proc/sys/net/wonder/wonder_enable to our wonder (idempotent).

Reverse-engineered from madrid wonder.ko (OS4.0.29): wonder_data has `int enable` (=1 at
wonder_mac80211_init); wonder_start returns -1 when it is 0; probe registers
register_net_sysctl_sz(&init_net, "net/wonder", {"wonder_enable", maxlen 4, 0644,
proc_wonder_enable, SYSCTL_ZERO..SYSCTL_ONE}); proc handler -ENODEV when no instance.
MIShare's AirDropAvailability observes this file to decide whether AirDrop is offered.
usage: add_wonder_enable.py <wonder src dir>"""
import sys
from pathlib import Path

d = Path(sys.argv[1])


def patch(name, old, new, count=1):
    p = d / name
    s = p.read_text()
    if new in s:
        return
    assert s.count(old) == count, (name, old, s.count(old))
    p.write_text(s.replace(old, new))


patch('core.h', '\tbool provider_lost;\n};',
      '\tbool provider_lost;\n\tint enable; /* net.wonder.wonder_enable (madrid ABI); 0 blocks wonder_start */\n};')

patch('mac80211.c', '\twonder->tx_stop = false;\n\t/* Set Band Capabilities */',
      '\twonder->tx_stop = false;\n\twonder->enable = 1;\n\t/* Set Band Capabilities */')

patch('mac80211.c', '\tASSERT_RTNL();\n\tif (READ_ONCE(wonder->quiescing))\n\t\treturn -ESHUTDOWN;\n\tret = wondertap_call_get',
      '\tASSERT_RTNL();\n\tif (!READ_ONCE(wonder->enable)) {\n\t\twonder_error("wonder disabled via sysctl\\n");\n\t\treturn -1;\n\t}\n'
      '\tif (READ_ONCE(wonder->quiescing))\n\t\treturn -ESHUTDOWN;\n\tret = wondertap_call_get')

SYSCTL = r'''
/* net.wonder.wonder_enable, same path/mode/range as madrid's wonder.ko. */
static struct wonder_data *wonder_sysctl_data;
static struct ctl_table_header *wonder_sysctl_hdr;
static DEFINE_MUTEX(wonder_sysctl_lock);

static int proc_wonder_enable(const struct ctl_table *table, int write, void *buffer,
			      size_t *lenp, loff_t *ppos)
{
	struct ctl_table tmp = {
		.maxlen = sizeof(int),
		.extra1 = SYSCTL_ZERO,
		.extra2 = SYSCTL_ONE,
	};
	int val, ret;

	mutex_lock(&wonder_sysctl_lock);
	if (!wonder_sysctl_data) {
		mutex_unlock(&wonder_sysctl_lock);
		return -ENODEV;
	}
	val = READ_ONCE(wonder_sysctl_data->enable);
	tmp.data = &val;
	ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);
	if (write && !ret) {
		WRITE_ONCE(wonder_sysctl_data->enable, val);
		pr_info("[wonder] Driver %s via sysctl\n", val ? "enabled" : "disabled");
	}
	mutex_unlock(&wonder_sysctl_lock);
	return ret;
}

static struct ctl_table wonder_sysctl_table[] = {
	{
		.procname = "wonder_enable",
		.maxlen = sizeof(int),
		.mode = 0644,
		.proc_handler = proc_wonder_enable,
		.extra1 = SYSCTL_ZERO,
		.extra2 = SYSCTL_ONE,
	},
};

static void wonder_sysctl_init(struct wonder_data *wonder)
{
	mutex_lock(&wonder_sysctl_lock);
	wonder_sysctl_data = wonder;
	mutex_unlock(&wonder_sysctl_lock);
	wonder_sysctl_hdr = register_net_sysctl_sz(&init_net, "net/wonder", wonder_sysctl_table,
						   ARRAY_SIZE(wonder_sysctl_table));
	if (!wonder_sysctl_hdr)
		pr_warn("[wonder] failed to register net/wonder sysctl\n");
}

static void wonder_sysctl_exit(void)
{
	if (wonder_sysctl_hdr) {
		unregister_net_sysctl_table(wonder_sysctl_hdr);
		wonder_sysctl_hdr = NULL;
	}
	mutex_lock(&wonder_sysctl_lock);
	wonder_sysctl_data = NULL;
	mutex_unlock(&wonder_sysctl_lock);
}
'''

patch('main.c', '#include <linux/of_platform.h>\n',
      '#include <linux/of_platform.h>\n#include <linux/sysctl.h>\n#include <net/net_namespace.h>\n')
patch('main.c', '\nstatic int wonder_probe_instance(struct platform_device *pdev)',
      SYSCTL + '\nstatic int wonder_probe_instance(struct platform_device *pdev)')
patch('main.c', '\t\tdev_warn(&pdev->dev, "%s(): Debugfs unavailable: %d\\n", __func__, ret);\n\treturn 0;',
      '\t\tdev_warn(&pdev->dev, "%s(): Debugfs unavailable: %d\\n", __func__, ret);\n\twonder_sysctl_init(wonder);\n\treturn 0;')
patch('main.c', '\twonder_debugfs_exit();\n\t/* Detach completes',
      '\twonder_sysctl_exit();\n\twonder_debugfs_exit();\n\t/* Detach completes')
print('patched')
