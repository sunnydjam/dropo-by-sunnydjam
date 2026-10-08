package `in`.droponevedimka.dropo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageManager.NameNotFoundException
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.LinkProperties
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import androidx.annotation.RequiresApi
import dropoandroid.CommandServer
import dropoandroid.CommandServerHandler
import dropoandroid.ConnectionOwner
import dropoandroid.Dropoandroid
import dropoandroid.InterfaceUpdateListener
import dropoandroid.LocalDNSTransport
import dropoandroid.NetworkInterfaceIterator
import dropoandroid.OverrideOptions
import dropoandroid.PlatformInterface
import dropoandroid.RoutePrefix
import dropoandroid.StringIterator
import dropoandroid.SystemProxyStatus
import dropoandroid.TunOptions
import dropoandroid.WIFIState
import dropoandroid.NetworkInterface as BoxNetworkInterface
import dropoandroid.Notification as BoxNotification
import dropoandroid.SetupOptions as BoxSetupOptions
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import java.net.NetworkInterface as JavaNetworkInterface

class DropoVpnService :
    VpnService(),
    PlatformInterface,
    CommandServerHandler {
    @Volatile
    private var engineThread: Thread? = null
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "DropoVpnEngine").also { engineThread = it }
    }
    private val nativeLogs = NativeLogDispatcher { method, arguments ->
        Dropoandroid.call(method, arguments)
    }
    private val sessionFence = VpnSessionFence()
    private val tunLock = Any()
    private val stopLock = Any()
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }

    @Volatile
    private var engineGeneration = 0L

    @Volatile
    private var tunInterface: ParcelFileDescriptor? = null

    @Volatile
    private var commandServer: CommandServer? = null

    @Volatile
    private var starting = false

    @Volatile
    private var stopping = false

    @Volatile
    private var lastCoreDebugLogAt = 0L

    @Volatile
    private var lastRuntimeSingBoxLogAt = 0L

    @Volatile
    private var verboseSingBoxLogs = false

    @Volatile
    private var foregroundActive = false

    @Volatile
    private var foregroundText = ""

    @Volatile
    private var notificationAlwaysOn: Boolean? = null

    @Volatile
    private var interfaceUpdateListener: InterfaceUpdateListener? = null
    private var networkCallbackRegistered = false
    private var physicalNetworkSignature = ""
    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                notifyDefaultInterfaceAsync()
            }

            override fun onLost(network: Network) {
                notifyDefaultInterfaceAsync()
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                notifyDefaultInterfaceAsync()
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                notifyDefaultInterfaceAsync()
            }
        }

    override fun onCreate() {
        super.onCreate()
        // ACTION_STOP can start a previously inactive service via an old
        // PendingIntent. The fail-safe response still needs a valid channel
        // before it can refresh the foreground notification.
        createNotificationChannel()
        activeService = this
        publishVpnProtection()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        refreshVpnProtectionAndNotification()
        return when (intent?.action) {
            ACTION_STOP -> {
                val protection = publishVpnProtection()
                if (!protection.observed || protection.alwaysOn) {
                    // The service is the final authority for every stop path,
                    // including stale notification PendingIntents. Stopping an
                    // Always-on service makes Android recreate it and can cause
                    // a brief direct-traffic window when lockdown is disabled.
                    // Unknown protection state is handled fail-safe as well.
                    val text = if (protection.alwaysOn) {
                        "Always-on VPN управляется Android"
                    } else {
                        "Сначала проверьте системные настройки VPN"
                    }
                    DropoVpnRuntime.appendLog("VPN stop redirected to Android settings")
                    showForeground(text, protection)
                    if (protection.alwaysOn && commandServer == null && !starting) {
                        startVpn()
                    }
                    START_STICKY
                } else {
                    DropoVpnRuntime.setDisconnecting("VPN останавливается")
                    stopVpn(stopSelf = true)
                    START_NOT_STICKY
                }
            }
            else -> {
                startVpn()
                START_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopVpn(stopSelf = true)
        super.onRevoke()
    }

    override fun onDestroy() {
        sessionFence.destroy()
        stopVpn(stopSelf = false)
        executor.shutdown()
        nativeLogs.close()
        foregroundActive = false
        if (activeService === this) {
            activeService = null
            DropoVpnRuntime.setVpnProtection(
                observed = false,
                alwaysOn = false,
                lockdown = false,
            )
        }
        super.onDestroy()
    }

    fun protectFileDescriptor(socket: Int): Boolean = protect(socket)

    private fun startVpn() {
        createNotificationChannel()
        if (stopping) return
        if (starting || commandServer != null) {
            executor.execute { coreLog("start skipped: VPN service is already running") }
            sessionFence.commit(engineGeneration) {
                if (commandServer != null) {
                    DropoVpnRuntime.setConnected("VPN уже работает")
                    showForeground("VPN работает")
                } else {
                    showForeground("VPN запускается")
                }
            }
            return
        }
        val generation = sessionFence.begin() ?: return
        engineGeneration = generation
        if (!sessionFence.commit(generation) {
            starting = true
            DropoVpnRuntime.setStarting("VPN запускается")
            showForeground("VPN запускается")
        }) return
        executor.execute {
            try {
                Dropoandroid.ensureStarted(filesDir.absolutePath, packageVersionName())
                if (!sessionFence.commit(generation) {
                    syncCoreServiceState("starting", "VPN запускается")
                    Dropoandroid.call("AndroidEngineStarting", "[]")
                }) return@execute
                coreLog("startForeground requested")
                startEngine(generation)
            } catch (error: Throwable) {
                if (!sessionFence.isActive(generation)) {
                    Log.i(TAG, "cancelled VPN start discarded")
                    return@execute
                }
                val message = describeError(error)
                Log.e(TAG, "startEngine failed: $message", error)
                if (sessionFence.commit(generation) { coreError(message) }) {
                    stopVpn(stopSelf = true, failureMessage = message)
                }
            } finally {
                starting = false
            }
        }
    }

    private fun startEngine(generation: Long) {
        requireActiveSession(generation)
        if (commandServer != null) {
            coreLog("start skipped: command server is already running")
            sessionFence.commit(generation) {
                Dropoandroid.setConnected(true)
                DropoVpnRuntime.setConnected("VPN уже работает")
                syncCoreServiceState("connected", "VPN уже работает")
            }
            return
        }

        coreLog("libbox setup")
        ensureLibboxSetup(this)
        requireActiveSession(generation)
        coreLog("building sing-box config")
        val configResult = JSONObject(Dropoandroid.buildSingBoxConfig())
        requireActiveSession(generation)
        if (!configResult.optBoolean("success")) {
            error(configResult.optString("error", "Failed to build Android sing-box config"))
        }
        val config = configResult.getString("config")
        if (configResult.optBoolean("cached")) {
            coreLog("using cached sing-box config: ${configResult.optString("warning", "сохранённые серверы подписок")}")
        }
        verboseSingBoxLogs = androidSingBoxVerboseLogging()
        if (verboseSingBoxLogs) {
            coreLog("sing-box log capture enabled")
        }
        coreLog("checking sing-box config")
        Dropoandroid.checkConfig(config)
        requireActiveSession(generation)

        coreLog("starting command server")
        val server = CommandServer(this, this)
        var committed = false
        try {
            server.start()
            requireActiveSession(generation)
            coreLog("starting sing-box service")
            server.startOrReloadService(config, OverrideOptions().apply { autoRedirect = false })
            committed = sessionFence.commit(generation) {
                commandServer = server
                Dropoandroid.setConnected(true)
                val version = configResult.optString("version", Dropoandroid.version())
                DropoVpnRuntime.setConnected("VPN работает")
                syncCoreServiceState("connected", "VPN работает")
                coreLog("sing-box $version is active")
                showForeground("VPN работает")
                runCatching { server.startSourceSelection() }
                    .onFailure { coreLog("source selection could not start: ${describeError(it)}") }
            }
        } finally {
            if (!committed) {
                runCatching { server.stopSourceSelection() }
                runCatching { server.closeService() }
                runCatching { server.close() }
                closeTun()
            }
        }
    }

    private fun stopVpn(stopSelf: Boolean, failureMessage: String? = null) {
        // This fence must run on the requesting thread, before queued cleanup.
        // A subscription download may still be occupying the engine executor.
        sessionFence.cancel()
        runCatching { Dropoandroid.cancelPendingSourceWork() }
        runCatching { commandServer?.stopSourceSelection() }
        closeTun()
        synchronized(stopLock) {
            if (stopping) return
            stopping = true
        }
        if (failureMessage == null) {
            DropoVpnRuntime.setDisconnecting("VPN останавливается")
        }
        executor.execute {
            val server = commandServer
            val hadRuntime = server != null || tunInterface != null || starting
            starting = false
            commandServer = null
            runCatching { server?.closeService() }
            runCatching { server?.close() }
            closeTun()
            closeDefaultInterfaceMonitor(interfaceUpdateListener)
            if (hadRuntime) {
                coreLog("VpnService stopped")
            }
            verboseSingBoxLogs = false
            Dropoandroid.setConnected(false)
            if (failureMessage == null) {
                DropoVpnRuntime.setStopped("VPN остановлен")
                syncCoreServiceState("stopped", "VPN остановлен")
            } else {
                DropoVpnRuntime.setFailed(failureMessage)
                syncCoreServiceState("failed", failureMessage, failureMessage)
            }
            stopForegroundCompat()
            stopping = false
            if (stopSelf) {
                stopSelf()
            }
        }
    }

    private fun closeTun() {
        synchronized(tunLock) {
            runCatching { tunInterface?.close() }
            tunInterface = null
        }
    }

    private fun requireActiveSession(generation: Long = engineGeneration) {
        check(sessionFence.isActive(generation)) { "android: VPN session was cancelled" }
    }

    override fun openTun(options: TunOptions): Int {
        val generation = engineGeneration
        requireActiveSession(generation)
        if (prepare(this) != null) error("android: missing VPN permission")
        coreLog("open TUN mtu=${options.mtu}")

        val builder = Builder()
            .setSession("dropo")
            .setMtu(options.mtu.coerceAtLeast(1280))

        builder.setMetered(false)

        var hasInet4 = false
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet4 = true
        }

        var hasInet6 = false
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet6 = true
        }

        if (options.autoRoute) {
            runCatching {
                val dnsAddress = options.dnsServerAddress?.value
                if (!dnsAddress.isNullOrBlank()) {
                    builder.addDnsServer(dnsAddress)
                }
            }.onFailure {
                Log.w(TAG, "DNS hijack address unavailable", it)
            }
            addRoutes(builder, options, hasInet4, hasInet6)
            addApplications(builder, options)
        }

        if (options.isHTTPProxyEnabled) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList(),
                ),
            )
        }

        var descriptor = -1
        check(sessionFence.commit(generation) {
            synchronized(tunLock) {
                val pfd = builder.establish() ?: error("android: VPN establish returned null")
                runCatching { tunInterface?.close() }
                tunInterface = pfd
                descriptor = pfd.fd
            }
        }) { "android: VPN session was cancelled" }
        coreLog("TUN established fd=$descriptor")
        return descriptor
    }

    private fun addRoutes(
        builder: Builder,
        options: TunOptions,
        hasInet4: Boolean,
        hasInet6: Boolean,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            addRoutesWithExcludes(builder, options, hasInet4, hasInet6)
        } else {
            addRoutesLegacy(builder, options, hasInet4, hasInet6)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun addRoutesWithExcludes(
        builder: Builder,
        options: TunOptions,
        hasInet4: Boolean,
        hasInet6: Boolean,
    ) {
        var added4 = false
        val inet4Routes = options.inet4RouteAddress
        while (inet4Routes.hasNext()) {
            builder.addRoute(inet4Routes.next().toIpPrefix())
            added4 = true
        }
        if (!added4 && hasInet4) {
            builder.addRoute("0.0.0.0", 0)
        }

        var added6 = false
        val inet6Routes = options.inet6RouteAddress
        while (inet6Routes.hasNext()) {
            builder.addRoute(inet6Routes.next().toIpPrefix())
            added6 = true
        }
        if (!added6 && hasInet6) {
            builder.addRoute("::", 0)
        }

        val inet4Exclude = options.inet4RouteExcludeAddress
        while (inet4Exclude.hasNext()) {
            builder.excludeRoute(inet4Exclude.next().toIpPrefix())
        }
        val inet6Exclude = options.inet6RouteExcludeAddress
        while (inet6Exclude.hasNext()) {
            builder.excludeRoute(inet6Exclude.next().toIpPrefix())
        }
    }

    // API < 33: Builder.excludeRoute is unavailable, so route exclusions cannot be
    // expressed directly. RouteRange carries the merged prefixes sing-box computes
    // with the exclusions already subtracted.
    private fun addRoutesLegacy(
        builder: Builder,
        options: TunOptions,
        hasInet4: Boolean,
        hasInet6: Boolean,
    ) {
        var added4 = false
        val inet4Ranges = options.inet4RouteRange
        while (inet4Ranges.hasNext()) {
            val prefix = inet4Ranges.next()
            builder.addRoute(prefix.address(), prefix.prefix())
            added4 = true
        }
        if (!added4 && hasInet4) {
            builder.addRoute("0.0.0.0", 0)
        }

        var added6 = false
        val inet6Ranges = options.inet6RouteRange
        while (inet6Ranges.hasNext()) {
            val prefix = inet6Ranges.next()
            builder.addRoute(prefix.address(), prefix.prefix())
            added6 = true
        }
        if (!added6 && hasInet6) {
            builder.addRoute("::", 0)
        }
    }

    private fun addApplications(builder: Builder, options: TunOptions) {
        val includePackages = options.includePackage.toList()
        val excludePackages = options.excludePackage.toList().toMutableList()
        if (includePackages.isEmpty() && packageName !in excludePackages) {
            excludePackages += packageName
        }

        for (packageName in includePackages) {
            runCatching { builder.addAllowedApplication(packageName) }
                .onFailure { if (it is NameNotFoundException) Log.w(TAG, "unknown allowed app $packageName") }
        }

        for (packageName in excludePackages) {
            runCatching { builder.addDisallowedApplication(packageName) }
                .onFailure { if (it is NameNotFoundException) Log.w(TAG, "unknown disallowed app $packageName") }
        }
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            error("android: failed to protect socket fd=$fd from the VPN tunnel")
        }
    }

    override fun useProcFS(): Boolean = false

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = packageManager.getPackagesForUid(uid).orEmpty()
        return ConnectionOwner().apply {
            userId = uid
            userName = packages.firstOrNull().orEmpty()
            setAndroidPackageNames(StringArray(packages.asList().iterator()))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        check(sessionFence.commit(engineGeneration) {
            interfaceUpdateListener = listener
            if (!networkCallbackRegistered) {
                connectivity.registerNetworkCallback(
                    NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                        .build(),
                    networkCallback,
                )
                networkCallbackRegistered = true
            }
        }) { "android: VPN session was cancelled" }
        notifyDefaultInterfaceAsync()
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        interfaceUpdateListener = null
        physicalNetworkSignature = ""
        if (networkCallbackRegistered) {
            runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaInterfaces = JavaNetworkInterface.getNetworkInterfaces().toList()
        val result = mutableListOf<BoxNetworkInterface>()
        for (network in connectivity.allNetworks) {
            val linkProperties = connectivity.getLinkProperties(network) ?: continue
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            val name = linkProperties.interfaceName ?: continue
            val javaInterface = javaInterfaces.firstOrNull { it.name == name } ?: continue
            result += BoxNetworkInterface().apply {
                this.name = name
                index = javaInterface.index
                mtu = runCatching { javaInterface.mtu }.getOrDefault(1500)
                addresses = StringArray(javaInterface.interfaceAddresses.map { it.toPrefix() }.iterator())
                dnsServer = StringArray(linkProperties.dnsServers.mapNotNull { it.hostAddress }.iterator())
                type = when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Dropoandroid.InterfaceTypeWIFI
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Dropoandroid.InterfaceTypeCellular
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Dropoandroid.InterfaceTypeEthernet
                    else -> Dropoandroid.InterfaceTypeOther
                }
                metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                flags = javaInterface.toFlags(capabilities)
            }
        }
        return NetworkInterfaceArray(result.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun readWIFIState(): WIFIState? = null

    override fun systemCertificates(): StringIterator = StringArray(loadSystemCertificates().iterator())

    override fun clearDNSCache() {
    }

    override fun sendNotification(notification: BoxNotification) {
        val text = notification.body.ifBlank {
            notification.subtitle.ifBlank {
                notification.title.ifBlank { "VPN работает" }
            }
        }
        sessionFence.commit(engineGeneration) { showForeground(userNotificationText(text)) }
    }

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun serviceStop() {
        val protection = publishVpnProtection()
        if (!protection.observed || protection.alwaysOn) {
            coreLog("sing-box stop redirected to Android VPN settings")
            sessionFence.commit(engineGeneration) {
                showForeground(
                    if (protection.alwaysOn) "Always-on VPN управляется Android"
                    else "Сначала проверьте системные настройки VPN",
                    protection,
                )
            }
            return
        }
        coreLog("sing-box requested service stop")
        stopVpn(stopSelf = true)
    }

    override fun serviceReload() {
        val generation = engineGeneration
        // Command callbacks can arrive on a Go/gRPC thread. Keep reloads on
        // the same worker as start, cleanup and physical-network changes.
        if (Thread.currentThread() === engineThread) {
            reloadEngine(generation)
        } else {
            executor.submit { reloadEngine(generation) }.get()
        }
    }

    private fun reloadEngine(generation: Long) {
        requireActiveSession(generation)
        val configResult = JSONObject(Dropoandroid.buildSingBoxConfig())
        requireActiveSession(generation)
        if (!configResult.optBoolean("success")) {
            error(configResult.optString("error", "Failed to reload Android sing-box config"))
        }
        if (configResult.optBoolean("cached")) {
            coreLog("reloading cached sing-box config: ${configResult.optString("warning", "сохранённые серверы подписок")}")
        }
        verboseSingBoxLogs = androidSingBoxVerboseLogging()
        coreLog("reloading sing-box service")
        val server = commandServer ?: return
        server.stopSourceSelection()
        server.startOrReloadService(
            configResult.getString("config"),
            OverrideOptions().apply { autoRedirect = false },
        )
        sessionFence.commit(generation) { server.startSourceSelection() }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply {
            available = false
            enabled = false
        }

    override fun setSystemProxyEnabled(enabled: Boolean) {
    }

    override fun writeDebugMessage(message: String?) {
        val text = message.orEmpty().trim()
        if (text.isEmpty()) return
        if (isDebugBuild()) {
            Log.d("sing-box", text)
        }
        val important = isImportantSingBoxMessage(text)
        if (verboseSingBoxLogs) {
            nativeLogs.post("AndroidSingBoxLog", "[${JSONObject.quote(text.take(2000))}]")
            val runtimeNow = SystemClock.elapsedRealtime()
            if (runtimeNow - lastRuntimeSingBoxLogAt >= 500) {
                lastRuntimeSingBoxLogAt = runtimeNow
                DropoVpnRuntime.appendLog("sing-box: ${text.take(240)}")
            }
        }
        if (!important) return

        val now = SystemClock.elapsedRealtime()
        if (now - lastCoreDebugLogAt < 1000) return
        lastCoreDebugLogAt = now
        val line = "sing-box: ${text.take(240)}"
        DropoVpnRuntime.appendLog("android engine: $line")
        nativeLogs.post("AndroidEngineLog", "[${JSONObject.quote(line)}]")
    }

    private fun isImportantSingBoxMessage(text: String): Boolean {
        val normalized = text.lowercase(Locale.ROOT)
        if ("noerror" in normalized) return false
        return Regex("\\b(error|warn|warning|fatal|panic|exception|failed)\\b")
            .containsMatchIn(normalized)
    }

    private fun androidSingBoxVerboseLogging(): Boolean {
        return runCatching {
            val config = JSONObject(Dropoandroid.call("GetAppConfig", "[]"))
            config.optBoolean("enableLogging", true)
        }.getOrDefault(true)
    }

    private fun coreLog(message: String) {
        DropoVpnRuntime.appendLog("android engine: $message")
        Dropoandroid.call("AndroidEngineLog", "[${JSONObject.quote(message)}]")
    }

    private fun coreError(message: String) {
        DropoVpnRuntime.setFailed(message)
        DropoVpnRuntime.appendLog("android engine error: $message")
        Dropoandroid.call("AndroidEngineError", "[${JSONObject.quote(message)}]")
    }

    private fun syncCoreServiceState(
        state: String,
        message: String,
        error: String = "",
    ) {
        Dropoandroid.call(
            "AndroidServiceState",
            "[${JSONObject.quote(state)},${JSONObject.quote(message)},${JSONObject.quote(error)}]",
        )
    }

    private fun describeError(error: Throwable): String {
        val message = error.message ?: error.javaClass.simpleName
        return "${error.javaClass.simpleName}: $message"
    }

    private fun packageVersionName(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0),
                ).versionName ?: "dev"
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0).versionName ?: "dev"
            }
        } catch (_: Throwable) {
            "dev"
        }
    }

    private fun notifyDefaultInterfaceAsync() {
        val generation = engineGeneration
        runCatching {
            executor.execute {
                if (sessionFence.isActive(generation)) notifyDefaultInterface(generation)
            }
        }.onFailure {
            Log.w(TAG, "default interface update skipped", it)
        }
    }

    private fun notifyDefaultInterface(generation: Long) {
        val listener = interfaceUpdateListener ?: return
        val network = physicalNetwork()
        val linkProperties = network?.let { connectivity.getLinkProperties(it) }
        val capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
        val name = linkProperties?.interfaceName
        val javaInterface = name?.let { JavaNetworkInterface.getByName(it) }
        if (network == null || linkProperties == null || capabilities == null || name == null || javaInterface == null) {
            sessionFence.commit(generation) {
                if (interfaceUpdateListener === listener && physicalNetworkSignature != "offline") {
                    physicalNetworkSignature = "offline"
                    setUnderlyingNetworks(emptyArray())
                    listener.updateDefaultInterface("", -1, false, false)
                    commandServer?.stopSourceSelection()
                }
            }
            return
        }
        val signature = "$network:$name:${linkProperties.linkAddresses}:${linkProperties.dnsServers}"
        sessionFence.commit(generation) {
            if (interfaceUpdateListener !== listener) return@commit
            val restored = physicalNetworkSignature == "offline"
            val changed = signature != physicalNetworkSignature
            physicalNetworkSignature = signature
            setUnderlyingNetworks(arrayOf(network))
            listener.updateDefaultInterface(
                name,
                javaInterface.index,
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED),
            )
            if (changed) {
                runCatching {
                    if (restored) {
                        commandServer?.startSourceSelection()
                    } else {
                        commandServer?.recheckSourceSelection()
                    }
                }.onFailure { coreLog("network source recheck could not start: ${describeError(it)}") }
            }
        }
    }

    private fun physicalNetwork(): Network? {
        fun usable(network: Network): Boolean {
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }
        connectivity.activeNetwork?.let { if (usable(it)) return it }
        return connectivity.allNetworks.filter(::usable).maxByOrNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
            var score = 0
            if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) score += 4
            if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true) score += 2
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) score += 1
            score
        }
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        foregroundActive = false
        foregroundText = ""
        notificationAlwaysOn = null
    }

    private fun showForeground(
        text: String,
        protection: VpnProtectionState = publishVpnProtection(),
    ) {
        foregroundText = text
        startForegroundCompat(buildNotification(text, protection))
        foregroundActive = true
        notificationAlwaysOn = protection.alwaysOn
    }

    private fun refreshVpnProtectionAndNotification() {
        val protection = publishVpnProtection()
        if (foregroundActive && notificationAlwaysOn != protection.alwaysOn) {
            runCatching {
                executor.execute {
                    if (foregroundActive && notificationAlwaysOn != protection.alwaysOn) {
                        showForeground(foregroundText.ifBlank { "VPN работает" }, protection)
                    }
                }
            }.onFailure {
                Log.w(TAG, "VPN notification protection refresh skipped", it)
            }
        }
    }

    private fun publishVpnProtection(): VpnProtectionState {
        val protection = runCatching {
            VpnProtectionState(
                observed = true,
                alwaysOn = isAlwaysOn,
                lockdown = isLockdownEnabled,
            )
        }.getOrElse {
            Log.w(TAG, "could not read Android VPN protection state", it)
            VpnProtectionState(observed = false, alwaysOn = false, lockdown = false)
        }
        DropoVpnRuntime.setVpnProtection(
            observed = protection.observed,
            alwaysOn = protection.alwaysOn,
            lockdown = protection.lockdown,
        )
        return protection
    }

    private fun buildNotification(
        text: String,
        protection: VpnProtectionState,
    ): Notification {
        val safeText = userNotificationText(text)
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val openPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, DropoVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("dropo VPN")
            .setContentText(safeText)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openPendingIntent)
        if (protection.observed && !protection.alwaysOn) {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Отключить",
                stopPendingIntent,
            )
        }
        return builder.build()
    }

    private fun userNotificationText(text: String): String {
        val normalized = text.trim()
        if (normalized.isEmpty()) return "VPN работает"
        if (normalized.contains("sing-box", ignoreCase = true)) return "VPN работает"
        if (normalized.contains("active", ignoreCase = true)) return "VPN работает"
        if (normalized.contains("connected", ignoreCase = true)) return "VPN работает"
        if (normalized.contains("starting", ignoreCase = true)) return "VPN запускается"
        if (normalized.contains("stopping", ignoreCase = true)) return "VPN останавливается"
        if (normalized.contains("stopped", ignoreCase = true)) return "VPN остановлен"
        return normalized
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "dropo VPN",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun InterfaceAddress.toPrefix(): String {
        val host = if (address is Inet6Address) {
            Inet6Address.getByAddress(address.address).hostAddress?.substringBefore("%").orEmpty()
        } else {
            address.hostAddress.orEmpty()
        }
        return "$host/$networkPrefixLength"
    }

    private fun JavaNetworkInterface.toFlags(capabilities: NetworkCapabilities): Int {
        var value = 0
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            value = value or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        }
        if (runCatching { isLoopback }.getOrDefault(false)) value = value or OsConstants.IFF_LOOPBACK
        if (runCatching { isPointToPoint }.getOrDefault(false)) value = value or OsConstants.IFF_POINTOPOINT
        if (runCatching { supportsMulticast() }.getOrDefault(false)) value = value or OsConstants.IFF_MULTICAST
        return value
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun RoutePrefix.toIpPrefix(): IpPrefix {
        return IpPrefix(InetAddress.getByName(address()), prefix())
    }

    private fun StringIterator.toList(): List<String> {
        val result = mutableListOf<String>()
        while (hasNext()) {
            result += next()
        }
        return result
    }

    private class StringArray(iterator: Iterator<String>) : StringIterator {
        private val values = iterator.asSequence().toList()
        private var index = 0

        override fun len(): Int = values.size - index
        override fun hasNext(): Boolean = index < values.size
        override fun next(): String = values[index++]
    }

    private class NetworkInterfaceArray(
        private val iterator: Iterator<BoxNetworkInterface>,
    ) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): BoxNetworkInterface = iterator.next()
    }

    private data class VpnProtectionState(
        val observed: Boolean,
        val alwaysOn: Boolean,
        val lockdown: Boolean,
    )

    companion object {
        private const val TAG = "DropoVpnService"
        private const val CHANNEL_ID = "dropo_vpn"
        private const val NOTIFICATION_ID = 5001
        private const val ACTION_START = "in.droponevedimka.dropo.START_VPN"
        private const val ACTION_STOP = "in.droponevedimka.dropo.STOP_VPN"

        private val libboxSetup = AtomicBoolean(false)
        private val certificateCache = mutableListOf<String>()

        @Volatile
        private var activeService: DropoVpnService? = null

        fun refreshVpnProtection(): Map<String, Any?> {
            val service = activeService
            if (service == null) {
                DropoVpnRuntime.setVpnProtection(
                    observed = false,
                    alwaysOn = false,
                    lockdown = false,
                )
            } else {
                service.refreshVpnProtectionAndNotification()
            }
            return DropoVpnRuntime.vpnProtectionSnapshot()
        }

        fun start(context: Context) {
            val intent = Intent(context, DropoVpnService::class.java).setAction(ACTION_START)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, DropoVpnService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }

        private fun ensureLibboxSetup(context: Context) {
            if (libboxSetup.get()) return
            synchronized(libboxSetup) {
                if (libboxSetup.get()) return
                val workingDir = java.io.File(context.noBackupFilesDir, "libbox").apply {
                    if (!exists() && !mkdirs()) {
                        error("Failed to create private libbox working directory")
                    }
                }
                Dropoandroid.setup(
                    BoxSetupOptions().apply {
                        basePath = context.filesDir.absolutePath
                        workingPath = workingDir.absolutePath
                        tempPath = context.cacheDir.absolutePath
                        logMaxLines = 2400
                        debug = context.isDebugBuild()
                    },
                )
                libboxSetup.set(true)
            }
        }

        private fun loadSystemCertificates(): List<String> {
            synchronized(certificateCache) {
                if (certificateCache.isNotEmpty()) return certificateCache.toList()
                runCatching {
                    val keyStore = KeyStore.getInstance("AndroidCAStore")
                    keyStore.load(null)
                    val aliases = keyStore.aliases()
                    while (aliases.hasMoreElements()) {
                        val certificate = keyStore.getCertificate(aliases.nextElement()) as? X509Certificate
                        if (certificate != null) {
                            certificateCache += certificate.toPem()
                        }
                    }
                }.onFailure {
                    Log.w(TAG, "system certificate load failed", it)
                }
                return certificateCache.toList()
            }
        }

        private fun X509Certificate.toPem(): String {
            val encoded = Base64.encodeToString(encoded, Base64.NO_WRAP)
                .chunked(64)
                .joinToString("\n")
            return "-----BEGIN CERTIFICATE-----\n$encoded\n-----END CERTIFICATE-----\n"
        }
    }
}
