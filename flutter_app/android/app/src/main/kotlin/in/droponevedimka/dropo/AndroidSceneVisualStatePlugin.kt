package `in`.droponevedimka.dropo

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/** Provides the Android callbacks the Flutter scene needs during startup. */
class AndroidSceneVisualStatePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                val id = (call.arguments as? Number)?.toLong() ?: -1L
                val view = WebViewFlutterAndroidExternalApi.getWebView(binding, id)
                when (call.method) {
                    "observeRenderer" -> {
                        if (view == null || view.url != null) {
                            result.error("INVALID_SCENE_VIEW", null, null)
                        } else {
                            observeRenderer(view, MethodChannel(binding.binaryMessenger, "$CHANNEL/$id"))
                            result.success(null)
                        }
                    }
                    "awaitFrame" -> awaitFrame(view, id, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun observeRenderer(view: WebView, events: MethodChannel) {
        val navigation = view.webViewClient
        // Keep the local-only navigation policy and resource-error reporting
        // from the Flutter WebView plugin.
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                navigation.shouldOverrideUrlLoading(view, request)

            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) =
                navigation.onPageStarted(view, url, favicon)

            override fun onPageFinished(view: WebView, url: String) =
                navigation.onPageFinished(view, url)

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) =
                navigation.onReceivedError(view, request, error)

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
                events.invokeMethod("rendererGone", null)
                return true
            }
        }
    }

    private fun awaitFrame(view: WebView?, id: Long, result: MethodChannel.Result) {
        if (view == null || !view.isAttachedToWindow || view.width <= 0 ||
            view.height <= 0 || view.url != SCENE_URL
        ) {
            result.success(null)
            return
        }
        val width = view.width
        val height = view.height
        var completed = false
        val expires = Runnable {
            if (!completed) {
                completed = true
                result.success(null)
            }
        }
        view.postVisualStateCallback(id, object : WebView.VisualStateCallback() {
            override fun onComplete(requestId: Long) {
                if (completed) return
                completed = true
                mainHandler.removeCallbacks(expires)
                val current = view.isAttachedToWindow && view.url == SCENE_URL &&
                    view.width == width && view.height == height
                result.success(if (current) listOf(width, height) else null)
            }
        })
        mainHandler.postDelayed(expires, 1500)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private companion object {
        const val CHANNEL = "dropo/android-scene"
        const val SCENE_URL = "file:///android_asset/flutter_assets/assets/android_home/index.html"
    }
}
