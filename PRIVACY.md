# Waddle Privacy Policy

Waddle does not collect any data of any kind.

- The app connects to the network only to download a link you give it
  (Add → From a Link…) or a source you tap (Add → From Sources…; the
  Freedoom source the app comes with downloads Freedoom's own release from
  GitHub), when you ask. Only that link's server (and any server it
  redirects to) sees the request. It sees your IP address, as
  any server you connect to does, and the request's headers, which are
  fixed and say nothing about you or your device: `User-Agent: Waddle`
  (no version numbers), `Accept-Language: *` (no language preference),
  `Accept: */*`, `Accept-Encoding: gzip, deflate, br`,
  `Cache-Control: no-cache`, and the server's own name. No cookies,
  account or identifiers are sent or stored, nothing is cached, and the
  app keeps no history of the downloads. Sources you add are kept on
  your device only.
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
- WAD files you import, from Files, a link or a source, stay on your device.
  They are never uploaded or shared anywhere.

The App Store itself may collect standard install and crash metrics; those
are governed by [Apple's privacy policies](https://www.apple.com/legal/privacy/),
not ours.

Questions? Open an issue on this repository.
