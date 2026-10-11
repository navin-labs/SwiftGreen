plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.swiftgreen.app"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.swiftgreen.app"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    // Release signing is optional: set these in ~/.gradle/gradle.properties (never in the repo).
    // Without them, assembleRelease still produces an unsigned APK, as CI does.
    val releaseStoreFile = providers.gradleProperty("swiftgreen.storeFile").orNull
    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = providers.gradleProperty("swiftgreen.storePassword").get()
                keyAlias = providers.gradleProperty("swiftgreen.keyAlias").get()
                keyPassword = providers.gradleProperty("swiftgreen.keyPassword").get()
            }
        }
    }

    buildTypes {
        release {
            if (releaseStoreFile != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
        buildConfig = true   // Log.kt: release builds log no message text
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    testImplementation(libs.junit)
    debugImplementation(libs.androidx.compose.ui.tooling)

    // CameraX for QR Scanner
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    // ML Kit Barcode Scanning
    implementation(libs.mlkit.barcode.scanning)

    // BouncyCastle for X25519 on API < 31
    implementation(libs.bouncycastle.bcprov)

    // Photo orientation for gallery thumbnails (fixes for the framework ExifInterface on older APIs)
    implementation(libs.androidx.exifinterface)
}
