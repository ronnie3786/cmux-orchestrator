// Node's experimental webstorage shadows jsdom's, so tests get a functional in-memory Storage.
function createMemoryStorage() {
  const store = new Map();
  return {
    get length() {
      return store.size;
    },
    key(index) {
      return Array.from(store.keys())[index] ?? null;
    },
    getItem(key) {
      return store.has(String(key)) ? store.get(String(key)) : null;
    },
    setItem(key, value) {
      store.set(String(key), String(value));
    },
    removeItem(key) {
      store.delete(String(key));
    },
    clear() {
      store.clear();
    }
  };
}

for (const name of ["localStorage", "sessionStorage"]) {
  const storage = createMemoryStorage();
  for (const target of [globalThis, globalThis.window]) {
    if (!target) continue;
    try {
      Object.defineProperty(target, name, { configurable: true, value: storage });
    } catch {
      target[name] = storage;
    }
  }
}
