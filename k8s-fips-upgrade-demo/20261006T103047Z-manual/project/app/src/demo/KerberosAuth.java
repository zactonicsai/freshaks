package demo;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import javax.security.auth.Subject;
import javax.security.auth.callback.Callback;
import javax.security.auth.callback.CallbackHandler;
import javax.security.auth.callback.NameCallback;
import javax.security.auth.callback.PasswordCallback;
import javax.security.auth.kerberos.KerberosKey;
import javax.security.auth.kerberos.KerberosPrincipal;
import javax.security.auth.kerberos.KerberosTicket;
import javax.security.auth.kerberos.KeyTab;
import javax.security.auth.login.AppConfigurationEntry;
import javax.security.auth.login.Configuration;
import javax.security.auth.login.LoginContext;
import javax.security.auth.login.LoginException;
import org.ietf.jgss.GSSContext;
import org.ietf.jgss.GSSCredential;
import org.ietf.jgss.GSSManager;
import org.ietf.jgss.GSSName;
import org.ietf.jgss.Oid;

/**
 * Checks a user name and password against the FreeIPA Kerberos server (the "KDC").
 *
 * Step 1: ask the KDC for a ticket (TGT) with the password. A wrong password means no ticket.
 * Step 2: use that ticket to ask for a ticket to OUR OWN service, then open it with our keytab.
 *         Only the real KDC knows our service key, so this proves we did not talk to a fake KDC.
 */
final class KerberosAuth {
    record Result(boolean ok, String principal, String ticketEnctype, String error) { }

    private static final Pattern SAFE_USER = Pattern.compile("[A-Za-z0-9._-]{1,64}");
    private static final String KRB5_LOGIN_MODULE = "com.sun.security.auth.module.Krb5LoginModule";

    private final Config cfg;
    private final Oid krb5Mech;
    private final Oid krb5PrincipalName;
    private Subject serviceSubject;

    KerberosAuth(Config cfg) throws Exception {
        this.cfg = cfg;
        this.krb5Mech = new Oid("1.2.840.113554.1.2.2");
        this.krb5PrincipalName = new Oid("1.2.840.113554.1.2.2.1");
        if (cfg.validateTgt) {
            this.serviceSubject = serviceLogin();
        }
    }

    Result login(String user, char[] password) {
        if (user == null || !SAFE_USER.matcher(user).matches()) {
            return new Result(false, null, null, "user name has characters that are not allowed");
        }
        String principal = user + "@" + cfg.realm;
        LoginContext lc = null;
        try {
            Map<String, String> opts = new HashMap<>();
            opts.put("useTicketCache", "false");
            opts.put("storeKey", "false");
            opts.put("doNotPrompt", "false");
            opts.put("isInitiator", "true");
            CallbackHandler handler = (Callback[] cbs) -> {
                for (Callback cb : cbs) {
                    if (cb instanceof NameCallback n) {
                        n.setName(principal);
                    } else if (cb instanceof PasswordCallback p) {
                        p.setPassword(password);
                    }
                }
            };
            lc = new LoginContext("fipsdemo-user", null, handler, jaas(opts));
            lc.login();                                   // <-- talks to the KDC (TCP port 88)
            Subject userSubject = lc.getSubject();
            String enctype = "unknown";
            for (KerberosTicket t : userSubject.getPrivateCredentials(KerberosTicket.class)) {
                enctype = enctypeName(t.getSessionKeyType());
                break;
            }
            if (cfg.validateTgt) {
                String proven = proveKdcIsReal(userSubject);
                if (!principal.equalsIgnoreCase(proven)) {
                    return new Result(false, null, null, "ticket check gave a different name: " + proven);
                }
            }
            return new Result(true, principal, enctype, null);
        } catch (LoginException e) {
            return new Result(false, null, null, String.valueOf(e.getMessage()));
        } catch (Exception e) {
            return new Result(false, null, null, e.getClass().getSimpleName() + ": " + e.getMessage());
        } finally {
            if (lc != null) {
                try {
                    lc.logout();
                } catch (LoginException ignored) {
                    // nothing to clean up
                }
            }
        }
    }

