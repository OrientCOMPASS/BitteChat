import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// v0.5.17: CI supplies the release keystore via repository secrets
// (KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD ->
// normalized + exported as BC_* env by the "Release signing from repo
// secrets" step in .github/workflows/ci.yml). v0.5.18: no committed key
// anymore — local dev builds create key.properties via
// scripts/make-dev-keystore.sh; anything else is a configuration error.
val envStoreFile = System.getenv("BC_KEYSTORE_FILE")
val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "dev.orientcompass.bittechat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.orientcompass.bittechat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // API 28+: libtorrent/boost.asio need std::aligned_alloc (NDK, API 28)
        minSdk = 28
        // NB: deliberately NO `ndk { abiFilters }` here. Gradle rejects
        // abiFilters when ABI splits are enabled, and the release build uses
        // `flutter build apk --split-per-abi --target-platform
        // android-arm64,android-x64`, which drives the ABI set (arm64-v8a +
        // x86_64 — the only ones the native core is built for) via splits.
        // The packaging.jniLibs excludes below still keep armeabi-v7a out.
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // native core only ships for arm64-v8a + x86_64
            excludes += setOf("lib/armeabi-v7a/**")
        }
    }

    signingConfigs {
        create("release") {
            if (!envStoreFile.isNullOrEmpty()) {
                // CI: resolved + normalized credentials from the secrets step
                storeFile = file(envStoreFile)
                storePassword = System.getenv("BC_STORE_PASSWORD")
                keyAlias = System.getenv("BC_KEY_ALIAS")
                keyPassword = System.getenv("BC_KEY_PASSWORD")
            } else if (keyPropertiesFile.exists()) {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            } else {
                // v0.5.18: no committed signing key anymore. CI exports BC_*
                // from the repository secrets; local dev creates
                // key.properties via scripts/make-dev-keystore.sh.
                throw GradleException(
                    "No release signing config found. CI: configure the " +
                    "KEYSTORE_* repository secrets. Local: run " +
                    "scripts/make-dev-keystore.sh (writes key.properties).",
                )
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
