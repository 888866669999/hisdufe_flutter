allprojects {
    repositories {
        // 阿里云镜像优先（原因见 settings.gradle.kts 的注释）
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 把所有子项目的 compileSdk 提到 36。
//
// 为什么需要这一步：某些插件（这里具体是 onnxruntime）在自己的
// build.gradle 里把 compileSdk 钉在 33，而它依赖的 androidx 库
// （fragment 1.7.1 / window 1.2.0 等）要求编译目标至少 34，
// 于是 AAR 校验阶段直接失败：
//   "Dependency 'androidx.fragment:fragment:1.7.1' requires ... 34 or later.
//    :onnxruntime is currently compiled against android-33."
//
// 插件是第三方代码，不能改它的 build.gradle（升级会被覆盖），
// 因此在根项目统一覆写 —— 这也是 Android 官方推荐的解决方式。
// 注意 compileSdk 只影响「能用哪些 API 编译」，不改变 minSdk（能装到哪些设备）
// 与 targetSdk（运行时行为），因此覆写是安全的。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
}

// 给 flutter_local_notifications 子项目补上 androidx.core。
//
// 为什么必须"单独给它补"：该插件在 android/build.gradle 里把依赖写成
// `implementation "androidx.core:core:1.3.0"`，而**插件是独立解析自己那份
// dependencies 的** —— 在 app 模块里再加一条 implementation 根本传不下去。
// 结果它编译自身 Java 时报「程序包 androidx.core.app 不存在 / 找不到符号 IconCompat」。
// 因此这里直接往它自己的 configurations 里加一条，放进它的编译类路径。
//
// 用 1.13.1 而不是它声明的 1.3.0：更完整，也与其它插件一致。
subprojects {
    if (name == "flutter_local_notifications") {
        // 必须在 afterEvaluate 里加：Android 插件的 `implementation`
        // configuration 是在 apply plugin 之后才创建的，
        // 配置阶段过早访问会报 "Configuration with name 'implementation' not found"。
        afterEvaluate {
            dependencies {
                add("implementation", "androidx.core:core:1.13.1")
            }
        }
    }
}

// 把各插件自带的 buildscript AGP 版本统一到本项目使用的 9.0.1。
//
// 为什么必须做：flutter_local_notifications 18.x 的 android/build.gradle 里有
//
//     buildscript { dependencies { classpath 'com.android.tools.build:gradle:7.3.1' } }
//
// 这是老模板留下的写法。AGP 7.3.1 的字节码无法被 Gradle 9 的
// 「instrumentation」转换处理，于是配置该插件时报：
//   Failed to transform gradle-7.3.1.jar ... MergeInstrumentationAnalysisTransform
//   > IllegalStateException: Could not deserialize analysis from a file
//   .../instrumentation-hierarchy.bin
//
// 这个错误此前被 Gradle 的共享 transform 缓存掩盖（缓存里恰好有其它项目
// 早先生成的结果），一旦缓存被清理就会稳定复现 —— 所以必须从根上消除
// 这个版本冲突，而不是依赖缓存。
//
// 在根项目里对子项目的 buildscript 做版本对齐是标准做法，
// 且不需要修改 pub 缓存里的第三方源码（那样会被 pub get 覆盖）。
subprojects {
    buildscript {
        configurations.all {
            resolutionStrategy {
                force("com.android.tools.build:gradle:9.0.1")
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
