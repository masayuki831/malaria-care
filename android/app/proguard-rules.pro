# Notification schedules are serialized and restored by Gson.
-keepattributes Signature,*Annotation*
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
