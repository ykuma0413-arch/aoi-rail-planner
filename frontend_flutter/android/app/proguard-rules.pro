# TensorFlow Lite (tflite_flutter) - R8/ProGuard keep rules
# GPU delegate クラスは実行時にリフレクション参照されるため除外必須
-keep class org.tensorflow.** { *; }
-keep interface org.tensorflow.** { *; }
-dontwarn org.tensorflow.**

# Flutter デフォルト
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
