plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "work.yunju.fishaudio"
    compileSdk = 36
    defaultConfig {
        applicationId = "work.yunju.fishaudio"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    signingConfigs {
        if (System.getenv("TABLELOG_SIGNING_STORE") != null) create("distribution") {
            storeFile = file(System.getenv("TABLELOG_SIGNING_STORE"))
            storePassword = System.getenv("TABLELOG_SIGNING_PASSWORD")
            keyAlias = "tablelog"
            keyPassword = System.getenv("TABLELOG_SIGNING_PASSWORD")
        }
    }
    buildTypes { release { signingConfig = signingConfigs.findByName("distribution") } }
}
dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
}
