package org.haotian.xoscompat;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInfo;
import android.net.wifi.WifiManager;
import android.os.SystemClock;
import android.util.Log;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * haotian (Xiaomi 15 Pro, HyperOS 4.0.4.0, MIShare 5.4.x) companion for the xos0 exclusive-radio
 * backend.
 *
 * <p>radio.sh switches Wi-Fi off while it owns the radio (sys.xos.exclusive=1). Native MIShare treats
 * "Wi-Fi switched off" as a reason to stop AirDrop and drop the "everyone" switch. While the backend
 * owns the radio this module keeps reporting Wi-Fi as enabled to MIShare and drops
 * WIFI_STATE_CHANGED for it. This is the base capability and is installed unconditionally.
 *
 * <p>Advanced hooks (Apple Live Photo -> Motion Photo merge and the gallery-share AirDrop dispatch
 * fix) depend on MIShare internals. They are gated on a known MIShare versionCode: on an unknown
 * build they are skipped with a warning instead of touching code the module was not verified
 * against. Every hook installation and every hook callback is exception-isolated, so a MIShare
 * update can at worst disable a feature, never crash the target process (and never the system).
 */
public final class Hook implements IXposedHookLoadPackage {
    private static final String TAG = "HaotianXosCompat";
    private static final String MISHARE_PKG = "com.miui.mishare.connectivity";
    private static final String RESOLVER_PKG = "com.android.intentresolver";
    private static final String AIRDROP_TRAMPOLINE =
            "com.xiaomi.sharop.AirDropShareTrampolineActivity";
    private static final String EXCLUSIVE_PROP = "sys.xos.exclusive";

    /**
     * MIShare versionCodes the advanced hooks were verified against, or are worth a best-effort try.
     *
     * 50401 = 5.4.1 (upstream pandora's verified build)
     * 50500 = 5.5.0_20261029_1004 (实测 haotian OS4.0.4.0 预装版本; hooks are candidate-based and
     *         every callback is exception-isolated, so a mismatch only disables a feature)
     * 50501 = next 5.x build
     */
    private static final int[] KNOWN_MISHARE_VERSIONS = {50401, 50500, 50501};
    private static final int UNKNOWN_VERSION = -1;

    /** One-time guards: repeated package loads or callbacks must never install a hook twice. */
    private static final AtomicBoolean WIFI_MASK_INSTALLED = new AtomicBoolean(false);
    private static final AtomicBoolean LIVE_PHOTO_INSTALLED = new AtomicBoolean(false);
    private static final AtomicBoolean RESOLVER_INSTALLED = new AtomicBoolean(false);
    private static final Set<Class<?>> HOOKED_RECEIVERS =
            Collections.synchronizedSet(new HashSet<Class<?>>());
    private static volatile Method sSystemPropertiesGet;

