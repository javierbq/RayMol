# RayMol Documentation Site

This directory contains the source for the public RayMol user documentation hosted at [https://javierbq.github.io/RayMol/](https://javierbq.github.io/RayMol/), which is linked directly from **Documentation** on [raymol.io](https://raymol.io).

The site is built with [Astro Starlight](https://starlight.astro.build/) and deployed to GitHub Pages.

---

## Authoring Documentation

### Where Pages Live

All published documentation pages are Markdown or MDX files located in:

```text
docs/src/content/docs/
```

File paths map directly to site URLs with the `/RayMol/` base path. For example:
- `docs/src/content/docs/index.mdx` → `https://javierbq.github.io/RayMol/`
- `docs/src/content/docs/guides/analysis-notes.md` → `https://javierbq.github.io/RayMol/guides/analysis-notes/`
- `docs/src/content/docs/getting-started/installation.md` → `https://javierbq.github.io/RayMol/getting-started/installation/`

### Frontmatter

Every page requires frontmatter with a `title` and `description`:

```yaml
---
title: Analysis Notes
description: Keep observations, hypotheses, and live molecular view links alongside your session.
---
```

### Navigation & Sidebar

Adding a new document does not automatically make it visible in the site navigation. To include a page in the navigation tree, add its slug to the `sidebar` configuration in `docs/astro.config.mjs`:

```javascript
{
  label: 'Working with Structures',
  items: [
    { label: 'Analysis Notes', slug: 'guides/analysis-notes' },
    // Add new page slug here (path relative to src/content/docs without extension)
  ],
}
```

### Internal Links

Because the site is hosted under a GitHub Pages subpath (`/RayMol`), internal links must always include the `/RayMol/` base and a trailing slash:

```markdown
<!-- Correct -->
[Analysis Notes](/RayMol/guides/analysis-notes/)

<!-- Incorrect: missing base path -->
[Analysis Notes](/guides/analysis-notes/)
```

### Starlight Asides

Use Starlight callout asides (`:::note`, `:::tip`, `:::caution`) to highlight platform-specific features, requirements, or limitations:

```markdown
:::note
This feature is available on macOS, iPad, and iPhone.
:::

:::caution
The built-in MCP server is not available in the sandboxed Mac App Store build.
:::
```

---

## Local Development

Node.js 22.12 or newer and pnpm are required. If you do not have pnpm installed globally, `npx pnpm@11.19.0` works out of the box.

```sh
cd docs

# Install dependencies
pnpm install
# or: npx -y pnpm@11.19.0 install

# Start local development server (live reload)
pnpm dev
# or: npx -y pnpm@11.19.0 dev

# Build the static site
pnpm build
# or: npx -y pnpm@11.19.0 build
```

Always run `pnpm build` before submitting changes to ensure there are no syntax errors or build failures.

---

## Deployment

The documentation site is built and deployed by [`.github/workflows/deploy-docs.yml`](../.github/workflows/deploy-docs.yml):

- **Pull requests:** Every pull request modifying files under `docs/**` runs a test build to ensure changes compile cleanly.
- **GitHub Pages deployment:** The site is automatically built and deployed to GitHub Pages when:
  - A new GitHub release is published (`release: [published]`).
  - A release tag matching `v*` is pushed.
  - The workflow is triggered manually via GitHub Actions (`workflow_dispatch`).

---

## Non-Published Content in `docs/`

Not everything in the `docs/` folder is part of the Astro Starlight site. The following directories and files contain developer reference material, release history, and site assets:

- **`release-notes/`** — Per-version user release notes (`v1.2.0.md` through `v1.12.1.md`) and unreleased drafts (`unreleased/`).
- **Internal design specifications** (`lighting.md`, `materials.md`, `predictors.md`, `generators.md`, `metrics.md`, `analysis-notes.md`, `ios-beta-pipeline.md`) — In-depth architectural designs and engineering documentation.
- **`appstore/`** — App Store listing copy, keywords, screenshots, and version notes for macOS and iOS submissions.
- **`raymol.io/`** — Website copy, privacy policy, and support documentation for the main [raymol.io](https://raymol.io) marketing site.
- **`superpowers/`** — Design specs, implementation plans, checklists, and visual galleries/mocks.
- **`issues/`** — Bug investigations and reproduction notes.
