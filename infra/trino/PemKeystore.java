// The node agent's machine.pem (the certificate, then its PKCS#8 key) as a
// PKCS#12 keystore, which is what the JVM presents a client certificate from
// (decision 0066, point 10). infra/trino/entrypoint.sh runs it at each start,
// from source, with the image's JDK, which has no other tool for it.
//
//   java PemKeystore.java <machine.pem> <keystore.p12> <password>
//
// Nothing of the files is printed.
import java.io.ByteArrayInputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class PemKeystore {
    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            fail("usage: PemKeystore <machine.pem> <keystore.p12> <password>");
        }
        Matcher blocks = Pattern.compile("-----BEGIN ([A-Z ]+)-----(.*?)-----END \\1-----", Pattern.DOTALL)
                .matcher(Files.readString(Path.of(args[0])));
        List<Certificate> chain = new ArrayList<>();
        byte[] key = null;
        while (blocks.find()) {
            byte[] der = Base64.getMimeDecoder().decode(blocks.group(2));
            if (blocks.group(1).equals("CERTIFICATE")) {
                chain.add(CertificateFactory.getInstance("X.509").generateCertificate(new ByteArrayInputStream(der)));
            } else if (blocks.group(1).equals("PRIVATE KEY")) {
                key = der;
            }
        }
        if (chain.isEmpty() || key == null) {
            fail("no certificate with a PKCS#8 key in the file");
        }
        // The key is of the kind its certificate's is.
        PrivateKey parsed = KeyFactory.getInstance(chain.get(0).getPublicKey().getAlgorithm())
                .generatePrivate(new PKCS8EncodedKeySpec(key));
        char[] password = args[2].toCharArray();
        KeyStore store = KeyStore.getInstance("PKCS12");
        store.load(null, null);
        store.setKeyEntry("machine", parsed, password, chain.toArray(new Certificate[0]));
        try (OutputStream out = Files.newOutputStream(Path.of(args[1]))) {
            store.store(out, password);
        }
    }

    private static void fail(String why) {
        System.err.println("PemKeystore: " + why);
        System.exit(1);
    }
}
