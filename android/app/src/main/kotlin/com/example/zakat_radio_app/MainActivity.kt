package ly.zakatfund.radioapp

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val channelName = "ly.zakatfund.radioapp/native"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighestRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        preferHighestRefreshRate()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openApp" -> {
                    val packageName = call.arguments as? String
                    result.success(packageName?.let { openInstalledApp(it) } == true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openInstalledApp(packageName: String): Boolean {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return false

        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(launchIntent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun preferHighestRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return

        val display = windowManager.defaultDisplay ?: return
        val bestMode = display.supportedModes.maxByOrNull { it.refreshRate } ?: return
        val params = window.attributes
        params.preferredDisplayModeId = bestMode.modeId
        params.preferredRefreshRate = bestMode.refreshRate
        window.attributes = params
    }
}
