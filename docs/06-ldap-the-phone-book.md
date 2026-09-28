# 06 · LDAP, the phone book (user federation)

## Background

Most companies already have a list of employees somewhere — Active Directory, an HR system, an old LDAP server.
Nobody wants to retype 500 people into Keycloak. **LDAP** (Lightweight Directory Access Protocol) is the classic
"phone book" protocol: a tree of entries like

```
dc=freshmart,dc=local                         ← the company
├── ou=people
│   ├── uid=alex.ldap   (cn, sn, mail, userPassword)
│   ├── uid=jordan.ldap
│   └── uid=riley.ldap
└── ou=groups
    ├── cn=cashiers   member: uid=jordan.ldap,ou=people,…
    └── cn=managers   member: uid=riley.ldap,ou=people,…
```

**User federation** in Keycloak means: "when someone logs in, also look them up in this phone book". Keycloak
imports the entry, checks the password *against LDAP* (it never copies passwords), and can map LDAP groups to
Keycloak groups — which give roles, which end up on the badge. Same doors, same rules, different source of people.

## What the scripts do

`scripts/04-install-openldap.sh` runs the `osixia/openldap` image in namespace `identity` and loads
`k8s/openldap/seed.ldif` (rendered with `envsubst`, so the base DN and passwords come from `00-config.sh`).

`scripts/06-configure-realm.sh` then talks to Keycloak with `kcadm` and creates two *components*:

1. **`freshmart-ldap`** (type `UserStorageProvider`, from `k8s/keycloak/ldap-federation.json`):
   connection URL `ldap://openldap.identity.svc.cluster.local:389`, bind DN `cn=admin,<base>`, users DN
   `ou=people,<base>`, username attribute `uid`, edit mode `READ_ONLY`, import users on.
2. **`ldap-groups`** (type `group-ldap-mapper`, from `k8s/keycloak/ldap-group-mapper.json`): groups DN
   `ou=groups,<base>`, membership attribute `member`, mode `READ_ONLY`, "preserve group inheritance".

Then it triggers two syncs (groups first, then users) and lists everyone:

```
alex.ldap      alex.ldap@freshmart.local    from LDAP
casey.cashier  casey.cashier@freshmart.local local
...
```

Because the LDAP group `cashiers` has the same name as the Keycloak group `cashiers`, the mapper *merges* them:
`jordan.ldap` lands in Keycloak group `cashiers` and receives role `cashier`. `alex.ldap` is in no LDAP group, so
they only have the default role `shopper` — and the inspectors check that Alex cannot open the register.

## Pros and cons

| | Federation (what we do) | Copy users into Keycloak by hand |
|-|-------------------------|----------------------------------|
| Passwords | stay in LDAP, checked live | duplicated; two places to change |
| New hire | appears on first login / next sync | someone must add them |
| Groups | mapped automatically | assigned by hand |
| Complexity | one more system to run | none |

Best practices: keep the LDAP bind user read-only; use `ldaps://` (TLS) in real life; schedule periodic syncs
(`Periodic full sync` in the admin console) so people who left LDAP are disabled in Keycloak too.

## Poke at it

```bash
# search the phone book directly (inside the pod)
kubectl -n identity exec deploy/openldap -- ldapsearch -x -H ldap://localhost -b "dc=freshmart,dc=local" -D "cn=admin,dc=freshmart,dc=local" -w "$LDAP_ADMIN_PASSWORD" "(uid=*)" uid mail

# ask Keycloak to sync again (after adding an LDAP user)
scripts/06-configure-realm.sh        # safe to re-run
```

Tutorial: [add an LDAP user](tutorials/tutorial-add-an-ldap-user.md).
