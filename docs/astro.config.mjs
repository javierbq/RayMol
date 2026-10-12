import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://javierbq.github.io',
  base: '/RayMol',
  integrations: [
    starlight({
      title: 'RayMol Docs',
      description: 'Documentation for the native Metal-powered PyMOL experience on Apple platforms.',
      logo: {
        src: './src/assets/logo.svg',
        replacesTitle: false,
      },
      customCss: ['./src/styles/custom.css'],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/javierbq/RayMol',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/javierbq/RayMol/edit/master/docs/src/content/docs/',
      },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Installation', slug: 'getting-started/installation' },
            { label: 'Quickstart', slug: 'getting-started/quickstart' },
            { label: 'Interface Tour', slug: 'getting-started/interface' },
          ],
        },
        {
          label: 'Working with Structures',
          items: [
            { label: 'Selecting, Measuring & Moving', slug: 'guides/selecting' },
            { label: 'Analysis Notes', slug: 'guides/analysis-notes' },
            { label: 'Glycobiology', slug: 'guides/glycobiology' },
          ],
        },
        {
          label: 'Rendering',
          items: [
            { label: 'Rendering & Export', slug: 'guides/rendering-export' },
            { label: 'Studio Lights & Atmosphere', slug: 'guides/lighting' },
            { label: 'Materials & Looks', slug: 'guides/materials' },
            { label: 'Camera, Lens & Depth of Field', slug: 'guides/camera' },
            { label: 'Movies & Scenes', slug: 'guides/movies' },
          ],
        },
        {
          label: 'Predict & Design',
          items: [
            { label: 'Structure Prediction', slug: 'guides/predict' },
            { label: 'Sequence Design', slug: 'guides/design' },
            { label: 'Metrics', slug: 'guides/metrics' },
          ],
        },
        {
          label: 'AI Integration',
          items: [
            { label: 'MCP Server (Claude & AI apps)', slug: 'guides/mcp-setup' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Commands & Python API', slug: 'reference/commands' },
            { label: 'RayMol Settings', slug: 'reference/settings' },
            { label: 'Keyboard Shortcuts', slug: 'reference/keyboard-shortcuts' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { label: 'Architecture', slug: 'concepts/architecture' },
          ],
        },
      ],
    }),
  ],
});
