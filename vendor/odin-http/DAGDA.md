# Vendored Odin HTTP

Source: https://github.com/laytan/odin-http

Revision: `fac113fbd828aad3d71479a534b5de4358b6a07b`.

This directory includes the upstream root server package and its LICENSE and README. The client, examples, old I/O implementation, and binary OpenSSL libraries are not included. The server uses Odin's core nonblocking I/O package.

Upstream describes this implementation as a proof of concept, not production-ready. Dagda's runtime prototype must establish compatibility and ownership behavior before it can serve as a framework foundation.

Local changes are recorded in `../../patches/odin-http.patch`, relative to the
upstream revision above:

- Update the JSON writer call for the pinned Odin compiler.
- Add per-event-loop connection limits and request-read/response-write timeouts.
- Stop accepting connections when shutdown starts; cancel pending scanner reads
  before connection storage is freed.
- Reduce the initial connection arena commitment to 64 KiB.
- Reject duplicate Content-Length and combined Transfer-Encoding/Content-Length.
- Validate header field-name tokens and reject folded lines and disallowed control
  bytes in field values.

Zero-valued new options retain upstream's unbounded defaults. Dagda explicitly
sets limits and uses one HTTP event loop, no request bodies, and connection-close
responses. The read deadline starts at accept and is not a keep-alive policy.
These patches are targeted prototype fixes, not a complete HTTP security audit.
