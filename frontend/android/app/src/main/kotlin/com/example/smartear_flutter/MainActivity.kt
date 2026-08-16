package com.example.smartear_flutter

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alertChannel = "com.example.smartear_flutter/alerts"
    private val handler = Handler(Looper.getMainLooper())
    private var torchCameraId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, alertChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "triggerAlert") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val urgency = call.argument<String>("urgency") ?: "low"
                val vibrationEnabled =
                    call.argument<Boolean>("vibrationEnabled") ?: true
                val flashEnabled = call.argument<Boolean>("flashEnabled") ?: true
                try {
                    if (vibrationEnabled) vibrateForUrgency(urgency)
                    if (flashEnabled && urgency == "high") flashTorch()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("ALERT_FAILED", error.message, null)
                }
            }
    }

    private fun getVibrator(): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    private fun vibrateForUrgency(urgency: String) {
        val pattern = when (urgency) {
            "high" -> longArrayOf(0, 350, 150, 350, 150, 700)
            "medium" -> longArrayOf(0, 250, 150, 250)
            else -> longArrayOf(0, 180)
        }
        val vibrator = getVibrator()
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
        }
    }

    private fun flashTorch() {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = torchCameraId ?: manager.cameraIdList.firstOrNull { id ->
            val characteristics = manager.getCameraCharacteristics(id)
            characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
                characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: return
        torchCameraId = cameraId

        listOf(
            0L to true,
            250L to false,
            450L to true,
            700L to false,
            900L to true,
            1150L to false,
        ).forEach { (delay, enabled) ->
            handler.postDelayed({
                try {
                    manager.setTorchMode(cameraId, enabled)
                } catch (_: Exception) {
                    // The visual and vibration alerts remain available.
                }
            }, delay)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        torchCameraId?.let { id ->
            try {
                (getSystemService(Context.CAMERA_SERVICE) as CameraManager)
                    .setTorchMode(id, false)
            } catch (_: Exception) {
                // Camera may already be unavailable during shutdown.
            }
        }
        super.onDestroy()
    }
}
