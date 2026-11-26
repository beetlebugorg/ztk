# Tin Moon, part by part

An agent builds [Tin Moon](../widgets/ttk.md#play-tin-moon) from five short prompts. Step through it with the arrow keys: each step adds one part, the code shows the new lines, and the handheld runs the game as it is at that step.

<!-- stage: toy-tinmoon -->

Each step runs in CI: `tests/replay.sh` runs its script and its check in `ztk --headless`.
