import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Store builds are signed with the upload key named in key.properties, which
// stays out of git (FCW_KEY_PROPERTIES may point at it instead). Without it,
// release builds remain debug-signed local test builds.
val keyPropertiesPath: String? = System.getenv("FCW_KEY_PROPERTIES")
val keyPropertiesFile =
    keyPropertiesPath?.let { file(it) } ?: rootProject.file("key.properties")
// A named but missing file must not fall back to the debug key unnoticed.
if (keyPropertiesPath != null && !keyPropertiesFile.isFile) {
    throw GradleException("FCW_KEY_PROPERTIES is set, but $keyPropertiesFile is not a file")
}
val useUploadKey = keyPropertiesFile.isFile
val keyProperties = Properties().apply {
    if (useUploadKey) FileInputStream(keyPropertiesFile).use { load(it) }
}

// Names the missing entry only; signing values are never printed.
fun signingProperty(name: String): String =
    keyProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("$keyPropertiesFile is missing a value for $name")

android {
    namespace = "com.coldwallet.vault"
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
        applicationId = "com.coldwallet.vault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(28, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Every packaged ABI needs both Flutter and the FCW native core.
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }
    }

    signingConfigs {
        if (useUploadKey) {
            create("upload") {
                keyAlias = signingProperty("keyAlias")
                keyPassword = signingProperty("keyPassword")
                // A relative storeFile is relative to key.properties itself.
                storeFile = keyPropertiesFile.absoluteFile.parentFile
                    .resolve(signingProperty("storeFile"))
                storePassword = signingProperty("storePassword")
            }
        }
    }

    buildTypes {
        configureEach {
            // Flutter seeds build-type filters; AGP merges them with defaultConfig.
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
            }
        }
        release {
            signingConfig = signingConfigs.getByName(if (useUploadKey) "upload" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
