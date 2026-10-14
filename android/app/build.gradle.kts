import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val codecDartDefines = providers.gradleProperty("dart-defines").getOrElse("")
    .split(",").mapNotNull { encoded ->
        runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
    }
val legacyArm32 = "LEGACY_ARM32=true" in codecDartDefines
val aeicTrial = "AEIC_TRIAL=true" in codecDartDefines ||
    providers.gradleProperty("meshcoreAeicTrial").map { it.equals("true", ignoreCase = true) }.getOrElse(false)
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.meshcore.meshcore_open"
    compileSdk = maxOf(36, flutter.compileSdkVersion)
    ndkVersion = "29.0.14206865"
    // Extract the PIE codec executable into Android's executable nativeLibraryDir.
    packaging {
        jniLibs.useLegacyPackaging = true
    }

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
        if (aeicTrial) applicationIdSuffix = ".aeictrial"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = if (legacyArm32) 21 else flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Codec2 native build removed - no longer needed
        // externalNativeBuild {
        //     cmake {
        //         arguments += listOf("-DANDROID_STL=c++_shared")
        //     }
        // }
        // API21 ARMv7 uses the established legacy dependency profile.
        // The modern profile keeps its configured minimum SDK and ARM64 ABI.
        ndk {
            abiFilters += if (legacyArm32) listOf("armeabi-v7a") else listOf("arm64-v8a")
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
            } else {
                signingConfigs.getByName("debug")
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

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
