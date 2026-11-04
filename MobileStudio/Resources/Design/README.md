# Design

Mockups of this app's screens, made in Mobile Studio's Design window. They are the reference for how the screens
should look; the Flutter code in `lib/` is what the app really is. Mobile Studio writes `README.md`, `kit.css`,
`tokens.css` and each screen's `screen.json`; Claude writes the mockups and `tokens.json`.

- `tokens.json`: the look (colours for light and dark, fonts, corner radius, depth, spacing, type scale).
  `tokens.css` is the same as CSS variables, and `lib/app/design_theme.dart` the same as a Flutter theme.
- `screens/<screen>/`: one folder per screen. `current.html` is the screen as it is built, redrawn (redesigns only),
  `current.png` a picture of it from the app, and `v1.html`, `v2.html`, … versions, never edited once written.
  `screen.json` says which version is chosen and what was asked for each.
- `look/`: colour themes and font pairings suggested while choosing the look.
- `fonts/`: the Google Fonts files the mockups use.

## Rules for mockups

Each mockup is one HTML file of a 393 × 852 pt phone screen:

```html
<!doctype html>
<html><head><meta charset="utf-8"><meta name="ms-screen" content="Today">
<link rel="stylesheet" href="../../tokens.css"><link rel="stylesheet" href="../../kit.css"></head>
<body><div class="screen">…</div></body></html>
```

- Layout with `.row` and `.column` (flexbox), `.gap-1`…`.gap-6`, `.pad-1`…`.pad-6`, `.pad-x-*`, `.pad-y-*`, `.grow`,
  `.spacer`, `.scroll`. No CSS grid, no floats, no absolute positioning (only the overlays below float).
- Only the classes below, and colours only through tokens (`var(--primary)`) or the colour classes. No literal
  colours, no `font-family`, no `<script>`, no `<img>`, nothing from the internet. A `style` attribute may set
  sizes, widths, margins and the kit's own variables (`--value`, `--ratio`).
- Real text from the app or the plan, never lorem ipsum.

## The kit and the Flutter widget each class is

| Class | Flutter |
|---|---|
| `.screen` (add `.with-nav` with a nav bar) | `Scaffold` |
| `.app-bar`, `.app-bar-title`, `.app-bar.large` | `AppBar`, its `title`, `SliverAppBar.large` |
| `.card`, `.card.filled`, `.card.outlined` | `Card`, `Card.filled`, `Card.outlined` |
| `.list`, `.list-tile`, `.list-tile-title`, `.list-tile-subtitle` | `ListView`, `ListTile`, its `title` and `subtitle` |
| `.button.filled`, `.button.tonal`, `.button.outlined`, `.button.text`, `.button.elevated` | `FilledButton`, `FilledButton.tonal`, `OutlinedButton`, `TextButton`, `ElevatedButton` |
| `.icon-button` (`.filled`, `.tonal`) | `IconButton` (`.filled`, `.filledTonal`) |
| `.fab`, `.fab.extended` | `FloatingActionButton`, `FloatingActionButton.extended` |
| `.text-field`, `.text-field-label`, `.text-field-input` (`.placeholder`), `.text-field.filled` | `TextField` with `InputDecoration` (`labelText`, `hintText`, `filled`) |
| `.chip`, `.chip.selected` | `FilterChip` / `ChoiceChip` |
| `.switch` (`.on`), `.checkbox` (`.on`), `.radio` (`.on`) | `Switch`, `Checkbox`, `Radio` |
| `.slider` (`style="--value: 40%"`) | `Slider` |
| `.progress`, `.progress-circular` (`--value`) | `LinearProgressIndicator`, `CircularProgressIndicator` |
| `.divider` | `Divider` |
| `.avatar` | `CircleAvatar` |
| `.badge` | `Badge` |
| `.nav-bar`, `.nav-item` (`.selected`) | `NavigationBar`, `NavigationDestination` |
| `.tab-bar`, `.tab` (`.selected`) | `TabBar`, `Tab` |
| `.segmented`, `.segment` (`.selected`) | `SegmentedButton`, `ButtonSegment` |
| `.sheet`, `.scrim` | `showModalBottomSheet` |
| `.dialog` | `AlertDialog` |
| `.snackbar` | `SnackBar` |
| `.image` (`style="--ratio: 4 / 3"`), with a caption | `Image`, a chart or a map: whatever the caption says |
| `<span class="icon">name</span>` (`.small`, `.large`) | `Icon(Icons.name)`: only names Flutter's `Icons` has |
| `.display-large` … `.label-small` | `Theme.of(context).textTheme.displayLarge` … `labelSmall` |
| `.text-primary`, `.text-secondary`, `.text-variant`, `.text-error` | `colorScheme.primary`, `secondary`, `onSurfaceVariant`, `error` |
| `.bg-primary`, `.bg-primary-container`, `.bg-secondary-container`, `.bg-surface-container` | a `Container` coloured with that `colorScheme` role |
| `.rounded-s`, `.rounded-m`, `.rounded-l` | `BorderRadius.circular` of the tokens' small, medium, large radius |

## Building from a mockup

Match the layout, spacing, copy and components with the widgets above, and take every colour, font and radius from
`Theme.of(context)`, never from the mockup's values. `lib/app/design_theme.dart` already carries the tokens.
