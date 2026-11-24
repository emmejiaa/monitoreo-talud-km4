package co.edu.unal.monitoreo_km4

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sonidos: SoundPool? = null
    private var idAmarilla = 0
    private var idRoja = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val pool = SoundPool.Builder()
            .setMaxStreams(2)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .build()
        idAmarilla = pool.load(this, R.raw.alerta_amarilla, 1)
        idRoja = pool.load(this, R.raw.alerta_roja, 1)
        sonidos = pool

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "km4/alertas")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sonar" -> {
                        val id = if (call.argument<String>("tipo") == "roja") idRoja else idAmarilla
                        sonidos?.play(id, 1f, 1f, 1, 0, 1f)
                        result.success(null)
                    }
                    "vibrar" -> {
                        vibrar()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun vibrar() {
        val vibrador = if (Build.VERSION.SDK_INT >= 31) {
            getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        } ?: return
        val patron = longArrayOf(0, 400, 200, 400)
        if (Build.VERSION.SDK_INT >= 26) {
            vibrador.vibrate(VibrationEffect.createWaveform(patron, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrador.vibrate(patron, -1)
        }
    }

    override fun onDestroy() {
        sonidos?.release()
        sonidos = null
        super.onDestroy()
    }
}
