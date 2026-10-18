// The findings catalogue (docs/findings.json).
import { readRepoFile } from './content.mjs';

let cached;

export async function loadCatalogue() {
  if (!cached) cached = JSON.parse(await readRepoFile('docs/findings.json'));
  return cached;
}

export function resetCatalogueCache() { cached = undefined; }

/** Case-insensitive lookup by id. Returns undefined when unknown. */
export function findFinding(catalogue, id) {
  const want = String(id).trim().toLowerCase();
  return catalogue.findings.find((f) => f.id.toLowerCase() === want);
}
