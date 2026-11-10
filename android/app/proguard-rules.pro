# Flutter / 插件侧反射与 JNI 回调
# ---------------------------------------------------------------
# Flutter 引擎内部有按类名加载与 JNI 回调；保留全部 embedding 类最稳妥
# （体积影响很小，出错代价很大）。
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**

# audio_service / just_audio / audio_session：MediaSession、Service、
# Handler 由系统与插件按名字回调，不能被裁剪。
-keep class com.ryanheise.** { *; }
-dontwarn com.ryanheise.**

# 项目自身 Kotlin 原生实现
# ---------------------------------------------------------------
# KaraokeTextView 由 res/layout/overlay_lyrics.xml 按类名反射实例化，
# 构造函数必须保留，否则 Release 包桌面歌词悬浮窗会 InflateException。
-keep class shiyin.famlife.top.KaraokeTextView { *; }
# 其余原生类（MethodChannel 实现）保留默认构造，防止反射创建路径被裁。
-keep class shiyin.famlife.top.** {
    <init>(...);
}

# 车载歌词广播（SuperLyricApi，Xposed 侧按类名反射调用）
-keep class com.hchen.superlyricapi.** { *; }
-dontwarn com.hchen.superlyricapi.**

# 元信息：崩溃栈保留行号与注解，便于线上定位
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 依赖里缺失的可选注解类，避免 R8 因找不到引用而失败
-dontwarn org.jetbrains.annotations.**
-dontwarn javax.annotation.**
