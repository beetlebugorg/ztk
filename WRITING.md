# Writing

These rules apply to commit messages, PR bodies, code comments, and docs.

Say what changed and why. Leave out summaries of the work, reflection on it, and statements of its significance.

## Avoid these constructions

- Reversals: "Pinned, not changed." State the thing and drop the contrast.
- Dramatic negatives: "And ran nothing."
- Aphorisms and figures of speech.
- Fragments for emphasis. Write the full sentence.
- Personified subjects: "The fix buys us."
- Filler verbs: carries, takes, brings, lands, sits. Use has, is, or goes in.
- Editorial asides: "Worth noting."
- Lists of three built for rhythm.
- Human verbs for code. Code does not know, say, want, decide, or refuse. Name the mechanism.

## Voice

Use US English. Use present tense for what the code does and past tense for what it did. Keep sentences short and active, with one idea in each. Do not use em dashes. Do not join two clauses with a semicolon for effect.

## Names

Use one name for one thing. The plan uses these names:

| Name | Meaning |
|---|---|
| widget | One node of the widget tree. Tk calls it a window. |
| toplevel | A widget that has its own platform window. |
| logical pixel | The unit of layout. One logical pixel is `scale` device pixels. |
| scene | The list of quads that one frame draws. |
| backend | The code for one platform: its windows, its input, and its GPU API. |
| the implementer | The agent or person that writes the code of a task. |
| the reviewer | The agent or person that checks the work with `docs/dev/review.md`. |

Do not name an AI model or an AI vendor in the repository.

## Terms

The limit of CPU work of ztcl is the compute limit, and it counts compute units. Use these two terms. Do not call the limit a step limit or fuel. `ztk::limit -compute N` sets it.

## Commit messages

Keep the subject under 72 characters. Wrap the body at 72. Give what changed and the one fact a reviewer needs. Add no attribution trailers or session links, and no references to ignored paths.

## PR bodies

Do not hard wrap. Put one paragraph on each line.

## Before you publish

Search for these strings. Justify or remove each hit: `—`, `, not `, `nothing`, `would`, `carries`, `takes`, `worth`, `which is`.

## Scope

Do what the task asks. Ask before you fix an adjacent problem.

## Claims

Write only facts that you checked. If you cannot check a fact, say so in the sentence. Give each number with the command that measured it. A number of five or more digits, and a round number such as 1,000, uses commas between groups of three digits (37,413), never spaces.
