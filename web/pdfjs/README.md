# pdf.js 5.7.284

Mozilla's PDF renderer, served from the app's own origin so the document
preview works under the page's Content-Security-Policy (`script-src 'self'`,
no `eval`). From the npm package `pdfjs-dist@5.7.284`, integrity
`sha512-h4EdYQczmGhbOlqc3PPZwxevn7ApdWPbovAuWXOB/DjIyigSnwfy2oze7c6mRcSr9XgLp3eN3EeL4DyySTPMFw==`.
Apache-2.0, see LICENSE.

Only `build/pdf.min.mjs`, `build/pdf.worker.min.mjs` and `standard_fonts/` are
copied. Used by `lib/ui/widgets/browser_pdf_pages_web.dart`.
