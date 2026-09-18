// Top-level build file for the Horizon OS (hzos) panel app.
//
// Toolchain: plain Android + Jetpack Compose, AGP 8.11, Kotlin 2.2.0. No
// engine, no Spatial SDK: panels are shell windows owned by Horizon OS (see
// hzos/README.md). AGP 8.11 needs Android Studio Narwhal (2025.1.1) *or
// later* — Quail is fine; IDE version and AGP version are independent.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
