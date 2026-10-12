import java.io.File
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Release signing uses the shared publisher key kept outside the repo
// (~/.apk-signing-keystore/signing.properties on the release machine, or the
// path in EMANATOR_SIGNING_PROPERTIES). Without it, release builds are unsigned.
val keystoreProperties = Properties().apply {
    val path = System.getenv("EMANATOR_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.apk-signing-keystore/signing.properties"
    val file = File(path)
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "today.cypherpunk.emanator"
    compileSdk = 37

    defaultConfig {
        applicationId = "today.cypherpunk.emanator"
        minSdk = 26
        targetSdk = 36
        // The server compares versionCode against config/emanator.yml →
        // android.min_version_code (X-Emanator-Client). Bump on every release.
        versionCode = 4
        versionName = "1.3.0"
        buildConfigField("String", "DEFAULT_SERVER", "\"https://emanator.cypherpunk.today\"")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // The app's own languages, matching the web (config/locales/*/{en,sk,cs,es}).
    androidResources {
        localeFilters += listOf("en", "sk", "cs", "es")
    }

    signingConfigs {
        if (keystoreProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // Reproducibility: no build-time VCS info baked into the APK.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.exifinterface)
    implementation(project(":nostr-signin"))
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.media3.common)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.zxing.core)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.mockwebserver)
}
