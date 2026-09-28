allprojects {
    repositories {
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
subprojects {
    project.evaluationDependsOn(":app")
}

// Some Flutter plugins still pin an ancient compileSdk (e.g. media_kit_video
// hardcodes 31) while their transitive androidx deps require 33+. Flutter's
// documented workaround (issuetracker.google.com/issues/199180389): raise any
// plugin module below the app's compileSdk. Same mechanism PiliPlus uses.
subprojects {
    afterEvaluate {
        if (project.extensions.findByName("android") != null) {
            val androidExtension =
                project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            val pluginCompileSdk =
                androidExtension.compileSdkVersion
                    ?.removePrefix("android-")
                    ?.toIntOrNull()
            if (pluginCompileSdk != null && pluginCompileSdk < 36) {
                project.logger.warn(
                    "Overriding compileSdk in Flutter plugin ${project.name}: " +
                        "$pluginCompileSdk -> 36"
                )
                androidExtension.setCompileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
