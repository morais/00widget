import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
    alias(libs.plugins.detekt)
}

// Horizon Platform app ID (developer portal → your app). Per-machine, read
// from hzos/local.properties as `platformAppId=` (gitignored); empty means
// phone sign-in is disabled and manual paste is the only path. The ID is
// public (embedded in the app), not a secret.
val platformAppId: String = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}.getProperty("platformAppId", "")

// Release-safe per-developer values (gitignored defaults.properties, see
// defaults.properties.sample). Namespace is the store identity, so R and
// BuildConfig live next to the code that imports them.
val developerDefaults = Properties().apply {
    val f = rootProject.file("defaults.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
// Store listing metadata (gitignored store.properties; see the sample).
// Public URLs, safe to embed; blank hides the row.
val storeProps = Properties().apply {
    val f = rootProject.file("store.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val defaultBaseUrl: String = developerDefaults.getProperty("defaultBaseUrl", "")
val configuredAppId: String =
    developerDefaults.getProperty("applicationId", "com.zerozerowidget.hzos")

android {
    namespace = "com.zerozerowidget.hzos"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        // Store identity comes from gitignored defaults.properties.
        // Never point it at com.example.*.
        applicationId = configuredAppId
        minSdk = libs.versions.minSdk.get().toInt()
        // 34, not 36: the store warns that Horizon OS supports up to API 34.
        // compileSdk stays ahead for the build; runtime behavior targets 34.
        targetSdk = 34
        // Visible version is fixed per release line; the build number is
        // UTC date/time (ISO basic, hour precision). Full ISO doesn't fit:
        // versionCode is a signed 32-bit int, and yyyyMMddHHmm already
        // overflows it — yyyyMMddHH fits until 2038.
        //
        // A store build passes it in (-PversionCode, see upload-store.sh).
        // The configuration cache is on, and the clock is not one of its
        // inputs: a rebuild at a later hour with nothing else changed
        // reused the cached configuration and kept the earlier hour, an
        // unuploadable duplicate. A Gradle property is an input, so an
        // explicit value always lands. The clock stays as the fallback for
        // local builds, where a stale hour is harmless.
        versionCode = providers.gradleProperty("versionCode").orNull?.toInt()
            ?: ZonedDateTime.now(ZoneOffset.UTC)
                .format(DateTimeFormatter.ofPattern("yyyyMMddHH"))
                .toInt()
        versionName = "1.5"
        // Quest and Meta VR Glasses are arm64-only, and Glasses refuses a
        // binary without 64-bit native code. Say so explicitly instead of
        // shipping armeabi-v7a/x86/x86_64 copies of AndroidX's .so files.
        ndk { abiFilters += "arm64-v8a" }
        // Short commit hash for the About screen, so a screenshot proves
        // which source a build came from. versionCode alone cannot: its
        // hour precision collides across same-hour builds, which is how
        // three different builds all reported 2026092812. providers.exec
        // (not raw ProcessBuilder) keeps this configuration-cache safe.
        val gitSha: String = try {
            providers.exec {
                commandLine("git", "rev-parse", "--short", "HEAD")
                workingDir(rootProject.projectDir.parentFile)
            }.standardOutput.asText.get().trim()
                .takeIf { it.matches(Regex("[0-9a-f]+")) } ?: "unknown"
        } catch (_: Exception) {
            "unknown"
        }
        buildConfigField("String", "GIT_SHA", "\"$gitSha\"")

        // Horizon Platform app ID, read from local.properties above.
        buildConfigField(
            "String",
            "PLATFORM_APP_ID",
            "\"$platformAppId\""
        )
        // Default Worker URL, read from defaults.properties above.
        buildConfigField(
            "String",
            "DEFAULT_BASE_URL",
            "\"$defaultBaseUrl\""
        )
        // Listing URLs, read from store.properties above. Blank hides rows.
        buildConfigField(
            "String",
            "PRIVACY_URL",
            "\"${storeProps.getProperty("PRIVACY_URL", "")}\""
        )
        buildConfigField(
            "String",
            "TERMS_URL",
            "\"${storeProps.getProperty("TERMS_URL", "")}\""
        )
        // Subscriptions (Meta IAP). Everything here comes from gitignored
        // store.properties (see store.properties.sample) — real SKU strings
        // must never be committed. Off unless explicitly enabled, so
        // ordinary builds neither show nor link the purchase flow.
        // Expected values for the flag are literally "true"/"false".
        buildConfigField(
            "boolean",
            "SUBSCRIPTIONS_ENABLED",
            "${storeProps.getProperty("SUBSCRIPTIONS_ENABLED", "false")}"
        )
        buildConfigField(
            "String",
            "SUBSCRIPTION_MONTHLY_SKU",
            "\"${storeProps.getProperty("SUBSCRIPTION_MONTHLY_SKU", "")}\""
        )
        buildConfigField(
            "String",
            "SUBSCRIPTION_YEARLY_SKU",
            "\"${storeProps.getProperty("SUBSCRIPTION_YEARLY_SKU", "")}\""
        )
    }

    // Store signing. Keystore lives OUTSIDE the repo; point at it with env
    // (see hzos/README.md "Publishing"). A release build without it would
    // be unsigned — installable nowhere that matters — so asking for one
    // fails here instead, unless -PallowUnsigned says that is intended.
    val hasReleaseKeystore = System.getenv("ZW_KEYSTORE_FILE") != null
    val releaseRequested = gradle.startParameter.taskNames.any { task ->
        listOf("assembleRelease", "bundleRelease", "packageRelease", "installRelease")
            .any { task.endsWith(it) }
    }
    if (releaseRequested && !hasReleaseKeystore && !providers.gradleProperty("allowUnsigned").isPresent) {
        throw GradleException(
            "Release build without a keystore would be unsigned. Set ZW_KEYSTORE_FILE " +
                "(+ _PASSWORD, ZW_KEY_ALIAS, ZW_KEY_PASSWORD), or pass -PallowUnsigned."
        )
    }
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
            // R8: the unminified release was 48.8 MB, 47 MB of it dex. Keep
            // rules live in proguard-rules.pro; every library but the
            // Horizon Platform SDK brings its own.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // No dev credential field exists at all outside debug. The
            // Worker URL and Platform app ID are public configuration and
            // remain embedded. Unsigned only with -PallowUnsigned (above).
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
    lint {
        // New warnings fail the build; the existing ones are listed in
        // lint-baseline.xml, to be burned down rather than grown. Regenerate
        // it only after fixing entries: ./gradlew :app:updateLintBaseline.
        baseline = file("lint-baseline.xml")
        warningsAsErrors = true
        abortOnError = true
        // These fire when someone else publishes a newer version, not when
        // this code changes, so as errors they would break CI at random.
        // Dependency updates are Dependabot's job; targetSdk 34 is
        // deliberate (Horizon OS supports up to API 34).
        disable += setOf(
            "GradleDependency",
            "NewerVersionAvailable",
            "AndroidGradlePluginVersion",
            "OldTargetApi"
        )
    }
    testOptions {
        // Robolectric needs merged resources for the screenshot test.
        unitTests.isIncludeAndroidResources = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            // OkHttp 5 (and okio) both ship this OSGi manifest; it is
            // metadata only and irrelevant on Android.
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
    }
}

dependencies {
    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    // MetaVRX BOM keeps Meta's Android artifacts mutually compatible;
    // artifacts it manages carry no version of their own.
    implementation(platform(libs.metavrx.bom))
    implementation(libs.metavrx.uiset.compose)
    androidTestImplementation(composeBom)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.datastore.preferences)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // Horizon Platform SDK (Login API / send_auth_url delivery). Works in
    // plain activities; unrelated to any 3D SDK.
    implementation(libs.horizon.platform.core.kotlin)
    implementation(libs.horizon.platform.users.kotlin)
    implementation(libs.horizon.platform.iap.kotlin)

    // JVM unit tests (src/test): pure decision logic only, no SDK, no device.
    testImplementation(libs.junit.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    // Layout screenshots on the JVM (PanelLayoutScreenshotTest): Robolectric
    // renders the real panels at every breakpoint width, Roborazzi records
    // and compares the PNGs. Test-only; nothing here ships.
    testImplementation(libs.robolectric)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(composeBom)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

// Static analysis (audit B7): detekt 2 (an alpha: 1.23 cannot run on this
// project's Kotlin 2.2 or on JDK 25), with its default rules, with detekt.yml
// adjusting the few that fight Compose, and today's findings in
// detekt-baseline.xml so new ones fail. Formatting is ktlint's job
// (Spotless), not detekt's.
detekt {
    buildUponDefaultConfig = true
    config.setFrom(rootProject.file("detekt.yml"))
    baseline = file("detekt-baseline.xml")
    source.setFrom("src/main/java", "src/test/java")
}
