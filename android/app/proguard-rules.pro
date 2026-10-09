# kotlinx.serialization: keep generated serializers for @Serializable classes.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class today.cypherpunk.emanator.** {
    *** Companion;
}
-keepclasseswithmembers class today.cypherpunk.emanator.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class today.cypherpunk.emanator.**$$serializer { *; }
