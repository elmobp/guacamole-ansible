# ISM mapping — methodology and maintenance

`docs/LLD-RHEL-IRAP.md` §12 maps this build to Australian **ISM** controls. This document explains
how that mapping was produced, why you can defend it in an assessment, and how to refresh it when
a new ISM is published.

> **The currently published ISM at cyber.gov.au is authoritative.** Control numbers, wording and
> applicability change between quarterly releases. Everything here describes a *point-in-time*
> mapping against a stored dataset — see the retrieval date below.

---

## 1. The dataset

| | |
|---|---|
| Source | `https://raw.githubusercontent.com/elmobp/ism-quiz/main/controls.json` |
| Nature of source | **third-party community extract of the ISM — not an ACSC publication** |
| Retrieved | **2026-09-11** |
| Re-verified | 2026-09-11 — re-downloaded, byte-identical, SHA-256 unchanged |
| Stored at | `docs/data/ism-controls.json` (byte-for-byte as retrieved) |
| Provenance | `docs/data/ism-controls.meta.json` — URL, date, SHA-256, size, counts |
| SHA-256 | `f88b1222148e363ddf7e1c0f53258c6ab6a18fdc5bc61bc4d29fbc818481572e` |
| Control ids as published | 871 |
| Control ids after normalisation | **907** |

The file is a JSON object of `control id -> control statement`, with some HTML markup embedded in
the statements. JSON has no comment syntax, so the provenance header lives in the sidecar
`.meta.json` rather than in the dataset — keeping the dataset byte-identical to the source means
the SHA-256 above can be re-verified against the upstream URL at any time.

### Why this dataset, and what it is not

Be blunt about this, because an assessor will ask.

- The dataset is a **community extract**, mirrored on GitHub. It is *not* the ACSC's own
  machine-readable ISM release, and neither ACSC nor ASD published, endorsed or maintains it.
- It carries **no ISM release label**. The control ids and statements are consistent with a recent
  ISM, but the file does not state *which* quarterly release it was taken from, so this mapping
  cannot claim to be "the September-2025 ISM" or any other specific edition.
- It was chosen because it is the shape this generator needs (`{"ism-NNNN": "statement"}`), is
  stable at a fixed URL, and can be hash-pinned so the mapping is reproducible. The official
  downloads at cyber.gov.au (XLSX / OSCAL) are the better source and were not reachable
  non-interactively from this environment.

**Consequences you must accept before relying on §12:**

1. Re-check every cited control id and statement against the currently published ISM before an
   assessment. §5 is the procedure; step 4 (diff the *statements*, not just the ids) is the one
   that matters.
2. Treat the abridged statements in the §12 table as *navigation aids*, not as quotations of the
   ISM. Each row links to the control id so the authoritative text can be looked up.
3. The **status and the evidence note** in each row are the durable part of this work — they were
   derived from this repository's code and are unaffected by which ISM edition you check them
   against. Only the control numbering is at risk of drift.

Swapping in the official release later is a data change only: replace `ism-controls.json`, update
the sidecar, re-run the generator, and resolve whatever ids it reports as missing.

**Normalisation.** 36 of the published values carry the *next* control appended after a stray
markdown table separator, for example:

```
"ism-0427": "... the session lock. | | [ism-0430](/control/ism-0430) | Access to systems, ..."
```

`scripts/ism_map.py` splits those back out at load time (the raw file is never modified), which is
why the usable control count is 907 rather than 871. Several genuinely important controls —
`ism-0408` (logon banner), `ism-0430` (access removal), `ism-0485` (SSH public-key auth),
`ism-0585` (event record contents), `ism-1564` (POA&M) — exist *only* inside a merged value, and a
naive load would silently lose them.

---

## 2. How the mapping was derived

The instruction that shaped this work: **do not regex the controls — every cited control must be
100% relevant to what the design actually claims.** The process was:

1. **Read the implementation first, not the controls.** Every file in `roles/{common,database,
   guacd,guacamole_client,nginx_proxy,guac_extensions,connections,backup,hardening}` — tasks,
   defaults, templates and systemd units — plus `site.yml`, `group_vars/all.yml` and the `docs/`
   set, was read to build a factual inventory of what the build configures.
