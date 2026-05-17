// Simple async fetch-and-summarize. Run with: node index.js

const fakeApi = async (id) =>
  new Promise((resolve) =>
    setTimeout(() => resolve({ id, value: Math.random() * 100 }), 10)
  );

async function fetchAll(ids) {
  const results = await Promise.all(ids.map(fakeApi));
  return results.reduce(
    (acc, { value }) => ({
      sum: acc.sum + value,
      max: Math.max(acc.max, value),
      min: Math.min(acc.min, value),
      count: acc.count + 1,
    }),
    { sum: 0, max: -Infinity, min: Infinity, count: 0 }
  );
}

(async () => {
  const ids = Array.from({ length: 10 }, (_, i) => i + 1);
  const { sum, max, min, count } = await fetchAll(ids);
  console.log(`avg=${(sum / count).toFixed(2)} min=${min.toFixed(2)} max=${max.toFixed(2)}`);
})();
