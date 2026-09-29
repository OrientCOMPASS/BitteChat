plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
            // STABLE project signing key, committed on purpose: BitteChat is
            // public-domain (Unlicense) and distributed via GitHub Releases,
            // so a fixed, transparent key lets users UPGRADE IN PLACE. (The
            // old debug-key signing produced a different signature on every
            // CI runner => INSTALL_FAILED_UPDATE_INCOMPATIBLE => forced
            // uninstall/reinstall each release.)
            storeFile = file("../keystore/release.jks")
            storePassword = "bittechat"
            keyAlias = "bittechat"
            keyPassword = "bittechat"
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
