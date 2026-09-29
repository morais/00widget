# R8 rules for the hzos release build. Libraries ship their own consumer
# rules (kotlinx-serialization, OkHttp, Compose, UI Set); only gaps go here.

# Horizon Platform SDK (sign-in, send_auth_url, IAP). Its bridge to the
# OS-provided platform client uses reflection and it ships no keep rules of
# its own beyond a -dontwarn. Its checkout and account paths are hard to
# exercise in a test run, so it is kept whole rather than trusted to shrink:
# a few hundred classes, against a failure that would only show at runtime.
-keep class horizon.** { *; }
-dontwarn horizonos.**

# OkHttp probes for optional TLS providers (Conscrypt, BouncyCastle,
# OpenJSSE) and falls back to the platform when absent. The okhttp-jvm
# artifact this app uses does not carry the Android rules that normally
# silence these references.
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# Those probes only pass when that provider is installed first in the
# security provider list, which on Android is always the platform's own
# (AndroidOpenSSL), so OkHttp always picks Jdk9Platform here. Saying so
# lets R8 delete the three alternative platforms. The store's security
# scan flagged ConscryptPlatform's no-op DisabledHostnameVerifier as an
# "Insecure HostnameVerifier"; it is harmless (OkHttp verifies hostnames
# itself) and was never reachable, but it is now gone from the APK.
# okhttp-android, which lacks these classes, needs compileSdk 37.
-assumevalues class okhttp3.internal.platform.PlatformRegistry {
    private boolean isConscryptPreferred() return false;
    private boolean isBouncyCastlePreferred() return false;
    private boolean isOpenJSSEPreferred() return false;
}

# Nullability annotations referenced by the Platform SDK; compile-time only.
-dontwarn javax.annotation.**
