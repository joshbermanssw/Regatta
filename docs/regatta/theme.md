# Regatta base theme — Blue Matrix

Regatta ships with **Blue Matrix** as its default dark theme (source: https://cmuxthemes.com/themes/blue-matrix/).
A fresh Regatta install should default to this; the Regatta rail/fleet/memory UI should derive its
accent palette from it (deep blue accent, matrix-green highlights).

## Core
| Role | Hex |
|---|---|
| Foreground | `#00a2ff` |
| Background | `#101116` |
| Cursor | `#76ff9f` |

## ANSI palette (0–15)
| # | Color | Hex | | # | Color | Hex |
|---|---|---|---|---|---|---|
| 0 | Black | `#101116` | | 8 | Bright Black | `#686868` |
| 1 | Red | `#ff5680` | | 9 | Bright Red | `#ff6e67` |
| 2 | Green | `#00ff9c` | | 10 | Bright Green | `#5ffa68` |
| 3 | Yellow | `#fffc58` | | 11 | Bright Yellow | `#fffc67` |
| 4 | Blue | `#00b0ff` | | 12 | Bright Blue | `#6871ff` |
| 5 | Magenta | `#d57bff` | | 13 | Bright Magenta | `#d682ec` |
| 6 | Cyan | `#76c1ff` | | 14 | Bright Cyan | `#60fdff` |
| 7 | White | `#c7c7c7` | | 15 | Bright White | `#ffffff` |

## Apply (cmux built-in)
```
cmux themes set --dark "Blue Matrix"
```

## Ghostty config block
```
foreground = #00a2ff
background = #101116
cursor-color = #76ff9f
palette = 0=#101116
palette = 1=#ff5680
palette = 2=#00ff9c
palette = 3=#fffc58
palette = 4=#00b0ff
palette = 5=#d57bff
palette = 6=#76c1ff
palette = 7=#c7c7c7
palette = 8=#686868
palette = 9=#ff6e67
palette = 10=#5ffa68
palette = 11=#fffc67
palette = 12=#6871ff
palette = 13=#d682ec
palette = 14=#60fdff
palette = 15=#ffffff
```

## Regatta UI accent mapping (suggested)
- **Primary accent / brand**: `#00a2ff` (foreground blue) — brain section, links, active states.
- **Success / running / loop-green**: `#00ff9c` / cursor `#76ff9f` — worker "running", loop progress.
- **Warning / queued**: `#fffc58`. **Error / failed**: `#ff5680`.
- **Surfaces**: background `#101116`; raise panels slightly for the rail.
