package de.robv.android.xposed;

public abstract class XC_MethodHook {
    public XC_MethodHook() {}

    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {}

    public static class MethodHookParam {
        public Object thisObject;
        public Object[] args;

        public void setResult(Object result) {}
    }

    public class Unhook {}
}
