# android/app/proguard-rules.pro
# Keep accessibility service, dispatcher, and activity classes intact

-keep class * extends android.accessibilityservice.AccessibilityService {
    public *;
    protected *;
    <init>(...);
}

-keep class com.example.cyber_accessibility_agent.AgentAccessibilityService { *; }
-keep class com.example.cyber_accessibility_agent.MainActivity { *; }
-keep class com.example.cyber_accessibility_agent.CommandDispatcher { *; }

-keep class com.example.cyber_accessibility_agent.** { *; }

-keepclassmembers class * {
    public <methods>;
}

-keep class kotlin.Metadata { *; }
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers @androidx.annotation.Keep class * { *; }

-keepclasseswithmembernames class * {
    native <methods>;
}

-keepclassmembers class * implements android.os.Parcelable {
  public static final android.os.Parcelable$Creator CREATOR;
}