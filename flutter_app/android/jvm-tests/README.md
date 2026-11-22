# Android policy tests on the JVM

Run from `flutter_app/android` with JDK 17 or later:

```powershell
./gradlew.bat -p jvm-tests test --no-daemon
```

The harness compiles the platform-independent **production Kotlin files** from
`app/src/main/kotlin` and runs the same tests in `app/src/test/kotlin`. It needs no
Android SDK, Flutter build, private signing key or generated Go AAR. CI runs this
suite on every pull request; full local Android checks can additionally use
`:app:testDebugUnitTest` after preparing the Android toolchain and AAR.

This suite covers execution queues, cancellation, update download/resume and
validation policies, session fencing and other pure policies. It does not replace
device tests for VpnService, Activity recreation, package installation or WebView.
