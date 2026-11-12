# kotlinx.serialization: keep generated serializers for the document models.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class com.vinhhoang.docsnap.model.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.vinhhoang.docsnap.model.**$$serializer { *; }
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
