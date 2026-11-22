plugins {
    kotlin("jvm") version "2.3.21"
}

repositories { mavenCentral() }

kotlin {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    sourceSets {
        main {
            kotlin.srcDir("../app/src/main/kotlin")
            // Compile the real platform-independent policies, never copies or native stubs.
            kotlin.include(
                "**/AccountSessionEnvelope.kt", "**/AndroidDistributionPolicy.kt",
                "**/AndroidUpdateDownload.kt", "**/AndroidUpdatePolicy.kt", "**/AndroidUpdateResumeStore.kt",
                "**/CoreCallExecutionPolicy.kt", "**/NativeLogDispatcher.kt", "**/PhysicalNetworkPolicy.kt",
                "**/PlayStoreListing.kt", "**/ReviewPromptTracker.kt", "**/TelegramAuthLink.kt",
                "**/VpnDisclosurePolicy.kt", "**/VpnSessionFence.kt",
            )
        }
        test { kotlin.srcDir("../app/src/test/kotlin") }
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies { testImplementation("junit:junit:4.13.2") }

tasks.test { useJUnit() }
