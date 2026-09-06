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
        baseUrl: 'https://github.com/javierbq/RayMol/edit/master/docs/',
      },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Installation', slug: 'getting-started/installation' },
            { label: 'Quickstart', slug: 'getting-started/quickstart' },
          ],
        },
        {
          label: 'How-to Guides',
          items: [
            { label: 'Claude MCP Integration', slug: 'guides/mcp-setup' },
            { label: 'Rendering & Export', slug: 'guides/rendering-export' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'PyMOL Commands & API', slug: 'reference/commands' },
          ],
        },
        {
          label: 'Architecture',
          items: [
            { label: 'Metal Engine Design', slug: 'concepts/architecture' },
          ],
        },
      ],
    }),
  ],
});
