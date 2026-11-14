import { defineConfig, normalizePath, type Plugin } from 'vite';
import { cpSync, existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(import.meta.dirname, '..');
const assetDirs = ['audio', 'data'];
// SF Pro ships with Apple's font installer; SF Mono lives inside Terminal.app.
const FONT_DIRS = ['/Library/Fonts', path.join(process.env.HOME ?? '', 'Library/Fonts'), '/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts'];

// Git can check out directory symlinks as plain files on Windows. Serve the
// original assets through Vite and copy them into builds without using symlinks.
function repoAssets(): Plugin {
  return {
    name: 'repo-assets',
    configureServer(server) {
      // Apple's SF faces are read from the system font folder at run time; they are never copied into the repo.
      server.middlewares.use((req, res, next) => {
        const m = /^\/sysfonts\/(SF-[\w-]+\.otf)$/.exec(req.url ?? '');
        if (m) {
          const f = FONT_DIRS.map((d) => path.join(d, m[1]!)).find((x) => existsSync(x));
          if (!f) { res.statusCode = 404; res.end(); return; }
          res.setHeader('Content-Type', 'font/otf');
          res.end(readFileSync(f));
          return;
        }
        if (assetDirs.some((dir) => req.url?.startsWith(`/${dir}/`))) {
          req.url = `/@fs/${encodeURI(normalizePath(repoRoot))}${req.url}`;
        }
        next();
      });
    },
    writeBundle(options) {
      if (!options.dir) return;
      for (const dir of assetDirs) {
        cpSync(path.join(repoRoot, dir), path.join(options.dir, dir), { recursive: true });
      }
    },
  };
}

export default defineConfig({
  root: '.',
  publicDir: 'public',
  plugins: [repoAssets()],
  // TRAILER_NO_HMR=1: no live reload (export renders must not reload mid-run when a file changes)
  server: { port: 5173, strictPort: false, hmr: process.env.TRAILER_NO_HMR ? false : undefined, fs: { allow: [repoRoot] } },
  resolve: { alias: { '@root': repoRoot }, dedupe: ['three'] },
  optimizeDeps: { include: ['three', 'three/examples/jsm/geometries/RoundedBoxGeometry.js'] },
  build: { target: 'esnext', assetsInlineLimit: 0 },
});
