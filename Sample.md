# A Reader for Markdown

Context renders a document the way a book would set it: one column, a fixed
measure, and type that stays out of the way. The editor is a guest — press
`⌘E` when you need it, dismiss it when you don't.

## Why measure matters

Line length is the single largest lever on reading comfort. Much past seventy
characters and the eye loses the return sweep; much below fifty and the rhythm
breaks. This paragraph sits in the middle of that range, which is why it feels
unremarkable — that is the goal.[^measure]

> Typography exists to honour content. A page that calls attention to its own
> cleverness has already failed at the only job it had.

### Structural elements

Ordinary lists behave as you'd expect:

- Warm paper rather than pure white, ink rather than pure black
- System fonts throughout — New York, SF Pro, SF Mono
- Nothing downloaded at render time

1. Parse with `markdown-it`
2. Typeset with CSS
3. Hand the result to WebKit

And task lists carry their own affordance:

- [x] Follow the system between light and dark
- [x] Keep the scroll position when the file changes on disk
- [ ] Outline sidebar
- [ ] Export to PDF

## Mathematics

Inline maths sets on the baseline without disturbing leading — the Gaussian
integral $\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$ sits inside this
sentence quite comfortably. Display maths gets its own air:

$$
\min_{x \in \mathbb{R}^n} \; \tfrac{1}{2} x^\top Q x + c^\top x
\quad \text{subject to} \quad Ax \le b
$$

And a matrix, to check that wider expressions are handled:

$$
Q = \begin{bmatrix}
2 & -1 & 0 \\
-1 & 2 & -1 \\
0 & -1 & 2
\end{bmatrix}, \qquad \lambda_i = 2 - 2\cos\!\left(\frac{i\pi}{n+1}\right)
$$

## Code

Fenced blocks break out slightly wider than the prose measure, so long lines
have somewhere to go before the scrollbar appears.

```julia
"""
    tridiagonal(n) -> SymTridiagonal

Second-difference operator; eigenvalues known in closed form.
"""
function tridiagonal(n::Int)
    SymTridiagonal(fill(2.0, n), fill(-1.0, n - 1))
end

λ = eigvals(tridiagonal(64))
@assert all(λ .> 0)          # positive definite
```

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Measure:
    characters: int = 68

    def is_comfortable(self) -> bool:
        return 50 <= self.characters <= 75
```

Inline code such as `--parse-as-library` or `prefers-color-scheme` keeps its
own subtle background without shouting.

## Tables

| Route | Bundle | Memory | Feel |
|---|---|---|---|
| SwiftUI + WebKit | 1.5 MB | ~70 MB | Native shell, web typography |
| Pure AppKit text | 0.4 MB | ~25 MB | Native, but tables hurt |
| Electron | 210 MB | ~300 MB | Uniform everywhere |

---

Links behave normally — [CommonMark](https://commonmark.org) opens in your
browser, while a relative link stays inside Context.

[^measure]: Bringhurst puts the ideal at 66 characters, "counting both letters
and spaces", and calls anything from 45 to 75 satisfactory.
