plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

import java.util.Properties

// Horizon Platform app ID (developer portal → your app). Per-machine, read
// from hzos/local.properties as `platformAppId=` (gitignored); empty means
// phone sign-in is disabled and manual paste is the only path. The ID is
// public (embedded in the app), not a secret.
val platformAppId: String = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}.getProperty("platformAppId", "")

// Release-safe per-developer values (gitignored defaults.properties, see
// defaults.properties.sample). Namespace stays fixed so R/BuildConfig
// imports never move; only the store identity varies.
val developerDefaults = Properties().apply {
    val f = rootProject.file("defaults.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val defaultBaseUrl: String = developerDefaults.getProperty("defaultBaseUrl", "")
val configuredAppId: String =
    developerDefaults.getProperty("applicationId", "com.example.zerozerowidget.hzos")

android {
    namespace = "com.example.zerozerowidget.hzos"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        // Store identity comes from gitignored defaults.properties.
        // Keep com.example.* out of the store.
        applicationId = configuredAppId
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"

        // Horizon Platform app ID, read from local.properties above.
        buildConfigField(
            "String",
            "PLATFORM_APP_ID",
            "\"$platformAppId\"",
        )
        // Default Worker URL, read from defaults.properties above.
        buildConfigField(
            "String",
            "DEFAULT_BASE_URL",
            "\"$defaultBaseUrl\"",
        )
        // Default Worker URL (public production endpoint, safe to ship).
        buildConfigField(
            "String",
            "DEFAULT_BASE_URL",
            "\"$defaultBaseUrl\"",
        )
    }

    // Store signing. Keystore lives OUTSIDE the repo; point at it with env
    // (see hzos/README.md "Store submission"). Without these vars the
    // release build assembles unsigned — installable nowhere that matters.
    val hasReleaseKeystore = System.getenv("ZW_KEYSTORE_FILE") != null
    signingConfigs {
        create("release") {
            storeFile = System.getenv("ZW_KEYSTORE_FILE")?.let(::file)
            storePassword = System.getenv("ZW_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ZW_KEY_ALIAS")
            keyPassword = System.getenv("ZW_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // No dev credential field exists at all outside debug. The
            // Worker URL and Platform app ID are public configuration and
            // remain embedded; a release APK built without the keystore
            // below is unsigned and not submittable.
            if (hasReleaseKeystore) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.datastore.preferences)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // Horizon Platform SDK (Login API / send_auth_url delivery). Works in
    // plain activities; unrelated to any 3D SDK.
    implementation(libs.horizon.platform.core.kotlin)
    implementation(libs.horizon.platform.users.kotlin)
}
