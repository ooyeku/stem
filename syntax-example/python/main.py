"""Word frequency counter. Run with: python3 main.py"""

from __future__ import annotations
from collections import Counter
from dataclasses import dataclass
import re


@dataclass(frozen=True)
class WordStats:
    total: int
    unique: int
    top: list[tuple[str, int]]


def count_words(text: str, top_n: int = 5) -> WordStats:
    words = re.findall(r"[a-zA-Z']+", text.lower())
    counts = Counter(words)
    return WordStats(
        total=sum(counts.values()),
        unique=len(counts),
        top=counts.most_common(top_n),
    )


def main() -> None:
    sample = """
    The quick brown fox jumps over the lazy dog.
    The dog was not amused. The fox kept jumping.
    """
    stats = count_words(sample)
    print(f"total={stats.total} unique={stats.unique}")
    for word, n in stats.top:
        print(f"  {word:<10} {n}")


if __name__ == "__main__":
    main()
