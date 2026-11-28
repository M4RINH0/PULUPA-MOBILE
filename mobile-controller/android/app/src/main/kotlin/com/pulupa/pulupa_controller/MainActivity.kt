package com.pulupa.pulupa_controller

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var deviceChannel: MethodChannel? = null
    private var sensorChannel: EventChannel? = null
    private var buttonChannel: EventChannel? = null
    private var imu: ImuStream? = null

    /** Recebe as teclas de volume como botões enquanto o Dart escuta (jogo conectado). */
    private var buttonSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val sensors = ImuStream(requireNotNull(getSystemService(SensorManager::class.java)))
        imu = sensors
        sensorChannel = EventChannel(messenger, "pulupa/imu").apply {
            setStreamHandler(sensors)
        }
        buttonChannel = EventChannel(messenger, "pulupa/buttons").apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    buttonSink = events
                }

                override fun onCancel(arguments: Any?) {
                    buttonSink = null
                }
            })
        }
        val preferences = getSharedPreferences("controller", Context.MODE_PRIVATE)
        // Separado das configurações: "loadSettings" devolve tudo de "controller".
        val sessions = getSharedPreferences("controller_session", Context.MODE_PRIVATE)
        deviceChannel = MethodChannel(messenger, "pulupa/device").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "sensors" -> result.success(sensors.capabilities())
                    "wifi" -> result.success(hasWifi())
                    "deviceLabel" -> result.success(
                        listOf(Build.MANUFACTURER, Build.MODEL).distinct().joinToString(" ").trim()
                    )
                    "setKeepScreenOn" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    "setBackgroundSession" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        setBackgroundSession(enabled)
                        result.success(null)
                    }
                    "moveToBackground" -> {
                        // Botão voltar com o controle conectado: mantém o app vivo.
                        result.success(moveTaskToBack(true))
                    }
                    "loadSession" -> result.success(sessions.getString("session", null))
                    "saveSession" -> {
                        val value = call.arguments as? String
                        if (value == null) {
                            sessions.edit().remove("session").apply()
                        } else {
                            sessions.edit().putString("session", value).apply()
                        }
                        result.success(null)
                    }
                    "clearSession" -> {
                        sessions.edit().remove("session").apply()
                        result.success(null)
                    }
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

    /**
     * Com um jogo conectado, volume − é o botão A e volume + é o B. A tecla é
     * consumida (o volume não muda) e chega ao Dart como [botão, apertado].
     * Repetições de tecla segurada são ignoradas: só a descida e a subida contam.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val sink = buttonSink
        val button = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> "a"
            KeyEvent.KEYCODE_VOLUME_UP -> "b"
            else -> null
        }
        if (sink == null || button == null) return super.dispatchKeyEvent(event)
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) sink.success(listOf(button, true))
            KeyEvent.ACTION_UP -> sink.success(listOf(button, false))
        }
        return true
    }

    private var backgroundSession = false

    /**
     * Liga o serviço em primeiro plano enquanto há um jogo conectado, para que
     * sensores e Wi-Fi continuem com a tela bloqueada.
     */
    private fun setBackgroundSession(enabled: Boolean) {
        if (enabled == backgroundSession) return
        backgroundSession = enabled
        if (enabled) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                // Sem a permissão o serviço roda igual, só sem notificação visível.
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
            try {
                ControllerService.start(this)
            } catch (failure: Exception) {
                // Android 12+ recusa iniciar o serviço com o app em segundo plano;
                // ele é ligado assim que o app volta à frente.
                backgroundSession = false
            }
        } else {
            ControllerService.stop(this)
        }
    }

    /**
     * Retorna true quando o celular tem uma rede local utilizável: conectado a um Wi-Fi
     * (mesmo sem internet, quando o Android mantém o celular como rede padrão), a uma
     * Ethernet, ou servindo como roteador/hotspot (interface AP com IPv4 privado).
     */
    private fun hasWifi(): Boolean {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        if (connectivity != null) {
            val active = connectivity.activeNetwork
            if (active != null && isLocalTransport(connectivity.getNetworkCapabilities(active))) {
                return true
            }
            // Um Wi-Fi local sem internet pode existir sem ser a rede padrão (o Android
            // prefere os dados móveis nesse caso). Ainda serve para o PULUPA.
            @Suppress("DEPRECATION")
            val anyLocal = connectivity.allNetworks.any { network ->
                isLocalTransport(connectivity.getNetworkCapabilities(network))
            }
            if (anyLocal) return true
        }
        return hasLocalApInterface()
    }

    private fun isLocalTransport(capabilities: NetworkCapabilities?): Boolean {
        if (capabilities == null) return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    /** Detecta hotspot/tethering ativo: o ConnectivityManager não expõe a rede AP como Network. */
    private fun hasLocalApInterface(): Boolean = try {
        val prefixes = listOf("ap", "wlan", "swlan", "softap", "wigig")
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().any { nif ->
            val name = nif.name.lowercase()
            nif.isUp && !nif.isLoopback &&
                prefixes.any { name.startsWith(it) } &&
                nif.inetAddresses.toList().any { address ->
                    address is Inet4Address && address.isSiteLocalAddress
                }
        }
    } catch (failure: Exception) {
        false
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        imu?.stop()
        sensorChannel?.setStreamHandler(null)
        buttonChannel?.setStreamHandler(null)
        deviceChannel?.setMethodCallHandler(null)
        imu = null
        sensorChannel = null
        buttonChannel = null
        buttonSink = null
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        imu?.stop()
        if (backgroundSession) {
            // A atividade (e o engine do Flutter) acabou: não há mais quem envie.
            ControllerService.stop(this)
            backgroundSession = false
        }
        super.onDestroy()
    }
}

