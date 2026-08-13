'use strict'

// Antora extension: render [mermaid] blocks without an npm dependency.
//
// WHY THIS EXISTS
//
// site.yml previously required '@sntke/antora-mermaid-extension'. That package
// is not installed in the RHDP Showroom content image
// (ghcr.io/rhpds/showroom-content), and Antora treats a missing extension as
// FATAL: it builds nothing, the served directory stays empty, and every page
// 404s. The failure looks like a content problem but is a dependency problem.
//
// Local extensions are loaded by relative path from the cloned repo, so they
// work in every environment that builds this site: the content container,
// GitHub Actions, and a laptop. Keep it that way. Do not reintroduce an npm
// extension unless you have confirmed the content image ships it.
//
// HOW IT WORKS
//
// Without the npm extension, Asciidoctor renders
//
//     [mermaid]
//     ....
//     flowchart TD
//     ....
//
// as a generic <div class="literalblock"><div class="content"><pre>…</pre>.
// There is no marker identifying it as a diagram, so blocks are matched on
// their first word against the list of mermaid diagram keywords below.
//
// The <pre> body is left HTML-escaped on purpose. Mermaid reads the element's
// textContent, so the escaped "&lt;br/&gt;" is what produces the literal
// "<br/>" that mermaid needs for a line break inside a node label. Unescaping
// it here would make the browser parse it as real markup and the label would
// silently lose its line breaks.

const MERMAID_URL = 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs'

const DIAGRAM_KEYWORDS = new RegExp(
  '^(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|' +
  'journey|gantt|pie|gitGraph|mindmap|timeline|quadrantChart|requirementDiagram|' +
  'sankey-beta|xychart-beta|block-beta|C4Context)\\b'
)

const LITERAL_BLOCK =
  /<div class="literalblock">\s*<div class="content">\s*<pre>([\s\S]*?)<\/pre>\s*<\/div>\s*<\/div>/g

const LOADER = [
  '<script type="module">',
  `import mermaid from '${MERMAID_URL}'`,
  "mermaid.initialize({ startOnLoad: true, securityLevel: 'strict' })",
  '</script>',
].join('\n')

module.exports.register = function () {
  this.on('pagesComposed', ({ contentCatalog }) => {
    const pages = contentCatalog.getPages((p) => p.out && p.contents)
    let converted = 0
    let touched = 0

    pages.forEach((page) => {
      const html = page.contents.toString()
      if (html.includes('class="mermaid"')) return

      let found = 0
      const updated = html.replace(LITERAL_BLOCK, (match, body) => {
        // Compare against the unescaped text, but emit the escaped body.
        const probe = body
          .replace(/&lt;/g, '<')
          .replace(/&gt;/g, '>')
          .replace(/&amp;/g, '&')
          .trim()
        if (!DIAGRAM_KEYWORDS.test(probe)) return match
        found++
        return `<div class="mermaid-block"><pre class="mermaid">${body}</pre></div>`
      })

      if (!found) return
      converted += found
      touched++
      page.contents = Buffer.from(updated.replace('</body>', `${LOADER}\n</body>`))
    })

    console.log(`[inject-mermaid] converted ${converted} diagram(s) across ${touched} page(s)`)
  })
}
