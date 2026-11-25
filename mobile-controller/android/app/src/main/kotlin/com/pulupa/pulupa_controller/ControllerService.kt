package com.pulupa.pulupa_controller

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Serviço em primeiro plano que mantém o controle vivo com a tela bloqueada.
 *
 * Sem ele, o Android suspende o processo e corta sensores e Wi-Fi quando a tela
 * apaga. Com ele, o processo continua (notificação fixa), um wake lock parcial
 * mantém a CPU acordada para ler os sensores e um Wi-Fi lock de baixa latência
 * impede o modo de economia do rádio, que aumentaria o atraso dos pacotes.
 * Bloquear a tela durante o jogo evita toques acidentais.
 */
class ControllerService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        // Se o sistema matar o processo, não recria o serviço sozinho: o app
        // reaberto retoma a sessão salva e liga o serviço de novo.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App removido dos recentes: encerra junto, sem deixar notificação órfã.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val power = getSystemService(PowerManager::class.java)
            wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pulupa:controller")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock?.isHeld != true) {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi?.createWifiLock(mode, "pulupa:controller")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Controle conectado",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Mantém o controle enviando movimento com a tela bloqueada."
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.pulupa_icon)
            .setContentTitle("PULUPA conectado")
            .setContentText("Enviando movimento ao PC. Pode bloquear a tela.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "pulupa_controller"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            val intent = Intent(context, ControllerService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ControllerService::class.java))
        }
    }
}
