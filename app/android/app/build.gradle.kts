plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.peervault"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.peervault"
        // Android's Autofill Framework (android.service.autofill.*, used by
        // PeerVaultAutofillService) requires API 26 (Android 8.0) at
        // minimum — this is a hard floor, not a preference, so it's set
        // explicitly rather than deferring to whatever Flutter's own
        // default happens to be.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Required by PeerVaultAutofillAuthActivity.kt (BiometricPrompt,
    // FragmentActivity) and AutofillBridge.kt / PeerVaultAutofillService.kt
    // (kotlinx.coroutines). These were imported by the Kotlin autofill code
    // without ever being declared here, which means the native Android
    // side could not have compiled at all — this is very likely the actual
    // reason autofill "isn't working": there was no working APK containing
    // this code to begin with.
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.fragment:fragment-ktx:1.6.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}



flutter {
    source = "../.."
}
