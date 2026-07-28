;;; publish.el --- Build azizovich.uz/posts from org files -*- lexical-binding: t; -*-

;; Usage:
;;
;;   emacs --batch --load publish.el --funcall blog/publish
;;
;; Reads org/*.org and writes posts/ — one HTML page per post, plus a
;; hand-built index and RSS feed.  Source blocks are fontified at export time
;; by htmlize, using the same major modes Emacs uses in a live buffer.

(require 'cl-lib)

;;; Packages ------------------------------------------------------------------
;;
;; htmlize does the src-block fontification.  The major modes are here only so
;; that htmlize has something to fontify with: Emacs cannot colorise a language
;; it has no mode for.  Add a mode here when you start writing about a new
;; language.

(defconst blog/root
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this file.")

(defconst blog/packages '(htmlize go-mode haskell-mode)
  "Packages needed to build the site.")

(defun blog/install-packages ()
  "Install `blog/packages' into a project-local directory."
  (require 'package)
  ;; BLOG_PACKAGE_DIR lets CI keep packages outside the working tree, so they
  ;; survive the step that strips build files out of the deploy artifact and
  ;; can actually be cached between runs.
  (setq package-user-dir (or (getenv "BLOG_PACKAGE_DIR")
                             (expand-file-name ".packages" blog/root))
        package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("melpa" . "https://melpa.org/packages/")))
  (package-initialize)
  (unless (cl-every #'package-installed-p blog/packages)
    (package-refresh-contents)
    (dolist (pkg blog/packages)
      (unless (package-installed-p pkg)
        (package-install pkg)))))

;;; Site metadata -------------------------------------------------------------

(defconst blog/site-url "https://azizovich.uz")
(defconst blog/author "Asliddin Abdivasiyev")
(defconst blog/description
  "Notes on software engineering and security by Asliddin Abdivasiyev.")

;; The build assembles a complete site in _site/ and nothing else is deployed,
;; so the repository can hold sources, tooling and notes without any of it
;; reaching the web.  _site/ is wiped and rewritten on every build.
;;
;;   org/*.org      ->  _site/posts/*.html
;;   assets/*       ->  _site/posts/assets/*
;;   blog/root-files ->  _site/
(defconst blog/source-dir (expand-file-name "org" blog/root))
(defconst blog/site-dir (expand-file-name "_site" blog/root))
(defconst blog/output-dir (expand-file-name "posts" blog/site-dir))

(defconst blog/root-files
  '("index.html"   ; the CV page
    "googled54f822cf550c551.html" ;; google search verification
    "CNAME")       ; custom domain for GitHub Pages
  "Files copied verbatim from the repository root into the published site.
Anything not listed here is never deployed.")

;;; Small helpers -------------------------------------------------------------

(defun blog/escape (string)
  "Escape STRING for use in HTML/XML text and attributes."
  (let ((s (or string "")))
    (dolist (pair '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;")
                    ("\"" . "&quot;") ("'" . "&#39;")))
      (setq s (replace-regexp-in-string (regexp-quote (car pair)) (cdr pair) s t t)))
    s))

(defun blog/unescape (string)
  "Inverse of `blog/escape'.  `&amp;' is decoded last, so an escaped
entity in the source is not decoded twice."
  (let ((s (or string "")))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&#39;" . "'") ("&amp;" . "&")))
      (setq s (replace-regexp-in-string (car pair) (cdr pair) s t t)))
    s))

(defun blog/strip-tags (html)
  "Flatten HTML to plain text, for places that cannot hold markup."
  (string-trim (blog/unescape (replace-regexp-in-string "<[^>]*>" "" (or html "")))))

(defun blog/inline-html (org)
  "Export ORG as inline HTML, without the wrapping paragraph."
  (if (or (null org) (string-empty-p (string-trim org)))
      ""
    (let ((html (string-trim (org-export-string-as org 'html t '(:with-toc nil)))))
      ;; org-export-string-as always wraps a lone line in <p>...</p>
      (if (string-match "\\`<p>\\(\\(?:.\\|\n\\)*\\)</p>\\'" html)
          (string-trim (match-string 1 html))
        html))))

(defun blog/file-keyword (file keyword)
  "Return the value of the #+KEYWORD: line in FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)$" keyword) nil t)
      (let ((value (string-trim (match-string 1))))
        (unless (string-empty-p value) value)))))

(defun blog/parse-date (string)
  "Parse a YYYY-MM-DD date STRING into an Emacs time value."
  (let ((parsed (parse-time-string (concat (string-trim string) " 00:00:00 +0000"))))
    (encode-time (decoded-time-set-defaults parsed))))

(defun blog/format-date (time)
  "Format TIME as e.g. `Jul 28, 2026'."
  (format-time-string "%b %-d, %Y" time t))

;;; Post collection -----------------------------------------------------------
;;
;; Metadata is read straight off the #+KEYWORD: lines rather than through a
;; full org parse — it is faster and keeps the index/feed independent of the
;; export machinery.

(cl-defstruct blog/post slug title time date-html description-html description-text tags)

(defun blog/read-post (file)
  "Build a `blog/post' from FILE, or return nil if it is a draft."
  (unless (equal (blog/file-keyword file "DRAFT") "t")
    (let* ((date (or (blog/file-keyword file "DATE")
                     (error "%s: missing #+DATE:" (file-name-nondirectory file))))
           (time (blog/parse-date date))
           (description (blog/inline-html (blog/file-keyword file "DESCRIPTION")))
           (keywords (blog/file-keyword file "KEYWORDS")))
      (make-blog/post
       :slug (file-name-base file)
       :title (or (blog/file-keyword file "TITLE") (file-name-base file))
       :time time
       :date-html (blog/format-date time)
       :description-html description
       :description-text (blog/strip-tags description)
       :tags (when keywords
               (seq-remove #'string-empty-p
                           (mapcar #'string-trim (split-string keywords ","))))))))

(defun blog/posts ()
  "All published posts, newest first."
  (sort (delq nil (mapcar #'blog/read-post
                          (directory-files blog/source-dir t "\\.org\\'")))
        (lambda (a b) (time-less-p (blog/post-time b) (blog/post-time a)))))

;;; Shared page chrome --------------------------------------------------------

(defconst blog/html-head
  (concat
   "<link rel=\"stylesheet\""
   " href=\"https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/css/bootstrap.min.css\""
   " integrity=\"sha384-Gn5384xqQ1aoWXA+058RXPxPg6fy4IWvTNh0E263XmFcJlSAwiGgFAW/dAiS6JXm\""
   " crossorigin=\"anonymous\"/>\n"
   "<link rel=\"stylesheet\" href=\"/posts/assets/style.css\"/>\n"
   (format "<link rel=\"alternate\" type=\"application/rss+xml\" title=\"%s — Posts\" href=\"%s/posts/feed.xml\"/>"
           (blog/escape blog/author) blog/site-url))
  "Markup injected into <head> of every generated page.")

(defconst blog/nav
  (format "<div class=\"site-nav\">
<h5><a class=\"site-name\" href=\"/\">%s</a></h5>
<div><a href=\"/\">CV</a>&nbsp;&middot;&nbsp;<a href=\"/posts/\">Posts</a></div>
</div>
<hr/>"
          (blog/escape blog/author))
  "Header shared by the index and every post page.")

(defun blog/meta-line (date tags)
  "Render the DATE · TAGS line shown under a post title."
  (format "<div class=\"post-meta\"><small>%s%s</small></div>"
          (blog/escape date)
          (if tags
              (concat " &middot; " (mapconcat #'blog/escape tags ", "))
            "")))

;;; Post pages ----------------------------------------------------------------

(defun blog/post-preamble (info)
  "Header for a post page: site nav, then the post title and metadata.
Rendered here rather than by ox-html so the title, date and tags sit
together above the body."
  (let* ((title (org-export-data (plist-get info :title) info))
         (date (blog/format-date
                (blog/parse-date (org-export-data (plist-get info :date) info))))
         (keywords (org-export-data (or (plist-get info :keywords) "") info))
         (tags (seq-remove #'string-empty-p
                           (mapcar #'string-trim (split-string keywords ",")))))
    (concat blog/nav
            (format "<h5 class=\"post-title\">%s</h5>" title)
            (blog/meta-line date tags))))

(defconst blog/post-postamble
  "<hr/>\n<div><a href=\"/posts/\">&larr; All posts</a></div>"
  "Footer for a post page.")

;;; Index page ----------------------------------------------------------------

(defun blog/index-entry (post)
  (format "<div class=\"post-list-item\">
<h6><a href=\"/posts/%s.html\">%s</a></h6>
%s
<div>%s</div>
</div>"
          (blog/post-slug post)
          (blog/escape (blog/post-title post))
          (blog/meta-line (blog/post-date-html post) (blog/post-tags post))
          (blog/post-description-html post)))

(defun blog/write-index (posts)
  "Write the post list to blog/index.html."
  (let ((html
         (format "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\"/>
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"/>
<meta name=\"description\" content=\"%s\"/>
<meta name=\"author\" content=\"%s\"/>
<link rel=\"canonical\" href=\"%s/posts/\"/>
%s
<title>Posts — %s</title>
</head>
<body>
<div id=\"preamble\" class=\"status\">
%s
</div>
<div id=\"content\" class=\"content\">
<div class=\"site-nav\">
<h5>Posts</h5>
<div><small><a href=\"/posts/feed.xml\">RSS</a></small></div>
</div>
<div class=\"mt-3\">
%s
</div>
</div>
</body>
</html>
"
                 (blog/escape blog/description)
                 (blog/escape blog/author)
                 blog/site-url
                 blog/html-head
                 (blog/escape blog/author)
                 blog/nav
                 (if posts
                     (mapconcat #'blog/index-entry posts "\n")
                   "<div class=\"post-meta\">No posts yet.</div>"))))
    (with-temp-file (expand-file-name "index.html" blog/output-dir)
      (insert html))))

;;; RSS -----------------------------------------------------------------------

(defun blog/rss-item (post)
  (let ((url (format "%s/posts/%s.html" blog/site-url (blog/post-slug post))))
    (format "    <item>
      <title>%s</title>
      <link>%s</link>
      <guid isPermaLink=\"true\">%s</guid>
      <pubDate>%s</pubDate>
      <description>%s</description>
    </item>"
            (blog/escape (blog/post-title post))
            url url
            (format-time-string "%a, %d %b %Y %H:%M:%S GMT" (blog/post-time post) t)
            ;; RSS descriptions carry no markup here, so the plain-text form.
            (blog/escape (blog/post-description-text post)))))

(defun blog/write-rss (posts)
  "Write an RSS 2.0 feed to blog/feed.xml."
  (with-temp-file (expand-file-name "feed.xml" blog/output-dir)
    (insert (format "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">
  <channel>
    <title>%s — Posts</title>
    <link>%s/posts/</link>
    <description>%s</description>
    <language>en</language>
    <atom:link href=\"%s/posts/feed.xml\" rel=\"self\" type=\"application/rss+xml\"/>
%s
  </channel>
</rss>
"
                    (blog/escape blog/author)
                    blog/site-url
                    (blog/escape blog/description)
                    blog/site-url
                    (mapconcat #'blog/rss-item posts "\n")))))

;;; Source language check -----------------------------------------------------

(defun blog/check-src-languages ()
  "Warn about src-block languages that have no major mode installed.

htmlize colourises code by running the language's major mode and reading
the faces it applies, so a language Emacs has no mode for publishes as
plain text.  Nothing errors in that case, which makes it easy to miss —
hence this warning.  The fix is to add the mode to `blog/packages'."
  (require 'org-src)
  (let ((case-fold-search t)
        (missing '()))
    (dolist (file (directory-files blog/source-dir t "\\.org\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*#\\+begin_src[ \t]+\\([^ \t\n]+\\)" nil t)
          (let ((lang (match-string 1)))
            (unless (or (member lang missing)
                        (fboundp (org-src-get-lang-mode lang)))
              (push lang missing))))))
    (when missing
      (message
       "WARNING: no major mode for: %s — those blocks publish uncoloured.\n         Add the mode to `blog/packages' in publish.el."
       (string-join (nreverse missing) ", ")))))

;;; Head rewriting ------------------------------------------------------------

(defun blog/html-meta-filter (output _backend info)
  "Fix up the <head> of an exported post.

ox-html copies #+DESCRIPTION: into the description meta tag verbatim, so
org markup such as ~code~ would leak into search results — that tag is
replaced here with the plain-text rendering.  Open Graph, Twitter and
canonical tags are added at the same time, since ox-html emits none and
they need per-post values."
  (if (not (string-match-p "</head>" output))
      output
    (let* ((file (plist-get info :input-file))
           (slug (and file (file-name-base file)))
           (url (format "%s/posts/%s.html" blog/site-url slug))
           (title (blog/strip-tags (org-export-data (plist-get info :title) info)))
           ;; :description arrives as an unparsed string, so org-export-data
           ;; would hand back the raw markup.  Render it the same way the index
           ;; does, then flatten.  The nested export re-enters this filter, but
           ;; its body-only output has no </head> and is returned untouched.
           (raw-description (plist-get info :description))
           (description
            (blog/strip-tags
             (blog/inline-html (if (stringp raw-description)
                                   raw-description
                                 (org-export-data (or raw-description "") info)))))
           (extra
            (concat
             (format "<meta property=\"og:type\" content=\"article\"/>\n")
             (format "<meta property=\"og:title\" content=\"%s\"/>\n" (blog/escape title))
             (format "<meta property=\"og:description\" content=\"%s\"/>\n" (blog/escape description))
             (format "<meta property=\"og:url\" content=\"%s\"/>\n" (blog/escape url))
             "<meta name=\"twitter:card\" content=\"summary\"/>\n"
             (format "<meta name=\"author\" content=\"%s\"/>\n" (blog/escape blog/author))
             (format "<link rel=\"canonical\" href=\"%s\"/>\n" (blog/escape url)))))
      (setq output
            (replace-regexp-in-string
             "<meta name=\"description\" content=\"[^\"]*\""
             (format "<meta name=\"description\" content=\"%s\"" (blog/escape description))
             output t t))
      ;; Give the tab title the same "<post> — <author>" shape as the index.
      (setq output
            (replace-regexp-in-string
             "<title>[^<]*</title>"
             (format "<title>%s — %s</title>"
                     (blog/escape title) (blog/escape blog/author))
             output t t))
      (replace-regexp-in-string "</head>" (concat extra "</head>") output t t))))

;;; Code colours --------------------------------------------------------------
;;
;; A batch Emacs has no display, so every face resolves to `unspecified' and
;; htmlize can only emit bold/italic — the published code comes out grey.
;; Setting explicit colours here gives htmlize something to work with and makes
;; the output deterministic: it no longer depends on the theme, the Emacs
;; version's defaults, or the terminal's colour support.
;;
;; The palette matches GitHub's light syntax theme.

(defconst blog/code-faces
  '((default                        . "#24292e")
    (font-lock-comment-face         . "#6a737d")
    (font-lock-comment-delimiter-face . "#6a737d")
    (font-lock-doc-face             . "#032f62")
    (font-lock-string-face          . "#032f62")
    (font-lock-keyword-face         . "#d73a49")
    (font-lock-preprocessor-face    . "#d73a49")
    (font-lock-negation-char-face   . "#d73a49")
    (font-lock-function-name-face   . "#6f42c1")
    (font-lock-variable-name-face   . "#e36209")
    (font-lock-type-face            . "#005cc5")
    (font-lock-constant-face        . "#005cc5")
    (font-lock-builtin-face         . "#005cc5"))
  "Foreground colour for each face htmlize may encounter.")

(defun blog/set-code-faces ()
  "Give font-lock faces explicit colours so htmlize can render them."
  (setq htmlize-use-rgb-txt nil)
  ;; Decorations are reset too: without a colour display Emacs falls back to
  ;; bold/italic/underline to tell faces apart, and those would otherwise show
  ;; up in the published HTML on top of the colours set here.
  (pcase-dolist (`(,face . ,colour) blog/code-faces)
    (set-face-attribute face nil :foreground colour
                        :weight 'normal :slant 'normal
                        :underline nil :overline nil :strike-through nil
                        :box nil :inverse-video nil))
  ;; htmlize emits a background for the `default' face; the stylesheet owns it.
  (set-face-attribute 'default nil :background "#f6f8fa"))

;;; Root files ----------------------------------------------------------------

(defun blog/copy-root-files ()
  "Copy `blog/root-files' into the published site."
  (dolist (name blog/root-files)
    (let ((source (expand-file-name name blog/root)))
      ;; A hard error, not a warning: CI checks out only the paths it needs, so
      ;; a file listed here but not in the workflow's sparse-checkout would
      ;; otherwise deploy a site quietly missing that file.
      (unless (file-exists-p source)
        (error "%s is listed in `blog/root-files' but was not found in %s"
               name blog/root))
      (copy-file source (expand-file-name name blog/site-dir) t))))

;;; Project definition --------------------------------------------------------

(defun blog/configure ()
  "Set up org export options and `org-publish-project-alist'."
  (require 'ox-publish)
  (require 'ox-html)
  (require 'htmlize)
  (blog/set-code-faces)

  ;; Fontify src blocks with inline colours taken from the running Emacs, so
  ;; the published code matches what the buffer looks like and no stylesheet
  ;; has to be kept in sync with face definitions.
  (setq org-html-htmlize-output-type 'inline-css
        org-html-doctype "html5"
        org-html-html5-fancy t
        org-html-validation-link nil
        org-export-with-smart-quotes t
        ;; Never run babel during export; a post should not be able to execute
        ;; code as a side effect of deploying.
        org-export-use-babel nil)

  (add-to-list 'org-export-filter-final-output-functions #'blog/html-meta-filter)

  (setq org-publish-project-alist
        `(("blog-posts"
           :base-directory ,blog/source-dir
           :base-extension "org"
           :publishing-directory ,blog/output-dir
           :publishing-function org-html-publish-to-html
           :recursive nil
           :exclude ,(rx string-start (or "index") ".org" string-end)

           :with-toc nil
           :section-numbers nil
           :with-author nil
           :with-creator nil
           :with-date nil
           ;; The title, date and tags are rendered by `blog/post-preamble'.
           :with-title nil

           :html-doctype "html5"
           :html-head-include-default-style nil
           :html-head-include-scripts nil
           :html-head ,blog/html-head
           :html-preamble blog/post-preamble
           :html-postamble ,blog/post-postamble)

          ("blog-assets"
           :base-directory ,(expand-file-name "assets" blog/root)
           :base-extension "css\\|js\\|png\\|jpe?g\\|gif\\|svg\\|webp\\|pdf"
           :publishing-directory ,(expand-file-name "assets" blog/output-dir)
           :recursive t
           :publishing-function org-publish-attachment)

          ("blog" :components ("blog-posts" "blog-assets")))))

;;;###autoload
(defun blog/publish ()
  "Build the whole blog into posts/."
  (blog/install-packages)
  (blog/configure)
  (blog/check-src-languages)
  ;; Start from an empty site so a renamed or deleted post cannot leave stale
  ;; HTML behind.  CI always builds from a fresh checkout; this makes local
  ;; builds behave the same.
  (when (file-directory-p blog/site-dir)
    (delete-directory blog/site-dir t))
  (make-directory blog/site-dir t)
  ;; Always republish: the cache would otherwise skip files whose output was
  ;; removed, and a full build takes under a second.
  (let ((org-publish-use-timestamps-flag nil))
    (org-publish-all t))
  (blog/copy-root-files)
  (let ((posts (blog/posts)))
    (blog/write-index posts)
    (blog/write-rss posts)
    (message "Built %d post(s) into _site/" (length posts))))

(provide 'publish)
;;; publish.el ends here