    // ---------------------------------------------------------------------------------------------
    // Entry point
    // ---------------------------------------------------------------------------------------------

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam p) {
        // A module failure thrown out of here takes the whole target process down: never throw.
        try {
            if (p == null || p.packageName == null) {
                return;
            }
            ClassLoader cl = p.classLoader != null ? p.classLoader : Hook.class.getClassLoader();
            if (cl == null) {
                cl = ClassLoader.getSystemClassLoader();
            }
            if (MISHARE_PKG.equals(p.packageName)) {
                handleMiShare(cl);
            } else if (RESOLVER_PKG.equals(p.packageName)) {
                handleIntentResolver(cl);
            }
        } catch (Throwable t) {
            warnThrottled("entry", "handleLoadPackage failed (ignored)", t);
        }
    }

    private static void handleMiShare(final ClassLoader cl) {
        // Base capability: always on, independent of the MIShare version.
        try {
            installWifiMasking(cl);
        } catch (Throwable t) {
            warnThrottled("mishare:wifi", "Wi-Fi state masking failed to install (ignored)", t);
        }
        // MIShare 5.5.0 的 WifiConflictManager 在启动 XOS 前会主动断开 5GHz STA 并等待 2s，
        // 超时就整体重试（表现为 Wi-Fi 反复断开重连、iPhone 2~10 秒才发现、偶尔一直搜不到）。
        // 我们的 radio 后端本来就会在整个会话期间关闭 Wi-Fi，所以直接回答“已离开 5GHz”跳过该步骤。
        try {
            hookSkipStaHandoff(cl);
        } catch (Throwable t) {
            warnThrottled("mishare:stahandoff", "STA 5 GHz handoff hook failed to install (ignored)", t);
        }
        // MisShare 自己的 RawMdnsBrowser 只监听、不发查询；在 MiShare 进程内用
        // xos0 网络绑定的 socket 主动发 QU 查询并扇出单播响应，必要时可让 iPhone 回应。
        try {
            startMdnsProbe();
        } catch (Throwable t) {
            warnThrottled("mishare:mdnsprobe", "mDNS probe failed to start (ignored)", t);
        }
        installAdvancedHooksWhenVersionKnown(cl, "MiShare", new Runnable() {
            @Override
            public void run() {
                try {
                    hookLivePhoto(cl);
                } catch (Throwable t) {
                    warnThrottled("mishare:livephoto", "Live Photo hook failed to install (ignored)", t);
                }
            }
        });
    }

    private static void handleIntentResolver(final ClassLoader cl) {
        installAdvancedHooksWhenVersionKnown(cl, "IntentResolver", new Runnable() {
            @Override
            public void run() {
                try {
                    hookIntentResolver(cl);
                } catch (Throwable t) {
                    warnThrottled("resolver:hook", "IntentResolver gallery hook failed to install (ignored)", t);
                }
            }
        });
    }

    // ---------------------------------------------------------------------------------------------
    // MIShare version gate
    // ---------------------------------------------------------------------------------------------

    private static void installAdvancedHooksWhenVersionKnown(final ClassLoader cl, final String who,
            final Runnable install) {
        try {
            int version = readMiShareVersionCode(null);
            if (version != UNKNOWN_VERSION) {
                applyVersionGate(who, version, install);
                return;
            }
            infoThrottled("version-defer:" + who, who + ": MIShare versionCode not readable yet,"
                    + " deferring advanced hooks until the app context is up");
            if (!deferUntilAppReady(cl, who, install)) {
                warnThrottled("version-hook:" + who, who
                        + ": cannot defer the version check, keeping Wi-Fi masking only");
            }
        } catch (Throwable t) {
            warnThrottled("version:" + who, who + ": version gate failed, keeping Wi-Fi masking only", t);
        }
    }

    /** Kept separate so the immediate path and the deferred path share exactly one gate. */
    private static void applyVersionGate(String who, int version, Runnable install) {
        if (isKnownMiShareVersion(version)) {
            infoThrottled("version-ok:" + who, who + ": MIShare versionCode " + version
                    + " is supported, installing advanced hooks");
            try {
                install.run();
            } catch (Throwable t) {
                warnThrottled("version-install:" + who, who
                        + ": advanced hook installation failed (ignored)", t);
            }
            return;
        }
        warnThrottled("version-skip:" + who, who + ": MIShare versionCode " + version
                + " is not in the known set {50401, 50501}; skipping Live Photo / gallery-dispatch"
                + " hooks (Wi-Fi state masking stays active)");
    }

    private static boolean isKnownMiShareVersion(int versionCode) {
        if (versionCode == UNKNOWN_VERSION) {
            return false;
        }
        for (int known : KNOWN_MISHARE_VERSIONS) {
            if (known == versionCode) {
                return true;
            }
        }
        return false;
    }

    /**
     * Defers the version check to the first application callback, where a real Context (and therefore
     * PackageManager.getPackageInfo) is guaranteed to exist. Falls back to Application.onCreate if the
     * Instrumentation hook is unavailable. Never throws.
     */
    private static boolean deferUntilAppReady(final ClassLoader cl, final String who,
            final Runnable install) {
        final XC_MethodHook whenAppReady = new XC_MethodHook() {
            private final AtomicBoolean fired = new AtomicBoolean(false);

            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                try {
                    if (!fired.compareAndSet(false, true)) {
                        return;
                    }
                    Object app = null;
                    if (param != null) {
                        if (param.args != null && param.args.length > 0) {
                            app = param.args[0];
                        }
                        if (app == null) {
                            app = param.thisObject;
                        }
                    }
                    Context ctx = app instanceof Context ? (Context) app : null;
                    if (ctx == null) {
                        ctx = currentApplication();
                    }
                    int version = readMiShareVersionCode(ctx);
                    if (version == UNKNOWN_VERSION) {
                        warnThrottled("version-app:" + who, who + ": MIShare versionCode still"
                                + " unreadable at app start, keeping Wi-Fi masking only");
                        return;
                    }
                    applyVersionGate(who, version, install);
                } catch (Throwable t) {
                    warnThrottled("version-app:" + who, who
                            + ": deferred version gate failed (ignored)", t);
                }
            }
        };
        try {
            Method callCreate = Class.forName("android.app.Instrumentation", false, cl)
                    .getDeclaredMethod("callApplicationOnCreate", Application.class);
            if (hookQuietly("version-hook:" + who, callCreate, whenAppReady)) {
                return true;
            }
        } catch (Throwable t) {
            warnThrottled("version-hook:" + who, who + ": Instrumentation hook unavailable", t);
        }
        try {
            Method onCreate = Application.class.getDeclaredMethod("onCreate");
            return hookQuietly("version-hook-app:" + who, onCreate, whenAppReady);
        } catch (Throwable t) {
            warnThrottled("version-hook-app:" + who, who + ": Application.onCreate hook unavailable", t);
            return false;
        }
    }

    private static int readMiShareVersionCode(Context ctx) {
        if (ctx != null) {
            try {
                PackageInfo info = ctx.getPackageManager().getPackageInfo(MISHARE_PKG, 0);
                if (info != null) {
                    return versionCodeOf(info);
                }
            } catch (Throwable ignored) {
                // Fall through to the context-free package service lookup (e.g. package visibility).
            }
        }
        return versionFromPackageManagerService();
    }

    @SuppressWarnings("deprecation")
    private static int versionCodeOf(PackageInfo info) {
        try {
            long code = info.getLongVersionCode();
            return code > Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) code;
        } catch (Throwable t) {
            return info.versionCode;
        }
    }

    /** Context-free fallback: ActivityThread/AppGlobals.getPackageManager().getPackageInfo(). */
    private static int versionFromPackageManagerService() {
        Object ipm = null;
        try {
            Method getter = Class.forName("android.app.ActivityThread").getMethod("getPackageManager");
            ipm = getter.invoke(null);
        } catch (Throwable ignored) {
        }
        if (ipm == null) {
            try {
                Method getter = Class.forName("android.app.AppGlobals").getMethod("getPackageManager");
                ipm = getter.invoke(null);
            } catch (Throwable ignored) {
            }
        }
        if (ipm == null) {
            return UNKNOWN_VERSION;
        }
        try {
            for (Method m : ipm.getClass().getMethods()) {
                if (!"getPackageInfo".equals(m.getName())) {
                    continue;
                }
                Class<?>[] types = m.getParameterTypes();
                if (types.length != 3 || types[0] != String.class || types[2] != int.class) {
                    continue;
                }
                Object flags;
                if (types[1] == long.class) {
                    flags = Long.valueOf(0L);
                } else if (types[1] == int.class) {
                    flags = Integer.valueOf(0);
                } else {
                    continue;
                }
                Object result = m.invoke(ipm, MISHARE_PKG, flags, Integer.valueOf(0));
                if (result instanceof PackageInfo) {
                    return versionCodeOf((PackageInfo) result);
                }
            }
        } catch (Throwable ignored) {
        }
        return UNKNOWN_VERSION;
    }

    private static Context currentApplication() {
        try {
            Object app = Class.forName("android.app.ActivityThread").getMethod("currentApplication")
                    .invoke(null);
            if (app instanceof Context) {
                return (Context) app;
            }
        } catch (Throwable ignored) {
        }
        try {
            Object app = Class.forName("android.app.AppGlobals").getMethod("getInitialApplication")
                    .invoke(null);
            if (app instanceof Context) {
                return (Context) app;
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    // ---------------------------------------------------------------------------------------------
    // Base capability: mask the "Wi-Fi off" state while the xos backend owns the radio
    // ---------------------------------------------------------------------------------------------

    private static void installWifiMasking(final ClassLoader cl) {
        if (!WIFI_MASK_INSTALLED.compareAndSet(false, true)) {
            return;
        }
        int wifiHooks = 0;
        if (hookQuietly("mishare:mask-getWifiState",
                findDeclaredMethod(WifiManager.class, "getWifiState"), new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        try {
                            if (ownsRadio()) {
                                param.setResult(Integer.valueOf(WifiManager.WIFI_STATE_ENABLED));
                            }
                        } catch (Throwable t) {
                            warnThrottled("mishare:mask-getWifiState-cb",
                                    "getWifiState mask failed (ignored)", t);
                        }
                    }
                })) {
            wifiHooks++;
        }
        if (hookQuietly("mishare:mask-isWifiEnabled",
                findDeclaredMethod(WifiManager.class, "isWifiEnabled"), new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        try {
                            if (ownsRadio()) {
                                param.setResult(Boolean.TRUE);
                            }
                        } catch (Throwable t) {
                            warnThrottled("mishare:mask-isWifiEnabled-cb",
                                    "isWifiEnabled mask failed (ignored)", t);
                        }
                    }
                })) {
            wifiHooks++;
        }
        if (hookQuietly("mishare:mask-setWifiEnabled",
                findDeclaredMethod(WifiManager.class, "setWifiEnabled", boolean.class),
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        try {
                            if (param != null && param.args != null && param.args.length > 0
                                    && Boolean.TRUE.equals(param.args[0]) && ownsRadio()) {
                                infoThrottled("mishare:setWifiEnabled",
                                        "suppress setWifiEnabled(true) while xos owns the radio");
                                param.setResult(Boolean.TRUE);
                            }
                        } catch (Throwable t) {
                            warnThrottled("mishare:mask-setWifiEnabled-cb",
                                    "setWifiEnabled mask failed (ignored)", t);
                        }
                    }
                })) {
            wifiHooks++;
        }
        int receiverHooks = hookRegisterReceiver(cl);
        Log.i(TAG, "Loaded in MIShare: Wi-Fi state masking while " + EXCLUSIVE_PROP + "=1 (now "
                + exclusivePropValue() + "), WifiManager hooks=" + wifiHooks
                + ", registerReceiver hooks=" + receiverHooks
                + ", known MIShare versions={50401,50501}");
    }

    private static int hookRegisterReceiver(ClassLoader cl) {
        final Class<?> contextImpl;
        try {
            contextImpl = Class.forName("android.app.ContextImpl", false, cl);
        } catch (Throwable t) {
            warnThrottled("mishare:contextimpl",
                    "ContextImpl unavailable; WIFI_STATE_CHANGED dropping disabled", t);
            return 0;
        }
        final XC_MethodHook onRegister = new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                try {
                    if (param == null || param.args == null || param.args.length < 2) {
                        return;
                    }
                    Object receiver = param.args[0];
                    Object filter = param.args[1];
                    if (!(receiver instanceof BroadcastReceiver) || !(filter instanceof IntentFilter)) {
                        return;
                    }
                    if (!((IntentFilter) filter).hasAction(WifiManager.WIFI_STATE_CHANGED_ACTION)) {
                        return;
                    }
                    hookReceiver(receiver.getClass());
                } catch (Throwable t) {
                    warnThrottled("mishare:registerReceiver-cb",
                            "registerReceiver inspection failed (ignored)", t);
                }
            }
        };
        Method[] methods;
        try {
            methods = contextImpl.getDeclaredMethods();
        } catch (Throwable t) {
            warnThrottled("mishare:contextimpl-scan", "ContextImpl scan failed (ignored)", t);
            return 0;
        }
        int hooked = 0;
        for (Method m : methods) {
            try {
                if (m == null || !m.getName().startsWith("registerReceiver")) {
                    continue;
                }
                Class<?>[] types = m.getParameterTypes();
                if (types.length < 2 || types[0] != BroadcastReceiver.class
                        || types[1] != IntentFilter.class) {
                    continue;
                }
                if (hookQuietly("mishare:registerReceiver-hook", m, onRegister)) {
                    hooked++;
                }
            } catch (Throwable t) {
                warnThrottled("mishare:registerReceiver-scan",
                        "registerReceiver scan failed (ignored)", t);
            }
        }
        return hooked;
    }

    private static void hookReceiver(Class<?> receiverClass) {
        try {
            if (receiverClass == null || !HOOKED_RECEIVERS.add(receiverClass)) {
                return;
            }
            final String receiverName = receiverClass.getName();
            Class<?> c = receiverClass;
            while (c != null && c != BroadcastReceiver.class) {
                Method onReceive = findDeclaredMethod(c, "onReceive", Context.class, Intent.class);
                if (onReceive == null) {
                    c = c.getSuperclass();
                    continue;
                }
                if (hookQuietly("mishare:onReceive:" + receiverName, onReceive, new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        try {
                            if (param == null || param.args == null || param.args.length < 2) {
                                return;
                            }
                            Object intent = param.args[1];
                            if (!(intent instanceof Intent)) {
                                return;
                            }
                            Intent i = (Intent) intent;
                            if (!WifiManager.WIFI_STATE_CHANGED_ACTION.equals(i.getAction())) {
                                return;
                            }
                            if (!ownsRadio()) {
                                return;
                            }
                            int state = i.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1);
                            infoThrottled("mishare:drop:" + receiverName,
                                    "drop WIFI_STATE_CHANGED (state=" + state + ") for " + receiverName);
                            param.setResult(null);
                        } catch (Throwable t) {
                            warnThrottled("mishare:onReceive-cb:" + receiverName,
                                    "WIFI_STATE_CHANGED drop failed (ignored)", t);
                        }
                    }
                })) {
                    Log.i(TAG, "hooked Wi-Fi state receiver " + receiverName);
                }
                return;
            }
        } catch (Throwable t) {
            warnThrottled("mishare:receiver:" + (receiverClass == null ? "null" : receiverClass.getName()),
                    "receiver hook failed (ignored)", t);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // sys.xos.exclusive
    // ---------------------------------------------------------------------------------------------

    static boolean ownsRadio() {
        try {
            Method get = systemPropertiesGet();
            if (get == null) {
                return false;
            }
            Object value = get.invoke(null, EXCLUSIVE_PROP, "");
            return "1".equals(value);
        } catch (Throwable t) {
            return false;
        }
    }

    static String exclusivePropValue() {
        try {
            Method get = systemPropertiesGet();
            if (get == null) {
                return "<unavailable>";
            }
            return String.valueOf(get.invoke(null, EXCLUSIVE_PROP, "<empty>"));
        } catch (Throwable t) {
            return "<error " + t.getClass().getSimpleName() + ">";
        }
    }

    private static Method systemPropertiesGet() {
        Method cached = sSystemPropertiesGet;
        if (cached != null) {
            return cached;
        }
        try {
            Method get = Class.forName("android.os.SystemProperties")
                    .getMethod("get", String.class, String.class);
            sSystemPropertiesGet = get;
            return get;
        } catch (Throwable t) {
            return null;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Advanced hook: Apple Live Photo (.pvt JPEG + MOV) -> Motion Photo JPEG
    // ---------------------------------------------------------------------------------------------

    /**
     * MIShare unpacks an Apple Live Photo (.pvt) into a separate JPEG and MOV. Its upload handler
     * {@code a.k1#d(ArrayList)} of 5.4.1 commits the staged files (rename into the inbox), then answers
     * HTTP 200 and hands the committed list to AirDropService for media scanning. Before that commit,
     * replace each JPEG+MOV pair carrying the same Apple pairing UUID with one Motion Photo JPEG (the
     * format of Xiaomi Gallery's own MVIMG_*.jpg). Any failure leaves the list and the files untouched.
     *
     * <p>Obfuscated class names change between MIShare builds, so this is a candidate list probed one
     * by one. Xposed cannot enumerate classes of the target ClassLoader; add verified entries to
     * {@link #LIVE_PHOTO_COMMIT_CANDIDATES_EXTRA} for other builds. When nothing matches the feature is
     * disabled, never fatal.
     */
    private static final String[][] LIVE_PHOTO_COMMIT_CANDIDATES = {
            // MIShare 5.4.1 (versionCode 50401) on pandora/houji-class OS4 builds.
            {"a.k1", "d", "java.util.ArrayList"},
    };

    /**
     * Empty by design: reserved candidate list for MIShare builds whose obfuscation map differs from
     * 5.4.1. Entries have the same shape as {@link #LIVE_PHOTO_COMMIT_CANDIDATES}; empty means "probe
     * only the 5.4.1 candidate and stay hands-off otherwise".
     */
    private static final String[][] LIVE_PHOTO_COMMIT_CANDIDATES_EXTRA = {};

    private static final long LIVE_MOV_MAX = 48L << 20;


    /**
     * MIShare 5.5.0 保持 STA 连接（官方并发设计）：启动 XOS 前，其 WifiConflictManager 会断开
     * 5 GHz STA 并最多等 2 秒的 DISCONNECTED；超时则 AWDL 启动失败并重试。我们的 radio 后端
     * 会整个关掉 Wi-Fi，所以这一步只会带来掉线/重连和 2-10 秒延迟。该 manager 是 AwdlManager
     * 里持有 WifiManager 的字段，它唯一的无参 boolean 方法就是“STA 已离开 5 GHz”检查，直接返回 true。
     */
    private static void hookSkipStaHandoff(ClassLoader cl) throws Throwable {
        Class<?> awdl = Class.forName("com.xiaomi.sharop.awdl.AwdlManager", false, cl);
        java.lang.reflect.Method leave = null;
        for (java.lang.reflect.Field f : awdl.getDeclaredFields()) {
            Class<?> t = f.getType();
            if (t.isPrimitive() || t.getName().startsWith("java.") || t.getName().startsWith("android.")) {
                continue;
            }
            boolean hasWifi = false;
            for (java.lang.reflect.Field g : t.getDeclaredFields()) {
                if (g.getType() == android.net.wifi.WifiManager.class) {
                    hasWifi = true;
                }
            }
            if (!hasWifi) {
                continue;
            }
            for (java.lang.reflect.Method m : t.getDeclaredMethods()) {
                if (m.getReturnType() == boolean.class
                        && m.getParameterTypes().length == 0
                        && !java.lang.reflect.Modifier.isStatic(m.getModifiers())) {
                    if (leave != null) {
                        throw new IllegalStateException("ambiguous " + leave + " / " + m);
                    }
                    leave = m;
                }
            }
        }
        if (leave == null) {
            throw new NoSuchMethodException("WifiConflictManager leave-5GHz check");
        }
        XposedBridge.hookMethod(leave, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                Log.i(TAG, "skip STA 5 GHz handoff (radio backend turns Wi-Fi off)");
                param.setResult(true);
            }
        });
        Log.i(TAG, "Loaded in MIShare: STA handoff bypass on "
                + leave.getDeclaringClass().getName() + "." + leave.getName());
    }


    // ------------------------------------------------------------------
    // MiShare 进程内的 mDNS 主动发现（实验）
    //
    // MiShare 5.5.0 的 RawMdnsBrowser 只 join ff02::fb 监听，从不发 PTR 查询；
    // 而 iPhone 只有在收到查询、且双方都在活跃 AirDrop 状态时才会回应。这里用
    // MiShare 自己的 xos0 Network 绑定一个 MulticastSocket，周期发 QU 查询，
    // 并把收到的单播响应再组播一份给 RawMdnsBrowser。
    // ------------------------------------------------------------------
    private static volatile boolean sMdnsProbeStarted = false;

    private static String xosExclusiveValue() {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            return (String) sp.getMethod("get", String.class).invoke(null, "sys.xos.exclusive");
        } catch (Throwable t) {
            return null;
        }
    }

    private static void startMdnsProbe() {
        if (sMdnsProbeStarted) return;
        sMdnsProbeStarted = true;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                Log.i(TAG, "mDNS probe thread started");
                while (true) {
                    try {
                        if (!"1".equals(xosExclusiveValue())) {
                            Thread.sleep(500);
                            continue;
                        }
                        runMdnsProbeSession();
                    } catch (Throwable e) {
                        Log.w(TAG, "mDNS probe session error: " + e);
                        try { Thread.sleep(1500); } catch (InterruptedException ignored) { }
                    }
                }
            }
        }, "XosMdnsProbe");
        t.setDaemon(true);
        t.start();
    }

    private static byte[] buildPtrQuery(boolean qu) {
        byte[] q = new byte[] {
            0, 0, 0, 0,             // ID, flags (query)
            0, 1, 0, 0, 0, 0, 0, 0, // QD=1
            8, '_', 'a', 'i', 'r', 'd', 'r', 'o', 'p',
            4, '_', 't', 'c', 'p',
            5, 'l', 'o', 'c', 'a', 'l', 0,
            0, 12,                  // PTR
            (byte) (qu ? 0x80 : 0x00), (byte) (qu ? 0x81 : 0x01),
        };
        return q;
    }

    private static void runMdnsProbeSession() throws Throwable {
        Object app = Class.forName("android.app.ActivityThread")
                .getMethod("currentApplication").invoke(null);
        if (!(app instanceof android.content.Context)) {
            Thread.sleep(1000);
            return;
        }
        android.content.Context ctx = (android.content.Context) app;
        if (!MISHARE_PKG.equals(ctx.getPackageName())) {
            Thread.sleep(3000);
            return;
        }
        // MiShare 有多个进程；只在主进程跑一份，避免两套探测线程互相扇出放大。
        String proc = null;
        try {
            proc = (String) Class.forName("android.app.ActivityThread")
                    .getMethod("currentProcessName").invoke(null);
        } catch (Throwable ignored) { }
        if (proc == null) {
            try {
                java.io.FileInputStream fis = new java.io.FileInputStream("/proc/self/cmdline");
                byte[] b = new byte[256];
                int n = fis.read(b);
                fis.close();
                if (n > 0) {
                    int z = 0;
                    while (z < n && b[z] != 0) z++;
                    proc = new String(b, 0, z, "UTF-8");
                }
            } catch (Throwable ignored) { }
        }
        if (proc != null && !MISHARE_PKG.equals(proc)) {
            Thread.sleep(3000);
            return;
        }

        android.net.ConnectivityManager cm = (android.net.ConnectivityManager)
                ctx.getSystemService(android.content.Context.CONNECTIVITY_SERVICE);
        if (cm == null) { Thread.sleep(500); return; }

        android.net.Network target = null;
        for (android.net.Network n : cm.getAllNetworks()) {
            android.net.LinkProperties l = cm.getLinkProperties(n);
            if (l != null && "xos0".equals(l.getInterfaceName())) { target = n; break; }
        }
        if (target == null) { Thread.sleep(200); return; }
        java.net.NetworkInterface nif = java.net.NetworkInterface.getByName("xos0");
        if (nif == null) { Thread.sleep(500); return; }
        java.net.Inet6Address local = null;
        for (java.net.InterfaceAddress ia : nif.getInterfaceAddresses()) {
            if (ia.getAddress() instanceof java.net.Inet6Address) {
                java.net.Inet6Address a6 = (java.net.Inet6Address) ia.getAddress();
                if (a6.isLinkLocalAddress()) { local = a6; break; }
            }
        }
        if (local == null) { Thread.sleep(500); return; }
        final byte[] localBytes = local.getAddress();
        java.net.Inet6Address group = java.net.Inet6Address.getByAddress(
                null, new byte[] { (byte) 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte) 0xfb },
                nif.getIndex());
        if (group == null) { Thread.sleep(500); return; }

        java.nio.channels.DatagramChannel ch = null;
        try {
            ch = java.nio.channels.DatagramChannel.open(java.net.StandardProtocolFamily.INET6);
            ch.setOption(java.net.StandardSocketOptions.SO_REUSEADDR, Boolean.TRUE);
            target.bindSocket(ch.socket());
            ch.setOption(java.net.StandardSocketOptions.IP_MULTICAST_IF, nif);
            ch.setOption(java.net.StandardSocketOptions.IP_MULTICAST_LOOP, Boolean.TRUE);
            ch.socket().bind(new java.net.InetSocketAddress(5353));
            ch.join(group, nif);
            ch.configureBlocking(false);
            Log.i(TAG, "mDNS probe ready on xos0 " + local);

            long start = System.currentTimeMillis();
            long nextq = 0, fanoutWinStart = -1000;
            int queries = 0, rx = 0, fanout = 0, fanoutWin = 0, logged = 0;
            java.nio.ByteBuffer rbuf = java.nio.ByteBuffer.allocate(4096);
            java.net.InetSocketAddress dst = new java.net.InetSocketAddress(group, 5353);
            java.util.LinkedHashMap<Long, Long> seen = new java.util.LinkedHashMap<Long, Long>() {
                @Override
                protected boolean removeEldestEntry(java.util.Map.Entry<Long, Long> e) {
                    return size() > 64;
                }
            };
            while ("1".equals(xosExclusiveValue()) && System.currentTimeMillis() - start < 120000) {
                long now = System.currentTimeMillis();
                if (now >= nextq) {
                    byte[] q = buildPtrQuery((queries++ & 1) == 0);
                    try { ch.send(java.nio.ByteBuffer.wrap(q), dst); } catch (Throwable e) { }
                    nextq = now + (now - start < 1200 ? 120 : (now - start < 3000 ? 300 : 1200));
                }
                rbuf.clear();
                java.net.SocketAddress from = ch.receive(rbuf);
                if (from == null) { Thread.sleep(15); continue; }
                rx++;
                rbuf.flip();
                int len = rbuf.remaining();
                byte[] data = new byte[len];
                rbuf.get(data);
                if (len < 12 || (data[2] & 0x80) == 0) continue;
                // 跳过自己发出的包（多进程时也可能来自同机另一 socket）
                boolean self = false;
                if (from instanceof java.net.InetSocketAddress) {
                    java.net.InetAddress a = ((java.net.InetSocketAddress) from).getAddress();
                    if (a instanceof java.net.Inet6Address
                            && java.util.Arrays.equals(a.getAddress(), localBytes)) {
                        self = true;
                    }
                }
                if (self) continue;
                long h = 0;
                int n = Math.min(len, 48);
                for (int k = 0; k < n; k++) h = h * 31 + (data[k] & 0xff);
                Long last = seen.get(h);
                long t = System.currentTimeMillis();
                if (last != null && t - last < 3000) continue;
                // 限速：最多 10 次/秒
                if (t - fanoutWinStart >= 1000) { fanoutWinStart = t; fanoutWin = 0; }
                if (fanoutWin >= 10) continue;
                seen.put(h, t);
                fanoutWin++;
                try { ch.send(java.nio.ByteBuffer.wrap(data), dst); fanout++; } catch (Throwable e) { }
                if (logged < 5) {
                    logged++;
                    Log.i(TAG, "mDNS response from " + from + " len=" + len + " fanout#" + fanout);
                }
            }
            Log.i(TAG, "mDNS probe done rx=" + rx + " fanout=" + fanout + " queries=" + queries);
        } finally {
            if (ch != null) { try { ch.close(); } catch (Throwable ignored) { } }
        }
    }


    private static final java.util.Set<Object> CTA_GATE_DONE =
            java.util.Collections.newSetFromMap(new java.util.WeakHashMap<Object, Boolean>());


    private static void hookLivePhoto(ClassLoader cl) {
        if (!LIVE_PHOTO_INSTALLED.compareAndSet(false, true)) {
            return;
        }
        for (String[][] group : new String[][][] {
                LIVE_PHOTO_COMMIT_CANDIDATES, LIVE_PHOTO_COMMIT_CANDIDATES_EXTRA}) {
            for (String[] candidate : group) {
                try {
                    if (hookLivePhotoCandidate(cl, candidate)) {
                        return;
                    }
                } catch (Throwable t) {
                    warnThrottled("livephoto:candidate:"
                                    + (candidate != null && candidate.length > 0 ? candidate[0] : "?"),
                            "Live Photo candidate probe failed (ignored)", t);
                }
            }
        }
        warnThrottled("livephoto:none", "no Live Photo commit candidate matched this MIShare build;"
                + " Live Photo synthesis disabled (Wi-Fi state masking stays active)");
    }

    private static boolean hookLivePhotoCandidate(ClassLoader cl, String[] candidate) {
        if (candidate == null || candidate.length < 2 || candidate[0] == null
                || candidate[1] == null) {
            return false;
        }
        final Class<?> owner;
        try {
            owner = Class.forName(candidate[0], false, cl);
        } catch (Throwable t) {
            infoThrottled("livephoto:class:" + candidate[0],
                    "Live Photo candidate class " + candidate[0] + " not present");
            return false;
        }
        String paramType = candidate.length > 2 ? candidate[2] : null;
        Method commit = findSingleParamMethod(owner, candidate[1], paramType);
        if (commit == null) {
            infoThrottled("livephoto:method:" + candidate[0] + "#" + candidate[1],
                    "Live Photo candidate method " + candidate[0] + "#" + candidate[1] + " not found");
            return false;
        }
        final String label = candidate[0] + "#" + candidate[1];
        if (!hookQuietly("livephoto:hook:" + label, commit, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                try {
                    if (param == null || param.args == null || param.args.length == 0) {
                        return;
                    }
                    Object arg = param.args[0];
                    if (!(arg instanceof ArrayList)) {
                        return;
                    }
                    @SuppressWarnings("unchecked")
                    ArrayList<Object> files = (ArrayList<Object>) arg;
                    if (files.size() >= 2) {
                        mergeLivePhotos(files);
                    }
                } catch (Throwable t) {
                    warnThrottled("livephoto:merge-cb", "Live Photo merge skipped (ignored)", t);
                }
            }
        })) {
            return false;
        }
        Log.i(TAG, "Loaded in MIShare: Live Photo -> Motion Photo merge on " + label);
        return true;
    }

    /** One-parameter method whose parameter can hold an ArrayList (ArrayList or List parameter). */
    private static Method findSingleParamMethod(Class<?> owner, String name, String paramTypeName) {
        Class<?> want = null;
        if (paramTypeName != null) {
            if ("java.util.ArrayList".equals(paramTypeName)) {
                want = ArrayList.class;
            } else {
                try {
                    want = Class.forName(paramTypeName, false, owner.getClassLoader());
                } catch (Throwable ignored) {
                }
            }
        }
        Method[] methods;
        try {
            methods = owner.getDeclaredMethods();
        } catch (Throwable t) {
            return null;
        }
        if (methods == null) {
            return null;
        }
        for (Method m : methods) {
            try {
                if (m == null || !name.equals(m.getName())) {
                    continue;
                }
                Class<?>[] types = m.getParameterTypes();
                if (types.length != 1) {
                    continue;
                }
                Class<?> type = types[0];
                if (want != null) {
                    // Exact candidate signature (ArrayList), a subclass of it, or the usual
                    // collection supertypes that the commit handler may declare instead.
                    if (type.equals(want) || want.isAssignableFrom(type)) {
                        return m;
                    }
                    if ((type.equals(List.class) || type.equals(java.util.Collection.class)
                            || type.equals(Iterable.class)) && type.isAssignableFrom(want)) {
                        return m;
                    }
                } else if (ArrayList.class.isAssignableFrom(type)) {
                    return m;
                }
            } catch (Throwable ignored) {
            }
        }
        return null;
    }

    static void mergeLivePhotos(ArrayList<Object> files) {
        if (files == null) {
            return;
        }
        try {
            List<File> jpegs = new ArrayList<File>();
            List<File> movs = new ArrayList<File>();
            for (Object o : files) {
                if (!(o instanceof File)) {
                    return; // unexpected list shape: leave it alone
                }
                File f = (File) o;
                if (f == null) {
                    return;
                }
                String n = f.getName().toLowerCase(Locale.ROOT);
                if (n.endsWith(".jpg") || n.endsWith(".jpeg")) {
                    jpegs.add(f);
                } else if (n.endsWith(".mov") && f.length() > 0 && f.length() <= LIVE_MOV_MAX) {
                    movs.add(f);
                }
            }
            if (jpegs.isEmpty() || movs.isEmpty()) {
                return;
            }
            Map<File, Set<String>> jpegIds = new HashMap<File, Set<String>>();
            for (File j : jpegs) {
                try {
                    jpegIds.put(j, MotionPhoto.jpegUuids(j));
                } catch (Throwable t) {
                    jpegIds.put(j, Collections.<String>emptySet());
                }
            }
            for (File mov : movs) {
                try {
                    String id = MotionPhoto.movContentId(mov);
                    if (id == null) {
                        continue;
                    }
                    File jpeg = null;
                    for (File j : jpegs) {
                        Set<String> ids = jpegIds.get(j);
                        if (ids != null && ids.contains(id)) {
                            jpeg = j;
                            break;
                        }
                    }
                    if (jpeg == null) {
                        infoThrottled("livephoto:nopair:" + mov.getName(),
                                "Live Photo: no JPEG for " + mov.getName() + " id=" + id);
                        continue;
                    }
                    mergePair(files, jpegs, jpeg, mov, id);
                } catch (Throwable t) {
                    warnThrottled("livephoto:pair", "Live Photo pair merge failed (ignored)", t);
                }
            }
        } catch (Throwable t) {
            warnThrottled("livephoto:merge", "Live Photo merge skipped (ignored)", t);
        }
    }

    private static void mergePair(ArrayList<Object> files, List<File> jpegs, File jpeg, File mov,
            String id) {
        File parent = jpeg.getParentFile();
        if (parent == null) {
            parent = jpeg.getAbsoluteFile().getParentFile();
        }
        if (parent == null) {
            return;
        }
        File tmp = new File(parent, "." + jpeg.getName() + ".motion");
        try {
            MotionPhoto.Result r = MotionPhoto.merge(jpeg, mov, tmp, new OrientTranscoder());
            File backup = new File(parent, "." + jpeg.getName() + ".orig");
            if (!jpeg.renameTo(backup)) {
                throw new java.io.IOException("backup failed " + jpeg);
            }
            if (!tmp.renameTo(jpeg)) {
                if (!backup.renameTo(jpeg)) {
                    Log.e(TAG, "Live Photo: could not restore " + jpeg);
                }
                throw new java.io.IOException("replace failed " + jpeg);
            }
            backup.delete();
            int mi = files.indexOf(mov);
            if (mi >= 0) {
                files.remove(mi);
            }
            if (!mov.delete()) {
                infoThrottled("livephoto:rm:" + mov.getName(),
                        "Live Photo: could not delete staged " + mov);
            }
            jpegs.remove(jpeg);
            infoThrottled("livephoto:merged:" + jpeg.getName(),
                    "Live Photo merged " + jpeg.getName() + " + " + mov.getName() + " id=" + id
                            + " " + r);
        } catch (Throwable t) {
            try {
                tmp.delete();
            } catch (Throwable ignored) {
            }
            warnThrottled("livephoto:failed:" + jpeg.getName(),
                    "Live Photo merge failed for " + jpeg.getName() + " + " + mov.getName(), t);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Advanced hook: gallery share grid -> standard AirDrop activity dispatch
    // ---------------------------------------------------------------------------------------------

    /** The gallery share grid starts MIShare's AirDrop trampoline with a URI-grant-preserving mode. */
    private static void hookIntentResolver(ClassLoader cl) {
        if (!RESOLVER_INSTALLED.compareAndSet(false, true)) {
            return;
        }
        final Class<?> stub;
        try {
            stub = Class.forName("com.android.intentresolver.ChooserActivityStubImpl", false, cl);
        } catch (Throwable t) {
            warnThrottled("resolver:stub", "IntentResolver gallery fix unavailable:"
                    + " ChooserActivityStubImpl missing", t);
            return;
        }
        Method checkStart = findDeclaredMethod(stub, "checkStartGalleryActivity", int.class,
                String.class, List.class);
        final Field targetInfoField = findField(stub, "mTargetInfo");
        final Method resolvedComponent = findNoArgMethod(
                loadClass(cl, "com.android.intentresolver.chooser.TargetInfo"),
                "getResolvedComponentName");
        if (checkStart == null) {
            warnThrottled("resolver:method", "IntentResolver gallery fix unavailable:"
                    + " checkStartGalleryActivity(int,String,List) missing");
            return;
        }
        if (targetInfoField == null || resolvedComponent == null) {
            warnThrottled("resolver:target", "IntentResolver gallery fix unavailable:"
                    + " target info member missing (mTargetInfo=" + (targetInfoField != null)
                    + ", getResolvedComponentName=" + (resolvedComponent != null) + ")");
            return;
        }
        if (hookQuietly("resolver:checkStartGalleryActivity", checkStart, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                try {
                    Object[] args = param == null ? null : param.args;
                    if (args == null || args.length < 3) {
                        return;
                    }
                    Object mode = args[0];
                    Object pkg = args[1];
                    if (!(mode instanceof Integer) || ((Integer) mode).intValue() != 0) {
                        return;
                    }
                    if (!(pkg instanceof String) || !MISHARE_PKG.equals(pkg)) {
                        return;
                    }
                    if (!fromChooserGrid()) {
                        return;
                    }
                    if (param.thisObject == null) {
                        return;
                    }
                    Object selected = targetInfoField.get(param.thisObject);
                    if (selected == null) {
                        return;
                    }
                    Object resolved = resolvedComponent.invoke(selected);
                    if (!(resolved instanceof ComponentName)) {
                        return;
                    }
                    ComponentName component = (ComponentName) resolved;
                    if (!MISHARE_PKG.equals(component.getPackageName())
                            || !AIRDROP_TRAMPOLINE.equals(component.getClassName())) {
                        return;
                    }
                    args[0] = Integer.valueOf(2);
                    infoThrottled("resolver:patched",
                            "gallery AirDrop target: standard activity dispatch (mode 0 -> 2)");
                } catch (Throwable t) {
                    warnThrottled("resolver:callback",
                            "gallery AirDrop dispatch fix skipped (ignored)", t);
                }
            }
        })) {
            return;
        }
        Log.i(TAG, "Loaded in IntentResolver: gallery AirDrop dispatch");
    }

    private static boolean fromChooserGrid() {
        try {
            StackTraceElement[] stack = Thread.currentThread().getStackTrace();
            if (stack == null) {
                return false;
            }
            for (StackTraceElement frame : stack) {
                if (frame == null) {
                    continue;
                }
                String cls = frame.getClassName();
                if ("com.android.intentresolver.adapter.MiuiChooserGridAdapter".equals(cls)
                        && "startSelected".equals(frame.getMethodName())) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static Class<?> loadClass(ClassLoader cl, String name) {
        try {
            return Class.forName(name, false, cl);
        } catch (Throwable t) {
            return null;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reflection + logging helpers (all exception-isolated)
    // ---------------------------------------------------------------------------------------------

    private static Method findDeclaredMethod(Class<?> owner, String name, Class<?>... params) {
        if (owner == null) {
            return null;
        }
        for (Class<?> c = owner; c != null; c = c.getSuperclass()) {
            try {
                return c.getDeclaredMethod(name, params);
            } catch (NoSuchMethodException ignored) {
            } catch (Throwable t) {
                return null;
            }
        }
        return null;
    }

    private static Method findNoArgMethod(Class<?> owner, String name) {
        if (owner == null) {
            return null;
        }
        for (Class<?> c = owner; c != null; c = c.getSuperclass()) {
            try {
                Method m = c.getDeclaredMethod(name);
                try {
                    m.setAccessible(true);
                } catch (Throwable ignored) {
                }
                return m;
            } catch (NoSuchMethodException ignored) {
            } catch (Throwable t) {
                return null;
            }
        }
        try {
            return owner.getMethod(name);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static Field findField(Class<?> owner, String name) {
        if (owner == null) {
            return null;
        }
        for (Class<?> c = owner; c != null && c != Object.class; c = c.getSuperclass()) {
            try {
                Field f = c.getDeclaredField(name);
                try {
                    f.setAccessible(true);
                } catch (Throwable ignored) {
                }
                return f;
            } catch (NoSuchFieldException ignored) {
            } catch (Throwable t) {
                return null;
            }
        }
        return null;
    }

    private static boolean hookQuietly(String key, Method method, XC_MethodHook callback) {
        if (method == null) {
            warnThrottled(key, "hook target missing: " + key);
            return false;
        }
        try {
            XposedBridge.hookMethod(method, callback);
            return true;
        } catch (Throwable t) {
            warnThrottled(key, "hook failed: " + method, t);
            return false;
        }
    }

    private static void infoThrottled(String key, String message) {
        try {
            if (Throttle.allow(key)) {
                Log.i(TAG, message);
            }
        } catch (Throwable ignored) {
        }
    }

    private static void warnThrottled(String key, String message) {
        try {
            if (Throttle.allow(key)) {
                Log.w(TAG, message);
            }
        } catch (Throwable ignored) {
        }
    }

    private static void warnThrottled(String key, String message, Throwable t) {
        try {
            if (t == null) {
                warnThrottled(key, message);
                return;
            }
            if (Throttle.allow(key + "|" + t.getClass().getName())) {
                Log.w(TAG, message, t);
            }
        } catch (Throwable ignored) {
        }
    }

    /** Log rate limiter: the same key/exception is logged at most once per 60 seconds. */
    private static final class Throttle {
        private static final long WINDOW_MS = 60_000L;
        private static final int MAX_KEYS = 256;
        private static final Map<String, Long> LAST = new HashMap<String, Long>();

        private Throttle() {
        }

        static synchronized boolean allow(String key) {
            long now;
            try {
                now = SystemClock.elapsedRealtime();
            } catch (Throwable t) {
                now = System.currentTimeMillis();
            }
            Long last = LAST.get(key);
            if (last != null && now - last.longValue() < WINDOW_MS) {
                return false;
            }
            if (LAST.size() >= MAX_KEYS) {
                LAST.clear();
            }
            LAST.put(key, Long.valueOf(now));
            return true;
        }
    }
}
