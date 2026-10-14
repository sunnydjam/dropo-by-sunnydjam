import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter forwards its Dart defines as an explicit -Pdart-defines argument.
// Decode that same flag for native permissions and signing so Gradle daemons
// cannot select a different distribution through a stale environment property.
fun dropoDistributionFlag(value: String): Boolean = when (value) {
    "false" -> false
    "true" -> true
    else -> throw GradleException("DROPO_PLAY_DISTRIBUTION must be true or false.")
}
fun dropoDistributionDefine(encoded: String?): Boolean? {
    if (encoded.isNullOrEmpty()) return null
    var selected: Boolean? = null
    for (entry in encoded.split(',')) {
        val decoded = try {
            val bytes = Base64.getDecoder().decode(entry)
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            // Never include a define's contents: other values can be private.
            throw GradleException("Malformed Flutter dart-defines encoding.")
        }
        val key = decoded.substringBefore('=')
        if (key != "DROPO_PLAY_DISTRIBUTION") continue
        if (!decoded.contains('=') || selected != null) {
            throw GradleException("DROPO_PLAY_DISTRIBUTION must occur exactly once with a boolean value.")
        }
        selected = dropoDistributionFlag(decoded.substringAfter('='))
    }
    return selected
}
val dartPlayDistribution = dropoDistributionDefine(gradle.startParameter.projectProperties["dart-defines"])
val explicitPlayDistribution = gradle.startParameter.projectProperties["dropoPlayDistribution"]
    ?.let(::dropoDistributionFlag)
if (explicitPlayDistribution != null && explicitPlayDistribution != dartPlayDistribution) {
    throw GradleException("Native distribution override must match the explicit Flutter Dart distribution define.")
}
val playDistribution = dartPlayDistribution ?: false
val playBundleRequested = gradle.startParameter.taskNames.any {
    it.contains("bundle", ignoreCase = true) && it.contains("release", ignoreCase = true)
}
if (playBundleRequested && dartPlayDistribution != true) {
    throw GradleException("Release AAB requires --dart-define=DROPO_PLAY_DISTRIBUTION=true.")
}
val signingPrefix = if (playDistribution) "DROPO_ANDROID_UPLOAD" else "DROPO_ANDROID"
val releaseSigningProperties = Properties()
val releaseSigningPropertiesFile = System.getenv("${signingPrefix}_SIGNING_PROPERTIES")
    ?.takeIf { it.isNotBlank() }
    ?.let(::file)
    ?: file("${System.getProperty("user.home")}/.dropo-signing/" +
        if (playDistribution) "google-play/android-upload-signing.properties" else "android-signing.properties")
if (releaseSigningPropertiesFile.isFile) {
    releaseSigningPropertiesFile.reader(Charsets.UTF_8).use(releaseSigningProperties::load)
}

fun releaseSigningValue(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotBlank() }
        ?: releaseSigningProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseKeystorePath = releaseSigningValue("${signingPrefix}_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = releaseSigningValue("${signingPrefix}_STORE_PASSWORD", "storePassword")
val releaseKeyAlias = releaseSigningValue("${signingPrefix}_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = releaseSigningValue("${signingPrefix}_KEY_PASSWORD", "keyPassword")
val releaseSigningReady = listOf(
    releaseKeystorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() } && file(releaseKeystorePath!!).isFile
val releaseBuildRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }

if (releaseBuildRequested && !releaseSigningReady) {
    throw GradleException(
        "Android release signing is required. Set ${signingPrefix}_* variables " +
            "or provide ${releaseSigningPropertiesFile.absolutePath}.",
    )
}

val flutterTargetPlatforms = (findProperty("target-platform") as? String)
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    ?: listOf("android-arm64")

val targetAbis = flutterTargetPlatforms.mapNotNull {
    when (it) {
        "android-arm" -> "armeabi-v7a"
        "android-arm64" -> "arm64-v8a"
        "android-x86" -> "x86"
        "android-x64" -> "x86_64"
        else -> null
    }
}.distinct()

android {
    namespace = "in.droponevedimka.dropo"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Play Console owns this identity; sideload/Preview keep update continuity.
        applicationId = if (playDistribution) "com.dropo_dzhamuha.app" else "in.droponevedimka.dropo"
        resValue("string", "app_name", "dropo")
        // Android 10 supplies connection-owner lookup and authoritative
        // Always-on/lockdown state used by service routing and protection UI.
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "PLAY_DISTRIBUTION", playDistribution.toString())
        ndk {
            abiFilters += targetAbis
        }
    }

    sourceSets {
        // Only the sideload channel can request APK installation. Play has no
        // installer permission, APK FileProvider or installer intent query.
        getByName("release").manifest.srcFile(
            if (playDistribution) "src/play/AndroidManifest.xml" else "src/sideload/AndroidManifest.xml",
        )
        getByName("profile").manifest.srcFile("src/sideload/AndroidManifest.xml")
        getByName("debug").manifest.srcFile("src/sideload/AndroidManifest.xml")
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("profile") {
            // Device-review builds coexist with signed production installs.
            applicationIdSuffix = ".preview"
            versionNameSuffix = "-preview"
            signingConfig = signingConfigs.getByName("debug")
            resValue("string", "app_name", "dropo Preview")
        }
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    implementation(files("libs/dropoandroid.aar"))
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
