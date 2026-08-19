import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/herdr-web/",
  build: {
    // Writes into the cmux-herdr-harness worktree's static dir (untracked
    // build output — that repo is otherwise read-only for this project).
    outDir: "../../../cmux-herdr-harness/herdr_harness/static/herdr-web",
    emptyOutDir: true
  }
});
