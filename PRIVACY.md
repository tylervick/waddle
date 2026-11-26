# Waddle Privacy Policy

Waddle does not collect any data of any kind.

- The app connects to the network only to download a file, when you ask:
  a link you give it (Add → From a Link…, or a link you drop on the
  library), or Freedoom, when you tap Get on the Get Freedoom tile. That
  tile is on the shelf only while your library has no Freedoom, shows the
  download's size before you tap, and downloads one file from github.com:
  the Freedoom 0.13.0 release
  (`https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip`),
  which the app checks against a fingerprint it ships with. Showing the
  tile makes no connection. Only that link's server (and any server it
  redirects to; GitHub sends a release download on to its own download
  server) sees the request. It sees your IP address, as
  any server you connect to does, and the request's headers, which are
  fixed and say nothing about you or your device: `User-Agent: Waddle`
  (no version numbers), `Accept-Language: *` (no language preference),
  `Accept: */*`, `Accept-Encoding: gzip, deflate, br`,
  `Cache-Control: no-cache`, and the server's own name. No cookies,
  account or identifiers are sent or stored, nothing is cached, and the
  app keeps no history of the links. The Get Freedoom download sends the
  same request, with the same headers, and nothing else.
  Otherwise the app makes no network connections on its own. Beyond that
  download, the only data this app ever sends anywhere is what you choose
  to send from the About screen. The
  diagnostics file you export or attach to a feedback email goes only where
  you send it, when you send it. The app version, iOS version and device
  model reach GitHub when you tap Open GitHub to start a bug report, and
  become a public issue only if you submit it there.
- There are no analytics services, no tracking, and no third-party SDKs
  that phone home. The app keeps simple usage counts on your device, which
  leave it only inside a diagnostics file you choose to send.
- WAD files you import, from Files or from a link, and a Freedoom you
  download, stay on your device.
  They are never uploaded or shared anywhere.

The App Store itself may collect standard install and crash metrics; those
are governed by [Apple's privacy policies](https://www.apple.com/legal/privacy/),
not ours.

Questions? Open an issue on this repository.
