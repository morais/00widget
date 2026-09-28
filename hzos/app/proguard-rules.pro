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

# Nullability annotations referenced by the Platform SDK; compile-time only.
-dontwarn javax.annotation.**
