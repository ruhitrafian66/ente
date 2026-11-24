-keep class ai.onnxruntime.** { *; }
# To ensure that stack traces is unambiguous
# https://developer.android.com/studio/build/shrink-code#decode-stack-trace
-keepattributes LineNumberTable,SourceFile

-keep class org.xmlpull.v1.** { *; }

# Preserve ExoPlayer/Media3 classes used for video playback.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**
