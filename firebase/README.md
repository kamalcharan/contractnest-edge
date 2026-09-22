# Firebase Storage configuration

Two files, both applied once per bucket, both **owner actions**.

Bucket: whatever `VITE_FIREBASE_STORAGE_BUCKET` holds
(today: `contractnest-driveapp.firebasestorage.app`).

---

## `cors.json` — apply this BEFORE testing the upload lab

### Why it is needed

The browser PUTs bytes **straight to Google Cloud Storage** using a signed URL
the API mints. That is a cross-origin request from your app's domain to
`storage.googleapis.com`, and a Firebase Storage bucket ships with **no CORS
configuration at all** — so the browser blocks the request before it is sent.

The old design never hit this because the Firebase **client SDK** talks to
endpoints that are already CORS-enabled. Uploading through a signed URL is what
makes the bucket's own CORS policy matter.

### What still works without it

Everything that uploads through our API rather than the browser:

- tenant logo (`POST /api/tenant-profile/logo`)
- integration QR (`POST /api/integrations/upload-qr`)

Those send multipart to our server and the server writes to storage. No
browser-to-GCS request, so no CORS involved. **Batch D works with or without
this file.**

### What needs it

The browser-direct path from batch C:

- `/settings/upload-lab`
- the service-evidence panel, once batch F moves it over

**Symptom if it is missing:** the upload bar reaches ~15% and stops, and the
browser console shows a CORS error on a `storage.googleapis.com` PUT — no
server error, nothing in the API log, nothing in Sentry. It reads like a code
bug and is not one.

### Apply

```bash
gcloud storage buckets update gs://contractnest-driveapp.firebasestorage.app \
  --cors-file=cors.json

# older toolchains:
gsutil cors set cors.json gs://contractnest-driveapp.firebasestorage.app
```

### Verify

```bash
gcloud storage buckets describe gs://contractnest-driveapp.firebasestorage.app \
  --format="default(cors_config)"
```

Then upload a photo at `/settings/upload-lab` — the bar should run past 15% to
"Uploaded".

### Editing the origins

`origin` must list every site that uploads. It matches the browser's `Origin`
header **exactly**: scheme, host and port, no wildcards, no trailing slash.
Add a line for any new domain or dev port; a missing entry fails as above.

`method` is deliberately narrow: `PUT` to upload, `GET`/`HEAD` to read a signed
URL back. No `POST` and no `DELETE` — the browser never deletes from storage,
the sweeper does, server-side.

---

## `storage.rules` — ⚠️ DO NOT DEPLOY YET

Blocked until **batch F**. Three surfaces still upload through the legacy
`/api/storage` path, which uses the Firebase client SDK with
`signInAnonymously()` and **is** governed by these rules: the service-evidence
panel, the `/settings/storage` pages, and the two old `FileUploader`
components. Deploying deny-all before those move would break them.

Existing files are unaffected whenever it does go out: every logo and QR image
already stored carries a `firebasestorage.googleapis.com` access token, and
those tokens authorise independently of rules.

```bash
firebase deploy --only storage
```

Verify after deploying:

- a client-SDK write fails from a test harness
- a client-SDK read of a `contracts/` object fails
- an API-minted signed URL still works
- a `tenants/` logo URL loads in an anonymous browser window
