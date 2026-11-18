import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import javax.inject.Inject

plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
  alias(libs.plugins.kotlin.serialization)
}

/**
 * Copies the self-contained Omni keyboard sources from the KKRemote Android client so this
 * playground always exercises exactly the code the real app ships (no fork, no app/WebRTC deps).
 */
abstract class SyncOmniKeyboardSources : DefaultTask() {
  @get:InputFiles
  @get:PathSensitive(PathSensitivity.RELATIVE)
  abstract val sources: ConfigurableFileCollection

  @get:OutputDirectory
  abstract val outputDir: DirectoryProperty

  @get:Inject
  abstract val fs: FileSystemOperations

  @TaskAction
  fun sync() {
    fs.sync {
      into(outputDir)
      from(sources) { into("com/kkremote/android/ui") }
    }
  }
}

val omniKeyboardDir = rootProject.layout.projectDirectory
  .dir("../Apps/AndroidClient/app/src/main/kotlin/com/kkremote/android/ui")

val syncOmniKeyboard = tasks.register<SyncOmniKeyboardSources>("syncOmniKeyboardSources") {
  sources.from(
    listOf("OmniMacKeyboard.kt", "OmniKeyboardEngine.kt", "OmniKeyboardUi.kt", "OmniVoicePanel.kt")
      .map { omniKeyboardDir.file(it) },
  )
  outputDir.set(layout.buildDirectory.dir("generated/omniKeyboard/kotlin"))
}

android {
  namespace = "com.kkremote.keyboardtest"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.kkremote.keyboardtest"
    minSdk = 29
    targetSdk = 36
    versionCode = 1
    versionName = "0.1.0"
  }

  buildTypes {
    release {
      // Minified release feels like the real app (debug Compose is janky) and installs fast
      // over a relayed adb link; signed with the local debug key, never published.
      isMinifyEnabled = true
      isShrinkResources = true
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
      signingConfig = signingConfigs.getByName("debug")
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  buildFeatures {
    compose = true
    buildConfig = false
  }
}

extensions.getByType(ApplicationAndroidComponentsExtension::class.java).onVariants { variant ->
  (variant.sources.kotlin ?: variant.sources.java)
    ?.addGeneratedSourceDirectory(syncOmniKeyboard, SyncOmniKeyboardSources::outputDir)
}

kotlin {
  jvmToolchain(17)
}

dependencies {
  val composeBom = platform(libs.androidx.compose.bom)
  implementation(composeBom)

  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.activity.compose)
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.compose.material3)
  implementation(libs.androidx.compose.material.icons.extended)
  implementation(libs.kotlinx.serialization.json)
  debugImplementation(libs.androidx.compose.ui.tooling)

  testImplementation(libs.junit)
}
