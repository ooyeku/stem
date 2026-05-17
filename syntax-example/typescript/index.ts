// Typed event bus. Run with: ts-node index.ts (or tsc && node index.js)

type EventMap = {
  login: { userId: string; at: Date };
  error: { code: number; message: string };
  tick: number;
};

type Listener<T> = (payload: T) => void;

class EventBus<M extends Record<string, unknown>> {
  private handlers: { [K in keyof M]?: Listener<M[K]>[] } = {};

  on<K extends keyof M>(event: K, fn: Listener<M[K]>): () => void {
    (this.handlers[event] ??= []).push(fn);
    return () => {
      this.handlers[event] = this.handlers[event]?.filter((h) => h !== fn);
    };
  }

  emit<K extends keyof M>(event: K, payload: M[K]): void {
    this.handlers[event]?.forEach((h) => h(payload));
  }
}

const bus = new EventBus<EventMap>();
const off = bus.on("login", ({ userId, at }) =>
  console.log(`login user=${userId} at=${at.toISOString()}`)
);
bus.on("error", ({ code, message }) => console.error(`[${code}] ${message}`));

bus.emit("login", { userId: "u-42", at: new Date() });
bus.emit("error", { code: 503, message: "service down" });
off();
