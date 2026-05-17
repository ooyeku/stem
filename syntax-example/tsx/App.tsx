// Tiny React counter. Build with: tsc --jsx react App.tsx (needs react types)

import * as React from "react";
import { useState, useCallback } from "react";

type Props = { initial?: number; step?: number };

const Counter: React.FC<Props> = ({ initial = 0, step = 1 }) => {
  const [count, setCount] = useState<number>(initial);
  const increment = useCallback(() => setCount((c) => c + step), [step]);
  const reset = useCallback(() => setCount(initial), [initial]);

  return (
    <div className="counter">
      <h1>{count}</h1>
      <button onClick={increment} disabled={count >= 10}>
        +{step}
      </button>
      <button onClick={reset}>reset</button>
      {count >= 10 && <p style={{ color: "red" }}>max reached</p>}
    </div>
  );
};

export default function App(): JSX.Element {
  return (
    <main>
      <Counter initial={0} step={2} />
    </main>
  );
}
