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
        // 必须先 clear() 清掉注入值,再 addAll 自定义架构。
        // 参考: https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android
        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a"))
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

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        dependsOn("cargoBuildArm64")
    }
}
