import java.io.InputStream;
import java.nio.file.Path;
import java.security.CodeSigner;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/** Build-only verifier: every payload entry must have the pinned upload signer. */
class VerifyBundleSignature {
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !args[1].matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Expected bundle path and pinned SHA-256.");
        }
        Set<String> names = new HashSet<>();
        int signedEntries = 0;
        try (JarFile archive = new JarFile(Path.of(args[0]).toFile(), true)) {
            if (archive.getManifest() == null) {
                throw new SecurityException("Unsigned AAB: missing JAR manifest.");
            }
            var entries = archive.entries();
            byte[] buffer = new byte[65536];
            while (entries.hasMoreElements()) {
                JarEntry entry = entries.nextElement();
                String name = entry.getName();
                if (!names.add(name)) {
                    throw new SecurityException("Duplicate AAB entry.");
                }
                if (entry.isDirectory()) continue;
                // JAR digest/signature checks run while each entry is fully consumed.
                try (InputStream stream = archive.getInputStream(entry)) {
                    while (stream.read(buffer) != -1) { }
                }
                String upperName = name.toUpperCase(Locale.ROOT);
                // Only JAR signature metadata may legitimately be unsigned, not
                // arbitrary payload stored under META-INF.
                if (upperName.equals("META-INF/MANIFEST.MF") ||
                        upperName.matches("META-INF/[^/]+\\.(SF|RSA|DSA|EC)") ||
                        upperName.matches("META-INF/SIG-[^/]+")) continue;
                CodeSigner[] signers = entry.getCodeSigners();
                if (signers == null || signers.length != 1) {
                    throw new SecurityException("Unsigned or multiply signed AAB payload entry.");
                }
                X509Certificate certificate = (X509Certificate)
                        signers[0].getSignerCertPath().getCertificates().get(0);
                certificate.checkValidity();
                String subject = certificate.getSubjectX500Principal().getName();
                if (subject.toLowerCase(Locale.ROOT).contains("android debug")) {
                    throw new SecurityException("Android debug signing is forbidden for Play bundles.");
                }
                String fingerprint = HexFormat.of().formatHex(
                        MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
                if (!fingerprint.equals(args[1])) {
                    String sha1 = HexFormat.ofDelimiter(":").withUpperCase().formatHex(
                            MessageDigest.getInstance("SHA-1").digest(certificate.getEncoded()));
                    throw new SecurityException("Unexpected AAB upload certificate. Expected SHA-256: "
                            + args[1] + "; actual SHA-256: " + fingerprint + "; actual SHA-1: " + sha1
                            + ". Use the upload key registered in Play Console, or complete its reset first.");
                }
                signedEntries++;
            }
        }
        if (signedEntries == 0) throw new SecurityException("AAB contains no signed payload.");
        System.out.println("Pinned upload signature and all " + signedEntries + " payload entries verified.");
    }
}
