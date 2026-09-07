plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Has spike/build_libtorch_android.sh been run? The `full` flavor's JNI bridge needs it;
// `lite` never does. TorchBridge reports a clear model error at runtime if the library
// turns out to be missing, so a `full` build without it degrades rather than crashing.
val libtorchBuilt = file("../libtorch-android").isDirectory

// CMake's Android support cannot locate the NDK's unified sysroot on a non-x86_64 host,
// and it will not accept a compiler override, so build-jni-libs.sh materialises a shim NDK
// there (see README.md). Use it when it exists; on an x86_64 host the real NDK is fine.
val ndkShim = file("../.ndk-shim")

android {
    namespace = "md.thomas.openoura"
    compileSdk = 36
    if (ndkShim.isDirectory) ndkPath = ndkShim.absolutePath

    defaultConfig {
        applicationId = "md.thomas.openoura"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk {
            // 64-bit only, matching the iOS arm64-only slice policy.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // Mirrors the iOS split between build_run.sh (model-free) and build_run_torch.sh:
    // `lite` needs nothing but the Rust core, `full` additionally needs LibTorch for
    // Android plus the decrypted .ptl models (both gitignored, absent from CI).
    flavorDimensions += "models"
    productFlavors {
        create("lite") {
            dimension = "models"
            applicationIdSuffix = ".lite"
            versionNameSuffix = "-lite"
        }
        create("full") {
            dimension = "models"
            // Only the `full` flavor compiles the JNI torch bridge, so `lite` stays
            // buildable (and CI-able) with no LibTorch and no .ptl models present —
            // the same split as build_run.sh vs build_run_torch.sh on iOS.
            if (libtorchBuilt) {
                externalNativeBuild {
                    cmake {
                        cppFlags += listOf("-fexceptions", "-frtti", "-O2")
                        // Only this flavor defines native targets; see cpp/CMakeLists.txt.
                        arguments += listOf("-DANDROID_STL=c++_static", "-DOURA_BUILD_TORCH=ON")
                    }
                }
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
    }
    buildFeatures { compose = true }

    // `externalNativeBuild.path` is global to the module — there is no per-flavor form —
    // so it is wired only when LibTorch has actually been built. LibTorch is a local,
    // gitignored artifact (spike/build_libtorch_android.sh), and its absence is the
    // normal state for the `lite` flavor and for CI. Without this guard, configuring
    // ANY variant would run CMake and fail on a missing LibTorch.
    if (libtorchBuilt) {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }

    // liboura_core.so is produced by build-jni-libs.sh, not by Gradle.
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
    // The UniFFI-generated Kotlin lives beside the app sources, checked in exactly
    // like apps/ios/generated/oura_core.swift.
    sourceSets["main"].kotlin.srcDirs("../generated")

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        // JNA ships .so for every ABI; keep only ours.
        jniLibs.useLegacyPackaging = false
    }

    lint {
        warningsAsErrors = false
        abortOnError = true
        disable += setOf("GradleDependency", "AndroidGradlePluginVersion", "OldTargetApi")
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.health.connect)
    implementation(libs.jna) { artifact { type = "aar" } }

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
