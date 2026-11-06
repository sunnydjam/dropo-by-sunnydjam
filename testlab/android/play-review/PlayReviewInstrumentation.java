package dropo.lab.playreview;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskCompletionSource;
import com.google.android.gms.tasks.Tasks;
import com.google.android.play.core.review.ReviewInfo;
import com.google.android.play.core.review.ReviewManager;
import com.google.android.play.core.review.testing.FakeReviewManager;
import in.droponevedimka.dropo.PlayReviewClient;
import in.droponevedimka.dropo.ReviewPromptState;
import in.droponevedimka.dropo.ReviewPromptStore;
import in.droponevedimka.dropo.ReviewPromptTracker;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import kotlin.Unit;

/** Owned preview emulator only. No production toggle, Store calls or reviews. */
public final class PlayReviewInstrumentation extends Instrumentation {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private Activity activity;

    private static final class Store implements ReviewPromptStore {
        volatile ReviewPromptState state = new ReviewPromptState(3, true, false);
        public ReviewPromptState read() { return state; }
        public boolean write(ReviewPromptState value) { state = value; return true; }
    }

    private final class Manager implements ReviewManager {
        final FakeReviewManager fake = new FakeReviewManager(getTargetContext());
        Task<ReviewInfo> pending;
        boolean failRequest;
        boolean throwLaunch;
        int launches;
        public Task<ReviewInfo> requestReviewFlow() {
            if (failRequest) return Tasks.forException(new IllegalStateException("fixture request"));
            return pending == null ? fake.requestReviewFlow() : pending;
        }
        public Task<Void> launchReviewFlow(Activity target, ReviewInfo info) {
            launches++;
            if (throwLaunch) throw new IllegalStateException("fixture launch");
            return fake.launchReviewFlow(target, info);
        }
    }

    private final class Fixture {
        final Store store = new Store();
        final ReviewPromptTracker tracker = new ReviewPromptTracker(store, SystemClock::elapsedRealtime);
        final AtomicBoolean visible = new AtomicBoolean(true);
        final Manager manager = new Manager();
        PlayReviewClient client;
        Fixture() {
            runOnMainSync(() -> client = new PlayReviewClient(activity, tracker, worker,
                visible::get, manager));
        }
    }

    private static void require(boolean value, String detail) {
        if (!value) throw new IllegalStateException(detail);
    }
    private static void await(CountDownLatch latch) throws Exception {
        require(latch.await(20, TimeUnit.SECONDS), "fixture timeout");
    }
    private Map<String, Boolean> prepare(Fixture f) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Map<String, Boolean>> response = new AtomicReference<>();
        runOnMainSync(() -> f.client.prepare(value -> {
            response.set(value); done.countDown(); return Unit.INSTANCE;
        }));
        await(done);
        return response.get();
    }
    private Map<String, Boolean> launch(Fixture f, String id) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Map<String, Boolean>> response = new AtomicReference<>();
        runOnMainSync(() -> f.client.launch(id, value -> {
            response.set(value); done.countDown(); return Unit.INSTANCE;
        }));
        await(done);
        return response.get();
    }

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        ArrayList<String> checks = new ArrayList<>();
        try {
            require(getTargetContext().getPackageName().equals("in.droponevedimka.dropo.preview") &&
                android.os.Build.FINGERPRINT.contains("generic"), "owned preview emulator required");
            activity = startActivitySync(new Intent().setClassName(getTargetContext(),
                "in.droponevedimka.dropo.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));

            Fixture ok = new Fixture();
            require(Boolean.TRUE.equals(prepare(ok).get("prepared")), "fake preparation");
            String id = ok.tracker.claim();
            require(id != null && Boolean.TRUE.equals(launch(ok, id).get("attempted")), "fake launch");
            require(ok.store.state.getShown() && ok.manager.launches == 1 &&
                ok.tracker.claim() == null && !ok.tracker.cancelUnpresentedClaim(id), "one launch budget");
            launch(ok, id);
            require(ok.manager.launches == 1 && ok.store.state.getShown(), "no repeat");
            checks.add("official fake SDK launch consumes one budget, with no visibility inference");

            Fixture failure = new Fixture(); failure.manager.failRequest = true;
            require(!Boolean.TRUE.equals(prepare(failure).get("prepared")) &&
                !failure.store.state.getShown() && failure.manager.launches == 0, "request failure");
            checks.add("request failure remains silent and never launches");

            Fixture moved = new Fixture(); prepare(moved); String movedId = moved.tracker.claim();
            moved.visible.set(false);
            Map<String, Boolean> deferred = launch(moved, movedId);
            require(Boolean.TRUE.equals(deferred.get("retryLater")) && !moved.store.state.getShown() &&
                moved.manager.launches == 0, "background reservation release");
            checks.add("foreground lost before launch releases only the unpresented claim");

            Fixture expired = new Fixture(); prepare(expired); String expiredId = expired.tracker.claim();
            Field at = PlayReviewClient.class.getDeclaredField("preparedAt"); at.setAccessible(true);
            runOnMainSync(() -> {
                try { at.setLong(expired.client, SystemClock.elapsedRealtime() - 31000); }
                catch (Exception error) { throw new RuntimeException(error); }
            });
            launch(expired, expiredId);
            require(!expired.store.state.getShown() && expired.manager.launches == 0, "expired info");
            checks.add("expired ReviewInfo cannot launch");

            Fixture brokenLaunch = new Fixture(); brokenLaunch.manager.throwLaunch = true;
            prepare(brokenLaunch); String brokenId = brokenLaunch.tracker.claim();
            require(Boolean.TRUE.equals(launch(brokenLaunch, brokenId).get("attempted")) &&
                brokenLaunch.store.state.getShown(), "unknown launch result must not repeat");
            checks.add("launch exception consumes unknown-outcome budget without fallback");

            Fixture late = new Fixture(); TaskCompletionSource<ReviewInfo> source = new TaskCompletionSource<>();
            late.manager.pending = source.getTask();
            require(!Boolean.TRUE.equals(prepare(late).get("prepared")), "bounded timeout");
            runOnMainSync(() -> source.setResult(late.manager.fake.requestReviewFlow().getResult()));
            waitForIdleSync();
            launch(late, late.tracker.claim());
            require(late.manager.launches == 0 && !late.store.state.getShown(), "late reply discarded");
            checks.add("preparation timeout discards late replies without consuming launch budget");

            Fixture closed = new Fixture(); TaskCompletionSource<ReviewInfo> closeSource = new TaskCompletionSource<>();
            closed.manager.pending = closeSource.getTask(); AtomicInteger replies = new AtomicInteger();
            runOnMainSync(() -> {
                closed.client.prepare(value -> { replies.incrementAndGet(); return Unit.INSTANCE; });
                closed.client.close();
                closeSource.setResult(closed.manager.fake.requestReviewFlow().getResult());
            });
            waitForIdleSync();
            require(replies.get() == 1 && closed.manager.launches == 0, "closed client late callback");
            checks.add("destroyed activity cannot launch a late request");

            result.putString("passed", "true");
            result.putStringArrayList("checks", checks);
            result.putString("realGoogleCardShown", "false");
            result.putString("reviewSubmitted", "false");
            finish(-1, result);
        } catch (Exception error) {
            result.putString("passed", "false"); result.putString("errorType", error.getClass().getSimpleName());
            result.putString("detail", error.getMessage()); finish(1, result);
        } finally { worker.shutdownNow(); }
    }
}
