allprojects {
    repositories {
        google()
        mavenCentral()
        // Only the pinned USB serial driver is resolved from JitPack.
        exclusiveContent {
            forRepository { maven(url = "https://jitpack.io") }
            filter { includeModule("com.github.mik3y", "usb-serial-for-android") }
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
