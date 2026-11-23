# CSS

The style system of ztk is a subset of CSS. ztk has its own parser and its own cascade. It has no code of a browser or of a CSS library.

Each specification is a W3C document. https://www.w3.org/Style/CSS/

**License:** W3C Document License for the text. ztk uses the rules and has no copy of the text.

| Specification | How ztk uses it |
|---|---|
| CSS Syntax Module Level 3 | The token rules and the error recovery of the parser |
| Selectors Level 4 | Type, id, and class selectors, the two combinators, the pseudo-classes, and the specificity |
| CSS Cascading and Inheritance Level 4 | The order of origins, specificity, and position; inheritance; `inherit` and `initial` |
| CSS Custom Properties for Cascading Variables Level 1 | `--name`, `var()`, fallbacks, and cycles |
| CSS Color Module Level 4 | The color forms and the table of 148 named colors |
| CSS Backgrounds and Borders Module Level 3 | `background-color`, `border`, `border-radius`, `box-shadow` |
| CSS Images Module Level 3 | `linear-gradient` and its angle and length rule |
| CSS Values and Units Module Level 3 | `px`, `pt`, `em`, `rem`, and percentages |
| CSS Transitions | `transition` and the `ease` timing function |
| Media Queries Level 5 | `prefers-color-scheme` |
| WCAG 2 | The contrast ratio of the scene checks |

The state names of `ttk` are from the manual page `ttk_widget.n` of Tk. The plan maps them to the pseudo-classes.
