// The test app: Kotlin and Jetpack Compose, depending on the kit as a host app would.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.bestcatscience.icreadsample"
    compileSdk = 35
    defaultConfig {
        // The same identifier as the iOS app, so one set of Maestro flows drives both.
        applicationId = "com.bestcatscience.icreadsample"
        minSdk = 26
        targetSdk = 35
        versionCode = 4
        versionName = "0.4.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures {
        compose = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        release {
            // Shrinking proves the kit's consumer keep rules work in a host app.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":icreadkit"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.ui:ui:1.8.0-beta02")
    implementation("androidx.compose.foundation:foundation:1.8.0-beta02")
    implementation("androidx.compose.material3:material3:1.4.0-alpha08")

    androidTestImplementation("androidx.compose.ui:ui-test-junit4:1.8.0-beta02")
    androidTestImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.compose.ui:ui-test-manifest:1.8.0-beta02")
}
