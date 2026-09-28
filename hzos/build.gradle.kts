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
    alias(libs.plugins.roborazzi) apply false
    alias(libs.plugins.spotless)
    alias(libs.plugins.detekt) apply false
}

// Formatting (audit M3): ktlint through Spotless, rules in .editorconfig.
// `./gradlew spotlessApply` fixes; `spotlessCheck` fails on drift (CI).
// Mirrors .editorconfig; Spotless does not reliably pick up every key
// from the file alone.
val ktlintOverrides = mapOf(
    "ktlint_code_style" to "android_studio",
    "ktlint_function_naming_ignore_when_annotated_with" to "Composable",
    "ktlint_standard_max-line-length" to "disabled",
    "max_line_length" to "off"
)

spotless {
    kotlin {
        target("app/src/**/*.kt")
        ktlint(libs.versions.ktlint.get())
            .setEditorConfigPath("$rootDir/.editorconfig")
            .editorConfigOverride(ktlintOverrides)
    }
    kotlinGradle {
        target("*.gradle.kts", "app/*.gradle.kts")
        ktlint(libs.versions.ktlint.get())
            .setEditorConfigPath("$rootDir/.editorconfig")
            .editorConfigOverride(ktlintOverrides)
    }
}
