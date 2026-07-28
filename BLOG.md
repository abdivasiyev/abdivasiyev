# Blog

Posts are Org files in `org/`. They are exported to HTML by Emacs itself —
`publish.el` drives `org-publish` with the standard `ox-html` exporter — during the
GitHub Pages deploy. The generated `_site/` directory is gitignored and never committed.

> The build assembles a complete site in `_site/`, and **only `_site/` is deployed**.
> Sources, tooling, editor config and notes stay in the repository and never reach the
> web. `_site/` is deleted and rewritten on every build, so nothing you put there by
> hand survives.

```
org/*.org   ->  _site/posts/*.html
assets/*    ->  _site/posts/assets/*
index.html  ->  _site/index.html     (listed in blog/root-files)
CNAME       ->  _site/CNAME          (listed in blog/root-files)
```

To ship another file from the repository root — `robots.txt`, `favicon.ico`, a
verification file — add its name to `blog/root-files` in `publish.el`. Nothing else at
the root is deployed.

**Add it to the workflow's `sparse-checkout` list too.** CI fetches only the paths the
build reads (`org/`, `assets/`, `publish.el`, `index.html`, `CNAME`), so a file listed
in `blog/root-files` but missing from that list never reaches the runner. The build
errors out in that case rather than deploying a site with a hole in it.

## Writing a post

Create `org/<slug>.org`. The filename becomes the URL: `org/my-post.org` is served
at `https://azizovich.uz/posts/my-post.html`.

```org
#+TITLE: My post
#+DATE: 2026-08-01
#+DESCRIPTION: Optional. Org inline markup works here.
#+KEYWORDS: golang, security

Your content here.

#+begin_src go
func main() {}
#+end_src
```

| Keyword | Required | Notes |
| --- | --- | --- |
| `#+TITLE:` | no | Defaults to the filename |
| `#+DATE:` | **yes** | `YYYY-MM-DD`; also sets the ordering (newest first) |
| `#+DESCRIPTION:` | no | Inline org markup (`~code~`, `*bold*`, links). Used for the post list, `<meta description>`, Open Graph, and RSS |
| `#+KEYWORDS:` | no | Comma-separated tags |
| `#+DRAFT: t` | no | Excludes the post from the build |

Commit the org file and push to `master` — the workflow builds and deploys it.

## Local preview

```sh
make serve     # build, then serve on http://localhost:4321
make build     # build only, into _site/
make clean     # remove _site/ and .packages/
```

`make serve` takes `PORT=8080` and `EMACS=/path/to/emacs` if you need them.

Without make:

```sh
emacs --batch --load publish.el --funcall blog/publish
python3 -m http.server 4321 --directory _site
```

Serve `_site/`, not the repository root — pages use absolute paths like
`/posts/assets/style.css`. Serving `_site/` also means what you see locally is exactly
what deploys, down to which files exist.

The first run downloads the packages in `blog/packages` from ELPA/MELPA into
`.packages/`; later runs reuse them and touch the network only when the list changes.
Set `BLOG_PACKAGE_DIR` to put them somewhere else — CI does this to keep them out of
the deploy artifact so they can be cached.

## What CI caches

A push installs nothing it already has:

- **Emacs** — the runner ships without it, so it comes from apt. The downloaded `.deb`
  files are cached, which skips the download; `dpkg` still runs so post-install scripts
  behave normally. Bump `-v1` in the cache key to force a refresh.
- **ELPA packages** — cached on the hash of `publish.el`. Editing `publish.el` for an
  unrelated reason still reuses the previous download via `restore-keys`; only a change
  to `blog/packages` causes a real re-download.

The package cache lives outside the working tree (`~/.cache/blog-emacs-packages`) via
`BLOG_PACKAGE_DIR`, which also keeps it well clear of `_site/` and therefore out of the
deploy artifact.

## Syntax highlighting

Source blocks are fontified at export time by `htmlize`, using the same major modes
Emacs uses in a live buffer — so published code matches what you see while writing, and
pages need no JavaScript.

This means **a language needs its major mode installed to be highlighted**. Emacs ships
modes for elisp, sh, C, Python, SQL and others; anything else has to be added to
`blog/packages` in `publish.el` — `go-mode` and `haskell-mode` are already there.

A language with no mode still exports fine, just uncoloured, and nothing errors — which
is easy to miss. The build therefore scans every `#+begin_src` and prints a warning
naming any language it cannot colour:

```
WARNING: no major mode for: rust — those blocks publish uncoloured.
         Add the mode to ‘blog/packages’ in publish.el.
```

Batch Emacs has no display, so every face would normally resolve to `unspecified` and
htmlize would emit grey code. `blog/set-code-faces` assigns explicit colours (a
GitHub-light palette) and resets weight/slant, which also keeps output identical across
Emacs versions and themes.

## What gets generated

- `_site/index.html` — the CV page, copied from the repository root
- `_site/CNAME` — custom domain, copied from the repository root
- `_site/posts/index.html` — post list, built by `blog/write-index`
- `_site/posts/<slug>.html` — one page per post, via `org-html-publish-to-html`
- `_site/posts/feed.xml` — RSS feed, built by `blog/write-rss`
- `_site/posts/assets/` — static files copied from `assets/` by `org-publish-attachment`

That is the complete deploy artifact — six files today.

The index and feed are written directly rather than through `:auto-sitemap`, which
cannot easily produce the per-entry title/date/description layout.

## Notes

- Babel is disabled during export (`org-export-use-babel nil`), so publishing a post
  can never execute code as a side effect.
- Post titles, dates and tags are rendered by `blog/post-preamble` rather than by
  ox-html, so they sit together above the body. Hence `:with-title nil` in the project
  definition.
- `ox-html` copies `#+DESCRIPTION:` into the description meta tag verbatim;
  `blog/html-meta-filter` replaces it with the plain-text rendering and adds the Open
  Graph, Twitter and canonical tags that ox-html does not emit.