2. **Read all 907 control statements.** Not searched — read, in full, grouped by ISM theme, so
   that exclusions are decisions rather than gaps in a keyword list.
3. **Match statement to evidence, one at a time.** A control earns a row only when its *statement*
   describes something the build genuinely does, genuinely does not do, or directly enables.
4. **Write the evidence into the note.** Each note names a variable, a file, a unit directive or a
   verified behaviour. The rule used while authoring: *if you cannot name the evidence, the row
   does not belong in the table.*
5. **Grade honestly, including against the previous draft.** Several rows in the earlier
   hand-curated table were downgraded or corrected during this pass (see §4).
6. **Record the exclusions.** §12.1 of the LLD lists the control families that were reviewed and
   deliberately excluded, with the artefact that owns each one.

### Status vocabulary

| Status | Meaning |
|---|---|
| ✅ `implemented` | Configured by default, or by a documented toggle. |
| 🟡 `partial` | Implemented in part, or needs a variable set / an operational step. The note says **which part is missing**. |
| 📋 `customer` | The design supports or enables it; an organisational process or another system must operate it. |
| ❌ `not-addressed` | A real gap. It appears in the POA&M seed (§12.2). |

### Current result

**165 controls mapped** — ✅ 44 · 🟡 99 · 📋 16 · ❌ 6.

The high proportion of 🟡 is deliberate and is the point of the exercise: a component build almost
never *fully* discharges an ISM control on its own, and a table of green ticks would be the less
useful document. Each 🟡 states the residual work.

---

## 3. How the table is generated

The §12 table is **generated, not hand-edited**:

```
docs/data/ism-controls.json   (verbatim dataset)
docs/data/ism-mapping.yml     (hand-authored: control id -> status / reference / note)
          |
          v
scripts/ism_map.py            (stdlib only — no PyYAML, no network)
          |
          v
docs/LLD-RHEL-IRAP.md  §12    (between the BEGIN/END ISM TABLE markers)
```

```bash
python3 scripts/ism_map.py           # rewrite the table in place
python3 scripts/ism_map.py --check   # exit 1 if the LLD is out of date (CI-friendly)
python3 scripts/ism_map.py --stats   # status breakdown only
```

The script validates before it writes and refuses to generate if:

- a mapped control id does not exist in the dataset (a typo, or a control retired by a new ISM);
- a row is missing `theme`, `status`, `ref` or `note`;
- a status, theme or design reference is unknown;
- the LLD is missing its `<!-- BEGIN/END ISM TABLE -->` markers;
- a ❌ `not-addressed` row has **no corresponding action in §12.2**, or §12.2 cites a control that
  has no row in the table. §12.2 is hand-written prose *outside* the generated markers, so this is
  the guard that stops the POA&M seed drifting away from the mapping — an honest gap that never
  reaches the POA&M is the failure mode this whole document exists to prevent.

### Adding or changing a row

Edit `docs/data/ism-mapping.yml` only, then re-run the script:

```yaml
  ism-1272:
    theme: "07-database"           # must exist under themes:
    status: implemented            # implemented | partial | customer | not-addressed
    ref: db                        # must exist under refs: — becomes a link into the LLD
    note: "The default local deployment reaches MariaDB over the UNIX socket / 127.0.0.1 only …"
```

`refs:` entries are `"link text|#anchor"` and point at an explicit `<a id="…"></a>` anchor in the
LLD, so every row is clickable through to the design section that substantiates it.

`ism-mapping.yml` is deliberately a restricted YAML subset (nested mappings of scalars, two-space
indent, quoted strings) so `scripts/ism_map.py` can parse it with the standard library alone. It
is still valid YAML and passes `yamllint`.

---

## 4. Corrections made during this pass

Recorded because an assessor will ask why the numbers moved:

