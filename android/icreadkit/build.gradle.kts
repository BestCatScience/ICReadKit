// The kit: Java, no dependencies, shipped as an AAR.
plugins {
    id("com.android.library")
}

android {
    namespace = "com.bestcatscience.icreadkit"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint {
        // Fails the build on API calls the kit's minSdk (26) does not have and D8 cannot backport.
        abortOnError = true
        warningsAsErrors = true
        checkDependencies = false
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
