package com.pulupa.pulupa_controller

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var deviceChannel: MethodChannel? = null
    private var sensorChannel: EventChannel? = null
    private var imu: ImuStream? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val sensors = ImuStream(requireNotNull(getSystemService(SensorManager::class.java)))
        imu = sensors
        sensorChannel = EventChannel(messenger, "pulupa/imu").apply {
            setStreamHandler(sensors)
        }
        val preferences = getSharedPreferences("controller", Context.MODE_PRIVATE)
        deviceChannel = MethodChannel(messenger, "pulupa/device").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "sensors" -> result.success(sensors.capabilities())
                    "wifi" -> result.success(hasWifi())
                    "deviceLabel" -> result.success(
                        listOf(Build.MANUFACTURER, Build.MODEL).distinct().joinToString(" ").trim()
                    )
                    "loadSettings" -> result.success(preferences.all)
                    "saveSettings" -> {
                        val editor = preferences.edit()
                        call.argument<Int>("captureHz")?.let { editor.putInt("captureHz", it) }
                        call.argument<Int>("sendHz")?.let { editor.putInt("sendHz", it) }
                        call.argument<Int>("smoothingMs")?.let { editor.putInt("smoothingMs", it) }
                        call.argument<Double>("deadZoneDegrees")?.let {
                            editor.putFloat("deadZoneDegrees", it.toFloat())
                        }
                        call.argument<Boolean>("haptics")?.let { editor.putBoolean("haptics", it) }
                        editor.apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun hasWifi(): Boolean {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return false
        return connectivity.allNetworks.any { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        imu?.stop()
        sensorChannel?.setStreamHandler(null)
        deviceChannel?.setMethodCallHandler(null)
        imu = null
        sensorChannel = null
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

private class ImuStream(private val manager: SensorManager) :
    EventChannel.StreamHandler, SensorEventListener {
    private val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val gameRotation = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private val quaternion = FloatArray(4)
    private var sink: EventChannel.EventSink? = null

    fun capabilities() = mapOf(
        "accelerometer" to (accelerometer != null),
        "gyroscope" to (gyroscope != null),
        "gameRotation" to (gameRotation != null)
    )

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val hz = (arguments as? Int) ?: 100
        if (hz !in listOf(25, 50, 100)) {
            events.error("invalid_rate", "Unsupported sensor rate", null)
            return
        }
        val available = listOfNotNull(accelerometer, gyroscope, gameRotation)
        sink = events
        try {
            val registered = available.map { sensor ->
                manager.registerListener(this, sensor, 1_000_000 / hz, 0)
            }
            if (registered.isNotEmpty() && registered.none { it }) {
                stop()
                events.error("imu_unavailable", "Android rejected all sensor registrations", null)
            }
        } catch (failure: RuntimeException) {
            stop()
            events.error("imu_unavailable", "Android could not start the sensors", null)
        }
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        manager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        val target = sink ?: return
        val timestamp = event.timestamp / 1000L
        val v = event.values
        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE -> {
                val kind = if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) 0 else 1
                target.success(listOf(kind, timestamp, v[0].toDouble(), v[1].toDouble(), v[2].toDouble()))
            }
            Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quaternion, v)
                target.success(listOf(
                    2, timestamp, quaternion[1].toDouble(), quaternion[2].toDouble(),
                    quaternion[3].toDouble(), quaternion[0].toDouble()
                ))
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}
