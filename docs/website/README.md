# Lingyue website (canonical source)

Static landing + legal pages for the App Store Connect URL fields. Deployed to GitHub Pages from the `gh-pages` branch of this same repo.

## Files

- `index.html` — landing page (Support URL + Marketing URL target)
- `privacy.html` — privacy policy (Privacy Policy URL target)
- `complaint.html` — 投诉与版权 (DMCA-style takedown)
- `disclaimer.html` — 免责声明 (limitation of liability)
- `lingyue-sources.json` — source bundle used by the in-app guide's one-tap import
- `screenshots/` — three iPhone captures used in the index hero

## Live URLs

- https://cynthiacui.github.io/Lingyue-Reader/
- https://cynthiacui.github.io/Lingyue-Reader/privacy.html
- https://cynthiacui.github.io/Lingyue-Reader/complaint.html
- https://cynthiacui.github.io/Lingyue-Reader/disclaimer.html
- https://cynthiacui.github.io/Lingyue-Reader/lingyue-sources.json

## Updating the live site

Don't edit `gh-pages` directly. This folder on `main` is the source of truth. Workflow:

```bash
# 1. Edit files here in docs/website/ on main, commit normally
# 2. Sync to gh-pages via worktree (no branch-switch needed)
cd /Users/xuanrrr/Documents/Lingyue
git worktree add ../lingyue-gh-pages gh-pages
cd ../lingyue-gh-pages
cp ../Lingyue/docs/website/*.html .
cp ../Lingyue/docs/website/lingyue-sources.json .
cp -r ../Lingyue/docs/website/screenshots .
git add -A && git commit -m "Update site" && git push origin gh-pages
cd ../Lingyue
git worktree remove ../lingyue-gh-pages
```

GitHub Pages rebuilds in ~30–60 seconds after push.

## App Store Connect mappings

| Field | URL |
|---|---|
| Support URL | `https://cynthiacui.github.io/Lingyue-Reader/` |
| Marketing URL | `https://cynthiacui.github.io/Lingyue-Reader/` (or blank) |
| Privacy Policy URL | `https://cynthiacui.github.io/Lingyue-Reader/privacy.html` |
