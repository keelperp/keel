import { defineConfig } from "vite";
// Deep links must survive a hard refresh in production. A host that serves index.html
// only at "/" turns every route into a 404 the dev server never shows.
export default defineConfig({
  build: { target: "es2022" },
  server: { port: 5173 },
});
