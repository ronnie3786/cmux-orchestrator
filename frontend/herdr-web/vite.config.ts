import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Resolve assets beside the loaded document so reverse-proxy path prefixes
  // such as /base/herdr-web/ remain intact.
  base: "./",
  build: {
    // Writes into this repo's herdr server static dir (untracked build
    // output, generated at deploy).
    outDir: "../../herdr_harness/static/herdr-web",
    emptyOutDir: true
  }
});
