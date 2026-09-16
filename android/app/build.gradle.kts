import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    //id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// 按 flutter 传入的 target-platform（-Ptarget-platform=android-arm,android-arm64）
// 决定本机库（Rust 引擎）与 APK abiFilters：token 精确匹配——
// "android-arm" 是 32 位，"android-arm64" 含 "android-arm" 前缀，不能用 contains。
val flutterTargetPlatformTokens: List<String> =
    (project.findProperty("target-platform") as? String)
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?: listOf("android-arm64")
val rustAbis: List<String> = buildList {
    if (flutterTargetPlatformTokens.contains("android-arm")) add("armeabi-v7a")
    if (flutterTargetPlatformTokens.contains("android-arm64")) add("arm64-v8a")
    if (isEmpty()) add("arm64-v8a")
}

android {
    namespace = "shiyin.famlife.top"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "shiyin.famlife.top"
        // You may update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 车载歌词依赖 SuperLyricApi 3.4 声明 minSdk 26，原 flutter.minSdkVersion(24) 会在 Manifest 合并失败
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Flutter 3.35+ Gradle 插件会在 build.gradle 处理前自动把
        // abiFilters 设为 armeabi-v7a,arm64-v8a,x86_64(防止 x86 误判),
        // 导致原来的 `+= listOf("arm64-v8a")` 失效、APK 塞进 3 套架构。
        // 必须先 clear() 清掉注入值,再按 flutter 传入的 target-platform
        // 精确设置（--target-platform android-arm → 仅 armeabi-v7a，
        // 老车机 32 位包；默认/ android-arm64 → 仅 arm64-v8a）。
        // 参考: https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android
        ndk {
            abiFilters.clear()
            abiFilters.addAll(rustAbis)
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // 渲染引擎双变体：skia（老 GPU 稳定）/ impeller（默认，Vulkan）。
    // 仅控制 Manifest 的 io.flutter.embedding.android.EnableImpeller 开关；
    // 包名、签名、versionCode 两变体完全一致，同版本跨变体可直接覆盖安装、
    // 数据保留。构建必须带 --flavor（CI / build_apk.bat 已处理）。
    flavorDimensions += "renderer"
    productFlavors {
        create("skia") {
            dimension = "renderer"
            manifestPlaceholders["enableImpeller"] = "false"
        }
        create("impeller") {
            dimension = "renderer"
            manifestPlaceholders["enableImpeller"] = "true"
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}


// JitPack 懒构建不缓存失败结果，避免首次 404 被永久缓存
configurations.all {
    resolutionStrategy {
        cacheChangingModulesFor(0, "seconds")
    }
}

dependencies {
    // SuperLyricApi 3.4 via JitPack，车载歌词广播（Xposed）
    implementation("com.github.HChenX:SuperLyricApi:3.4") {
        isChanging = true
    }
}

flutter {
    source = "../.."
}

tasks.register<Exec>("cargoBuildArm64") {
    workingDir = file("${project.projectDir}/../../rust")
    commandLine(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-o", "../android/app/src/main/jniLibs",
        "build", "--release"
    )
}

tasks.register<Exec>("cargoBuildArm32") {
    workingDir = file("${project.projectDir}/../../rust")
    commandLine(
        "cargo", "ndk",
        "-t", "armeabi-v7a",
        "-o", "../android/app/src/main/jniLibs",
        "build", "--release"
    )
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        if (rustAbis.contains("arm64-v8a")) dependsOn("cargoBuildArm64")
        if (rustAbis.contains("armeabi-v7a")) dependsOn("cargoBuildArm32")
    }
}
