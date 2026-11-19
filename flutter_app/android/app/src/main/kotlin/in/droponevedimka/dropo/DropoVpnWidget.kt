package `in`.droponevedimka.dropo

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.widget.RemoteViews
import dropoandroid.Dropoandroid
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class DropoVpnWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        observe(context)
        manager.updateAppWidget(ids, render(context))
    }

    companion object {
        private val observing = AtomicBoolean()
        internal const val START = "dropo.widget.START"
        internal const val STOP = "dropo.widget.STOP"

        fun observe(context: Context) {
            val app = context.applicationContext
            if (!observing.compareAndSet(false, true)) return
            DropoVpnRuntime.addListener(object : DropoVpnRuntime.Listener {
                override fun onEvent(event: Map<String, Any?>) {
                    if (event["name"] == "android-service-status") refresh(app)
                }
            })
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, DropoVpnWidget::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, render(context))
        }

        private fun render(context: Context): RemoteViews {
            val status = DropoVpnRuntime.snapshot()
            val connected = status["connected"] == true
            val busy = status["connecting"] == true || status["disconnecting"] == true
            val action = Intent(context, DropoVpnWidgetAction::class.java)
                .setAction(if (connected) STOP else START)
            val click = PendingIntent.getActivity(
                context,
                if (connected) 1 else 0,
                action,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val label = context.getString(
                when {
                    busy -> R.string.vpn_widget_wait
                    connected -> R.string.vpn_widget_on
                    else -> R.string.vpn_widget_off
                },
            )
            return RemoteViews(context.packageName, R.layout.dropo_vpn_widget).apply {
                setContentDescription(
                    R.id.widget_root,
                    context.getString(
                        R.string.vpn_widget_accessibility,
                        context.getString(R.string.vpn_widget_name),
                        label,
                    ),
                )
                val switchImage = if (connected) {
                    R.drawable.dropo_widget_switch_on
                } else {
                    R.drawable.dropo_widget_switch_off
                }
                setImageViewResource(R.id.widget_toggle, switchImage)
                setInt(R.id.widget_toggle, "setImageAlpha", if (busy) 140 else 255)
                setOnClickPendingIntent(R.id.widget_root, if (busy) null else click)
            }
        }
    }
}

/** An immutable launcher PendingIntent is the only entry to this Activity. */
class DropoVpnWidgetAction : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        DropoVpnWidget.observe(this)
        if (state != null) {
            finish()
            return
        }
        when (intent.action) {
            DropoVpnWidget.START -> startFromWidget()
            DropoVpnWidget.STOP -> {
                stopFromWidget()
                finish()
            }
            else -> finish()
        }
    }

    private fun startFromWidget() {
        if (!canStart() || !starting.compareAndSet(false, true)) {
            finish()
            return
        }
        val app = applicationContext
        executor.execute {
            val prepared = runCatching {
                if (!VpnDisclosureConsent.isAccepted(app) || VpnService.prepare(app) != null) {
                    return@runCatching false
                }
                Dropoandroid.configureDistribution(BuildConfig.PLAY_DISTRIBUTION)
                val version = packageManager.getPackageInfo(packageName, 0).versionName.orEmpty()
                Dropoandroid.ensureStarted(filesDir.absolutePath, version)
                val response = JSONObject(Dropoandroid.call("GetVPNSources", "[]"))
                val sources = response.optJSONArray("sources") ?: return@runCatching false
                (0 until sources.length()).any {
                    val item = sources.optJSONObject(it)
                    item != null && !item.optBoolean("disabled") && item.optInt("node_count") > 0
                }
            }.getOrDefault(false)
            runOnUiThread {
                try {
                    if (isDestroyed || isFinishing || !canStart()) return@runOnUiThread
                    val permissionGranted = prepared && VpnDisclosureConsent.isAccepted(this) &&
                        runCatching { VpnService.prepare(this) == null }.getOrDefault(false)
                    if (permissionGranted) {
                        val started = runCatching {
                            DropoVpnService.start(this)
                            DropoVpnRuntime.setStarting()
                        }.isSuccess
                        if (!started) openDropoForSetup()
                    } else {
                        openDropoForSetup()
                    }
                } finally {
                    starting.set(false)
                    finish()
                }
            }
        }
    }

    private fun canStart(): Boolean {
        val state = DropoVpnRuntime.snapshot()["state"]
        return state == "stopped" || state == "failed"
    }

    private fun stopFromWidget() {
        if (DropoVpnRuntime.snapshot()["connected"] != true) {
            DropoVpnWidget.refresh(this)
            return
        }
        val protection = DropoVpnService.refreshVpnProtection()
        if (protection["observed"] != true || protection["alwaysOn"] == true) {
            runCatching { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)) }
            return
        }
        runCatching {
            DropoVpnService.stop(this)
            DropoVpnRuntime.setDisconnecting()
        }
    }

    private fun openDropoForSetup() {
        WidgetVpnSetup.request()
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
    }

    private companion object {
        val executor = Executors.newSingleThreadExecutor()
        val starting = AtomicBoolean()
    }
}

/** A fresh, in-process request. Arbitrary intents to MainActivity cannot set it. */
internal object WidgetVpnSetup {
    private val expires = AtomicLong()
    fun request() {
        expires.set(SystemClock.elapsedRealtime() + 60_000)
    }
    fun pending(): Boolean = expires.get() > SystemClock.elapsedRealtime()
    fun consume(): Boolean = expires.getAndSet(0) > SystemClock.elapsedRealtime()
}
