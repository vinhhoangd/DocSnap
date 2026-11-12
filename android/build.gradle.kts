plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.1.0" apply false
}

// ~/Documents is synced to iCloud Drive: keep build output outside the project (one folder per
// checkout, so parallel worktrees don't share a build directory).
val buildRoot = File(System.getProperty("user.home"), "Library/Caches/DocSnap-android/" +
    Integer.toHexString(rootDir.absolutePath.hashCode()))
allprojects {
    layout.buildDirectory.set(File(buildRoot, name))
}
