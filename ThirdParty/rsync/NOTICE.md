# rsync 3.5.0

MusiCards Sync bundles rsync as a separate executable component at
`Contents/MacOS/rsync`.

- Project: rsync
- Version: 3.5.0
- License: GNU General Public License, version 3 (GPLv3)
- Official project: https://rsync.samba.org/
- Upstream attribution: Copyright (C) 1996-2026 by Andrew Tridgell, Wayne Davison, and others.

The complete upstream license text is included in [`COPYING`](COPYING).
The corresponding official source archive is preserved under
[`source/rsync-3.5.0.tar.gz`](source/rsync-3.5.0.tar.gz).

The executable is built from the rsync source distribution's bundled
third-party components:

- **popt** — bundled command-line parsing implementation. Its upstream license
  text is preserved verbatim in [`licenses/popt-COPYING`](licenses/popt-COPYING).
- **zlib** — bundled compression implementation. Its upstream license and
  notice text is preserved verbatim in [`licenses/zlib-LICENSE`](licenses/zlib-LICENSE).

These component notices retain their own license identities; they are not
described as GPLv3 solely because they are linked into rsync.
