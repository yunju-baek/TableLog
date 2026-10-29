plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "work.yunju.tablelog"
    compileSdk = 36
    defaultConfig {
        applicationId = "work.yunju.tablelog"
        minSdk = 26
        targetSdk = 36
        versionCode = 3
        versionName = "0.3.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    signingConfigs {
        if (System.getenv("TABLELOG_SIGNING_STORE") != null) create("distribution") {
            storeFile = file(System.getenv("TABLELOG_SIGNING_STORE"))
            storePassword = System.getenv("TABLELOG_SIGNING_PASSWORD")
            keyAlias = "tablelog"
            keyPassword = System.getenv("TABLELOG_SIGNING_PASSWORD")
        }
    }
    buildTypes { release {
        isMinifyEnabled = false
        signingConfig = signingConfigs.findByName("distribution")
    } }
}
val sherpaAar = layout.buildDirectory.file("dependencies/sherpa-onnx-2.0.1.aar")
val prepareSherpa by tasks.registering(Exec::class) {
    inputs.file(rootProject.file("scripts/fetch-sherpa.py"))
    outputs.file(sherpaAar)
    commandLine("python3", rootProject.file("scripts/fetch-sherpa.py"), "--output", sherpaAar.get().asFile)
}
dependencies {
    implementation(files(sherpaAar).builtBy(prepareSherpa))
    val composeBom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
