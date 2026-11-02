# Social Preview Kit

This directory contains the assets and renderer used to build `docs/social-preview.jpg` (1280×640 JPEG, under 1 MB) for the repository's GitHub social preview card.

## Files

- **`background.jpg`** — Abstract oil painting generated with an image model from the following prompt:
  > "Abstract expressive oil painting filling the whole frame, wide 16:9: thick visible brushstrokes, canvas texture, soft painterly blending, diagonal sweeping strokes, editorial OpenAI-blog-cover aesthetic. ABSOLUTELY NO text, letters, logos, symbols, faces or objects. Keep the center calmer and mid-tone so white text stays readable. Palette: deep indigo and violet twilight (evening sky, the passage of a day) with accents of coral, pink, turquoise and golden yellow."
- **`icon.svg`** — Lucide `"activity"` icon (ISC license).
- **`render.py`** — Lays out the white icon and two-line wordmark over the background image using headless Google Chrome. The central lockup is kept inside the middle square so it remains intact when chat apps crop the card to 1:1.

## Rebuild

Run from the repository root (requires Python 3 and Google Chrome installed):

```sh
python3 docs/social-preview/render.py --background docs/social-preview/background.jpg --icon docs/social-preview/icon.svg --name "lifetrace|for agents" --out docs/social-preview.jpg
```

## Upload

Upload the generated `docs/social-preview.jpg` (1280×640 JPEG, < 1 MB) in the GitHub repository under **Settings → General → Social preview**.
