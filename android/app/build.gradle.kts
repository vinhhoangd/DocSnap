import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// API URL, app token and signing passwords live in the git-ignored local.properties.
val local = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun localValue(key: String): String = local.getProperty(key, "")

android {
    namespace = "com.vinhhoang.docsnap"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.vinhhoang.docsnap"
        // Android 8.0+: covers Samsung phones from 2017 on.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-test"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Phones (Samsung included) are ARM; dropping x86 halves the bundled OCR engine's size.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
        buildConfigField("String", "API_URL", "\"${localValue("docsnap.apiUrl")}\"")
        buildConfigField("String", "APP_TOKEN", "\"${localValue("docsnap.appToken")}\"")
    }

    signingConfigs {
        create("release") {
            val store = rootProject.file("keystore/docsnap-release.jks")
            if (store.exists()) {
                storeFile = store
                storePassword = localValue("docsnap.keystorePassword")
                keyAlias = "docsnap"
                keyPassword = localValue("docsnap.keystorePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release").takeIf { it.storeFile != null }
                ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions { unitTests.isReturnDefaultValues = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // CamScanner-style capture: live edge detection, auto-capture, border adjusting (Google Play services).
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0-beta1")
    // On-device OCR; the Latin model reads Vietnamese diacritics. Bundled, so it works offline.
    implementation("com.google.mlkit:text-recognition:16.0.1")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.json:json:20240303")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
