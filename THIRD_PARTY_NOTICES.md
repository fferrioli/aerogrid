# Third-party notices

The components below retain their original licenses. Vendoring a source snapshot does not change its authorship or terms. [UPSTREAM.md](UPSTREAM.md) records the pinned revisions and AeroGrid modifications.

| Component | Use | Notice |
|---|---|---|
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | Bundled, modified window engine | [MIT license](vendor/AeroSpace/LICENSE.txt), [additional notices](vendor/AeroSpace/legal/) |
| [SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace) | Adapted event-tap / NSTouch input | [MIT license](vendor/SwipeAeroSpace/LICENSE) |
| [TOMLKit](https://github.com/python-poetry/tomlkit) | Configuration editing with formatting preserved | [MIT license](vendor/python/LICENSE-tomlkit) |

AeroSpace’s Swift package also resolves its own pinned dependencies. Their notices are retained in its legal directory; the resolved versions are in `vendor/AeroSpace/Package.resolved`.

The animated demo uses depictions of macOS and Apple application icons. Those names and artwork belong to their respective owners and are not covered by a new AeroGrid license. AeroGrid is an independent project and is not affiliated with Apple or the upstream projects.

No project-wide license has been selected for original AeroGrid code. Public source availability alone does not grant additional reuse rights.