| Control | Was | Now | Why |
|---|---|---|---|
| `ism-0467` | ✅/🟡 against FIPS mode | **removed** (out of scope, §12.1) | 0467 requires ASD-approved **High Assurance Cryptographic Equipment** for SECRET/TOP SECRET. FIPS 140 mode is not HACE. The applicable control is `ism-0465` (evaluated cryptography for OFFICIAL: Sensitive / PROTECTED). |
| `ism-1416` | ✅ | 🟡 | firewalld restricts **inbound** only; the control also requires outbound restriction, which this build does not configure. |
| `ism-1327` | ✅ | 🟡 | Keys have logical access control (0640, root-owned) but are not passphrase-encrypted and no HSM is used — the control asks for encryption too. |
| `ism-1765` | ✅ | 🟡 | The proxy certificate is RSA-3072, but the optional internal guacd certificate is generated at **rsa:2048** in `roles/hardening/tasks/app_layer.yml`. |
| `ism-0304` | ✅ | 🟡 | The build prunes *superseded versions*; the control is about removing software that has reached vendor end-of-support, which remains an operational judgement. |
| `ism-1682` | ❌ | 🟡 | Upgraded: `guac_ssl_auth_enabled` (X.509 client certificate / smart card) and OIDC/SAML to a WebAuthn IdP are genuine phishing-resistant paths added since the previous draft. |
| `ism-1403` | 🟡 | ❌ | Verified: `pam_faillock` is **not** configured by `roles/hardening` (auditd only *watches* `/var/run/faillock`) and Guacamole core has no lockout. |

New honest gaps surfaced by reading the code rather than the docs: `ism-1791`/`ism-1792` (Apache
and Maven artefacts are downloaded over HTTPS but their signatures/checksums are never verified,
and EPEL/RPM Fusion release RPMs install with `disable_gpg_check: true`), `ism-1245` (the guacd
build toolchain and source tree remain on a VM build), `ism-1537` (no MariaDB audit/general log),
`ism-0408` (the SSH `Banner` directive points at `/etc/issue.net`, but no banner text is
deployed), and `ism-0418` (target credentials are, by design, stored recoverable on the broker).

---

## 5. Refreshing against a newer ISM

1. **Re-retrieve the dataset** (or export the current ISM yourself in the same
   `{"ism-NNNN": "statement"}` shape):

   ```bash
   python3 - <<'EOF'
   import urllib.request, hashlib
   url = "https://raw.githubusercontent.com/elmobp/ism-quiz/main/controls.json"
   raw = urllib.request.urlopen(url, timeout=60).read()
   open("docs/data/ism-controls.json", "wb").write(raw)
   print(len(raw), hashlib.sha256(raw).hexdigest())
   EOF
   ```

2. **Update `docs/data/ism-controls.meta.json`** — `retrieved_utc`, `sha256`, `bytes` and the two
   control counts.

3. **Re-run the generator.** It fails loudly on any control id that no longer exists, which is
   exactly the signal that a control was retired or renumbered:

   ```bash
   python3 scripts/ism_map.py
   ```

4. **Diff the statements, not just the ids.** A control can keep its number and change its
   meaning. Compare the rendered table against the previous commit:

   ```bash
   git diff docs/LLD-RHEL-IRAP.md
   ```

   Any row whose *statement* moved needs its status and note re-validated against the code.

5. **Re-read the exclusions in §12.1** — a new ISM release can add a family that is now in scope.

6. **Update the retrieval date in the LLD header and in §12**, and refresh the status breakdown
   (`python3 scripts/ism_map.py --stats`).

### Suggested CI gate

```yaml
- name: ISM mapping is current
  run: python3 scripts/ism_map.py --check
```

This keeps the generated table and the mapping file from drifting apart — the table can only
change by changing `ism-mapping.yml`.

---

## 6. What this mapping is not

- **Not an ISM system security plan.** It is one component's contribution to one.
- **Not a security assessment.** Statuses are the design author's assertions; an IRAP assessor
  tests them.
- **Not classification-aware.** Several controls are tiered by classification (for example the
  passphrase-length and ECDH-curve controls). Rows reflect the OFFICIAL: Sensitive / PROTECTED
  reading — re-check every row if the system is SECRET or above, and note that the entire High
  Assurance Cryptographic Equipment family is excluded in §12.1.
- **Not a substitute for the CIS benchmark pass.** `roles/hardening` is CIS-*aligned*;
  `roles/cis` delivers full CIS L2 coverage plus the OpenSCAP gate. The §12 rows are anchored to
  what `roles/hardening` verifiably does today so the table does not depend on `roles/cis`.
