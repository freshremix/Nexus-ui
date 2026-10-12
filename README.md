# NEXUS — cPanel first-run setup prototype

## What's included
- Premium dark English dashboard.
- First visit to the subdomain opens a setup wizard; no `PANEL_PASSWORD` environment variable is required.
- The administrator chooses a password during setup. Only a salted scrypt hash is stored.
- NEXUS generates a random private URL path (24 random bytes, URL-safe encoding) and saves it in the data file.
- The password and private path survive restarts/redeploys as long as the data file and configured data directory are preserved.
- Create, enable/disable, update quota, reset usage, and delete user records. The WS relay checks account status, expiry and quota.
- Generates VLESS WebSocket (`/ws`) links using the current subdomain as the default connection address, TLS SNI, and WebSocket Host. The connection address can be overridden in settings if needed.
- Stores records in JSON; no MySQL required.

## cPanel deployment (GUI only)
1. In **Setup Node.js App / Node.js App Deploy**, create an app using Node.js 18+ (Node 20+ recommended).
2. Set the application root to a private folder such as `nexus-app`, and assign your subdomain, e.g. `https://m.example.com/`.
3. Upload and extract this ZIP into the application root. `index.js`, `package.json`, and `public/` must be directly inside the root.
4. Set the startup file to `index.js`.
5. Recommended: set `DATA_DIR` to an absolute writable folder outside `public_html`, for example `/home/CPANEL_USERNAME/nexus-data`. Create that folder in File Manager first. Replace `CPANEL_USERNAME` with your real cPanel account username. If you omit `DATA_DIR`, the app uses `<application-root>/data`.
6. The connection address defaults to the subdomain used to open NEXUS; the same domain is used for TLS SNI and WebSocket Host. Port defaults to `443`. You can override the connection address in settings if your deployment requires a different hostname or IP.
7. Click **Run NPM Install** and restart the app.
8. Open the subdomain root over HTTPS. Create an administrator password; NEXUS will show the generated private URL once. Save it in a password manager.
9. Use the generated private URL to access the login page. The root subdomain will not reveal or redirect to the private URL after setup. If you lose the URL, restore it from your backup; it is intentionally not displayed again.

## Important security / persistence notes
- Use HTTPS. The secret URL is an additional obscurity layer, not a replacement for the admin password.
- Back up the JSON data file. If the data file or `DATA_DIR` is deleted, replaced, or not preserved by the hosting provider, the password and private URL cannot be recovered from this app.
- Keep `DATA_DIR` outside public web folders and make sure Node.js can write to it.
- The app's in-memory sessions are cleared on restart, so you will need to sign in again; the saved password and private URL remain unchanged.
- This build does not run Xray Core. It implements a basic VLESS-over-WebSocket TCP relay in Node.js and counts bytes at that relay. This is not yet verified on your cPanel host, so do not assume the endpoint is reachable until a client connection succeeds.
- cPanel shared hosting may prohibit custom binaries and persistent background processes. This app cannot bypass hosting restrictions.


## WebSocket backend
- This build implements VLESS over WebSocket at `/ws`.
- Set the server IP and the TLS domain in panel settings. The IP is used as the connection address; the domain is used for TLS SNI and the WebSocket Host header. Use port `443` when HTTPS/TLS is terminated by the hosting provider.
- cPanel must forward WebSocket upgrades to the Node.js process and allow outbound TCP sockets. If the host blocks either, this cannot be fixed only in the app.
- Traffic counters are based on bytes observed by the Node.js relay. Verify with a small test account first; accounting is persisted in short batches, so a forced kill may lose the last moment of counters.
- This is a basic implementation, not a hardened multi-tenant proxy product. Keep Node.js dependencies updated and do not expose management data publicly.
