import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// Flutter passes Dart defines to Gradle as base64 strings. One flag controls
// both native packaging and Dart capability gates, so the profiles cannot drift.
val dartDefines = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.filter { it.isNotEmpty() }
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?: emptyList()
val legacyArm32 = dartDefines.contains("LEGACY_ARM32=true")
val allowTestSigning = System.getenv("MESHCORE_ALLOW_TEST_SIGNING") == "1"

android {
    namespace = "com.meshcore.meshcore_open"
    compileSdk = 36
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.meshcore.meshcore_open"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The packaged llama.cpp translation libraries are built for API 28.
        minSdk = if (legacyArm32) 21 else 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Codec2 native build removed - no longer needed
        // externalNativeBuild {
        //     cmake {
        //         arguments += listOf("-DANDROID_STL=c++_shared")
        //     }
        // }
        // Keep the modern app 64-bit: its inference runtimes need that address
        // space. The API 22 phone receives the dedicated ARMv7 build.
        ndk {
            abiFilters += if (legacyArm32) listOf("armeabi-v7a")
                else listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else if (allowTestSigning) {
                signingConfigs.getByName("debug")
            } else {
                null
            }
            // ONNX Runtime resolves its Java classes from native code by name.
            // Without these rules R8 renames them and the process SIGABRTs with
            // "java_class == null" the instant the codec runs a model.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Codec2 native build removed - no longer needed
    // externalNativeBuild {
    //     cmake {
    //         path = file("src/main/cpp/CMakeLists.txt")
    //     }
    // }
}

// Do not silently label a debug-signed APK as a distributable release.
tasks.matching { it.name == "validateSigningRelease" || it.name == "packageRelease" }
    .configureEach {
        doFirst {
            check(keystorePropertiesFile.exists() || allowTestSigning) {
                "Release signing is missing. Configure android/key.properties or " +
                    "explicitly set MESHCORE_ALLOW_TEST_SIGNING=1 for sideload testing."
            }
        }
    }

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
