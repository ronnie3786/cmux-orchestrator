import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/herdr-web/",
  build: {
    // Writes into this repo's herdr server static dir (untracked build
    // output, generated at deploy).
    outDir: "../../herdr_harness/static/herdr-web",
    emptyOutDir: true
  }
});