/**
 * Lê os sensores numa HandlerThread dedicada e entrega os eventos ao Dart pela thread
 * principal (exigência do EventSink). Cada evento é preservado (o Dart integra o
 * giroscópio e usa todo rotation vector), mas os eventos são enfileirados e drenados
 * por no máximo um Runnable pendente na fila principal por vez, sem inundá-la.
 */
private class ImuStream(private val manager: SensorManager) :
    EventChannel.StreamHandler, SensorEventListener {
    private val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val gameRotation = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private val quaternion = FloatArray(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val pending = ArrayDeque<List<Any>>()
    private var drainScheduled = false
    private var generation = 0
    private var sensorThread: HandlerThread? = null

    @Volatile
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
        val thread = HandlerThread("pulupa-imu").also { it.start() }
        sensorThread = thread
        val sensorHandler = Handler(thread.looper)
        sink = events
        try {
            val registered = available.map { sensor ->
                manager.registerListener(this, sensor, 1_000_000 / hz, 0, sensorHandler)
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
        synchronized(lock) {
            generation += 1
            pending.clear()
            drainScheduled = false
        }
        sensorThread?.quitSafely()
        sensorThread = null
    }

    // Executa na HandlerThread dos sensores.
    override fun onSensorChanged(event: SensorEvent) {
        if (sink == null) return
        val timestamp = event.timestamp / 1000L
        val v = event.values
        val payload: List<Any> = when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE -> {
                val kind = if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) 0 else 1
                listOf(kind, timestamp, v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
            }
            Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quaternion, v)
                listOf(
                    2, timestamp, quaternion[1].toDouble(), quaternion[2].toDouble(),
                    quaternion[3].toDouble(), quaternion[0].toDouble()
                )
            }
            else -> return
        }
        val scheduleGeneration: Int
        synchronized(lock) {
            pending.addLast(payload)
            // Proteção caso a thread principal trave: descarta os eventos mais antigos.
            while (pending.size > MAX_PENDING) pending.removeFirst()
            if (drainScheduled) return
            drainScheduled = true
            scheduleGeneration = generation
        }
        mainHandler.post { drain(scheduleGeneration) }
    }

    // Executa na thread principal.
    private fun drain(scheduledGeneration: Int) {
        val batch: List<List<Any>>
        synchronized(lock) {
            drainScheduled = false
            if (scheduledGeneration != generation) return
            batch = pending.toList()
            pending.clear()
        }
        val target = sink ?: return
        for (payload in batch) {
            target.success(payload)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private companion object {
        const val MAX_PENDING = 512
    }
}
