# reqling.af.codes

This orphan `gh-pages` branch *is* the published site; the app lives on `main`. GitHub Pages runs Jekyll on the branch root, which copies files without front matter verbatim, so add none. It drops names starting with `_` or `.`, and `_config.yml` keeps `og-image/`, `AGENTS.md` and `CLAUDE.md` off the site, so list any other unpublished root file in its `exclude`. Preview with `python3 -m http.server` from the root rather than opening the file.

Built per the global `static-site-rules` skill, as a sibling of the Alveary, Chromahora, Carouline and Roastier sites (their `gh-pages` branches). Carry shared layout, components and scripts across rather than letting them drift.

## Look

- Colors come from the app on `main`: `--accent` is `AccentColor` (`#743a8a` light, `#aa86c2` dark), the title gradients run through `AppIcon.icon`'s plum body, lavender wing and cream beak, and the glows wash a purple down from the top (the wing in light, `AccentColor` in dark) with the beak's cream to the right. Keep them in step with the app and the contrast ratios in the theme sheets' comments.
- The motif is the courier's dotted flight paths rising up the hero's sides to a packet each: an inline SVG in `index.html` and `og-image/og-image.html` (keep both copies equal), filled and stroked in `--trail`.
- Window screenshots are centered under their text, like Alveary's, since a window needs the full width. `#projects` and `#mcp` split their text beside a code frame instead, alternating sides; `#projects`' file tree mirrors the project layout in `main`'s `docs/projects.md`, and `#mcp`'s command mirrors Settings ▸ MCP's Claude Code setup.
- `scripts/platform-gate.js` greys out the download for visitors not on a Mac before first paint, keyed on `#release-link`; it is Alveary's `gh-pages` copy verbatim, so change the two together.
- `#protocols` tabs its GraphQL, gRPC, event stream, and WebSocket captures through `scripts/protocol-tabs.js`. Its markup ships every panel shown and the tablist hidden, so without JavaScript the captures stack under their names; keep a new protocol's panel id, tab, and caption together.
- `#details` is plain columns between hairlines, three to a row; keep the count a multiple of three so rows stay full. Alveary's `gh-pages` carries the same rules, so change the two together.

## Theming

`styles/index-light.css` and `styles/index-dark.css` hold the tokens and the glow; `styles/index-common.css` holds everything else. Both theme sheets ship media-scoped, as do the `theme-color` metas and every `<picture>` dark `<source>`, so the page follows the OS without JavaScript. `scripts/dark-mode.js` only applies a stored toggle override, and repeats each sheet's `--bg`, so change them together.

## Images

### Screenshots

`images/{request,graphql,grpc,events,websocket,scripts,batch}-{light,dark}.webp` are 1920x1248 captures of the main window from `main`'s screenshot mode, which seeds a fixed demo project (`ScreenshotDemoProject`), so the alt text describes that data. To regenerate:

1. On `main`, run `./scripts/screenshots.sh -b` on a Retina display with the Multicolor accent, or controls take the system accent instead of the app's purple. Each scene and theme takes focus while it's captured, so the window shows its active appearance. It writes 2400x1560 PNGs of the window alone, with transparent rounded corners, to `.build/screenshots/<scene>-<light|dark>.png`.
2. Downscale each by four fifths, which keeps both sides integral: `sips -z 1248 1920 <scene>-<theme>.png --out <tmp>.png`.
3. `cwebp -lossless -z 9 -alpha_q 100 <tmp>.png -o images/<scene>-<theme>.webp`. Every capture shares one size, repeated in `.screenshot`'s `aspect-ratio` and each `<img>`'s `width`/`height`.
4. Update the alt text if the demo data changed, and re-render the link preview if `request-dark.webp` did.

### Icons

- `images/app-icon-light.png` and `-dark.png` are `AppIcon.icon` renders at 256x256 in sRGB, with the plate and corner mask baked in: `"/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1` (`--rendition Dark` for dark), then `sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc"` and `sips -Z 256`.
- `favicon.png` is the light render at 96x96 in both themes, with `favicon.ico` (16, 32, 48) for old browsers; `apple-touch-icon.png` is it at 180x180, flattened onto white.
- The header logo loads from `https://af.codes/images/af.png` on `--logo-circle`, whose values match af.codes and the other siblings; change them together.

### Link preview

`images/og-image.png` is rendered by `og-image/render.sh` from `og-image/og-image.html`, which links the site's own common and dark sheets. Re-render it in the same change as the name, tagline, dark colors, flight paths, icon or `request-dark.webp`, then check `file images/og-image.png` reports 1200 x 630 RGB and view it.
