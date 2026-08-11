pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    // Pinned to 2.2.0 (down from the template's 2.3.20) — share_plus (and
    // other plugins still applying their own kotlin-android, e.g.
    // wakelock_plus) declare that version themselves, but Gradle resolves a
    // single kotlin-android plugin version project-wide, and whichever
    // version wins ends up compiling every module's Kotlin sources. With
    // 2.3.20 winning, share_plus's own source files failed with spurious
    // "Unresolved reference" errors on symbols defined in the very same
    // module/package — reproduced identically across share_plus 11.1.0,
    // 12.0.2, and 13.3.0, so it's a toolchain version mismatch, not a
    // share_plus bug. See pubspec.yaml's share_plus comment.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
