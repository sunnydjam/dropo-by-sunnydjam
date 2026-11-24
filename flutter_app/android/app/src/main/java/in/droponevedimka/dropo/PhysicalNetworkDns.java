package in.droponevedimka.dropo;

import android.net.DnsResolver;
import android.net.Network;
import android.os.CancellationSignal;

import java.io.IOException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Resolves one unmodified wire query on the selected physical Android network. */
final class PhysicalNetworkDns {
    private PhysicalNetworkDns() {}

    static byte[] exchange(Network network, byte[] query) throws IOException {
        CompletableFuture<byte[]> response = new CompletableFuture<>();
        CancellationSignal cancellation = new CancellationSignal();
        try {
            DnsResolver.getInstance().rawQuery(network, query, DnsResolver.FLAG_EMPTY,
                    Runnable::run, cancellation, new DnsResolver.Callback<byte[]>() {
                        @Override public void onAnswer(byte[] answer, int rcode) {
                            response.complete(answer);
                        }

                        @Override public void onError(DnsResolver.DnsException error) {
                            response.completeExceptionally(error);
                        }
                    });
            return response.get(5, TimeUnit.SECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Network DNS interrupted", interrupted);
        } catch (ExecutionException | TimeoutException failure) {
            throw new IOException("Network DNS query failed", failure);
        } finally {
            cancellation.cancel();
        }
    }
}
