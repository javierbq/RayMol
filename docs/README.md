# RayMol documentation site

The public documentation is built with [Astro Starlight](https://starlight.astro.build/) and deployed to GitHub Pages.

## Local development

Node.js 22.12 or newer and pnpm are required.

```sh
cd docs
pnpm install
pnpm dev
```

Run `pnpm build` before opening a pull request. After this branch is merged, repository administrators must set **Settings → Pages → Build and deployment → Source** to **GitHub Actions** once.