    private String proveKdcIsReal(Subject userSubject) throws Exception {
        byte[] token = Subject.callAs(userSubject, () -> {
            GSSManager m = GSSManager.getInstance();
            GSSName service = m.createName(cfg.servicePrincipal, krb5PrincipalName);
            GSSContext ctx = m.createContext(service, krb5Mech, null, GSSContext.DEFAULT_LIFETIME);
            ctx.requestMutualAuth(false);
            ctx.requestCredDeleg(false);
            byte[] out = ctx.initSecContext(new byte[0], 0, 0);   // <-- second trip to the KDC
            ctx.dispose();
            return out;
        });
        try {
            return accept(token);
        } catch (Exception first) {
            synchronized (this) {
                serviceSubject = serviceLogin();   // keytab file may have been replaced: read it again
            }
            return accept(token);
        }
    }

    private String accept(byte[] token) throws Exception {
        Subject svc;
        synchronized (this) {
            svc = serviceSubject;
        }
        return Subject.callAs(svc, () -> {
            GSSManager m = GSSManager.getInstance();
            GSSCredential cred = m.createCredential(null, GSSCredential.INDEFINITE_LIFETIME,
                    krb5Mech, GSSCredential.ACCEPT_ONLY);
            GSSContext ctx = m.createContext(cred);
            ctx.acceptSecContext(token, 0, token.length);
            String who = ctx.getSrcName().toString();
            ctx.dispose();
            return who;
        });
    }

    private Subject serviceLogin() throws LoginException {
        Map<String, String> opts = new HashMap<>();
        opts.put("useKeyTab", "true");
        opts.put("keyTab", cfg.keytab);
        opts.put("principal", cfg.servicePrincipal);
        opts.put("storeKey", "true");
        opts.put("isInitiator", "false");   // only load the keys, no network needed
        opts.put("doNotPrompt", "true");
        LoginContext lc = new LoginContext("fipsdemo-service", null, null, jaas(opts));
        lc.login();
        return lc.getSubject();
    }

    private static Configuration jaas(Map<String, String> options) {
        AppConfigurationEntry entry = new AppConfigurationEntry(KRB5_LOGIN_MODULE,
                AppConfigurationEntry.LoginModuleControlFlag.REQUIRED, options);
        return new Configuration() {
            @Override
            public AppConfigurationEntry[] getAppConfigurationEntry(String name) {
                return new AppConfigurationEntry[] {entry};
            }
        };
    }

    /** Which key types are inside our keytab file (shown on the status page). */
    List<String> keytabEnctypes() {
        List<String> names = new ArrayList<>();
        try {
            KeyTab kt = KeyTab.getInstance(new KerberosPrincipal(cfg.servicePrincipal), new File(cfg.keytab));
            for (KerberosKey k : kt.getKeys(new KerberosPrincipal(cfg.servicePrincipal))) {
                String n = enctypeName(k.getKeyType());
                if (!names.contains(n)) {
                    names.add(n);
                }
            }
        } catch (Exception e) {
            names.add("unreadable: " + e.getMessage());
        }
        return names;
    }

    static String enctypeName(int type) {
        return switch (type) {
            case 17 -> "aes128-cts-hmac-sha1-96";
            case 18 -> "aes256-cts-hmac-sha1-96";
            case 19 -> "aes128-cts-hmac-sha256-128";
            case 20 -> "aes256-cts-hmac-sha384-192";
            case 23 -> "rc4-hmac";
            case 16 -> "des3-cbc-sha1";
            default -> "etype-" + type;
        };
    }

    /** True for the two SHA-2 key types, the only ones a FIPS system accepts. */
    static boolean isSha2Enctype(String name) {
        return name.contains("sha256") || name.contains("sha384");
    }
}
