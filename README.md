# Pulp - Handwriting to PDF

Pulp is a native macOS app that turns your handwritten notes into typeset PDFs you can select and search. It uses GLM-OCR to recognize your notes on your Mac. Review the result beside the original, keep your diagrams, and export a new PDF.

## Features

- **Local recognition:** Open a PDF and recognize its pages with GLM-OCR on your Mac.
- **Side-by-side review:** Compare each original page with an editable draft and rendered preview.
- **Math support:** Review and edit equations as LaTeX, then render them in the PDF.
- **Keep original figures:** Select a diagram or equation on the original page and place its crop in the output.
- **Typeset export:** Create a PDF with visible, selectable prose, rendered equations, and your selected crops.

## How it works

1. Open a PDF. The app renders each page at a maximum dimension of 2200 pixels, then downsamples the recognition image to a maximum of 1100 pixels using Apple's Lanczos filter.
2. GLM-OCR recognizes pages locally, one at a time. The app shows progress and page-level errors.
3. Review the draft beside the original. Correct text and LaTeX; OCR can miss text or change mathematical symbols. To preserve a diagram or an uncertain equation, select a region and choose **Add Selected Figure**. Move its marker in the draft to change its position.
4. Choose **Export PDF**, then reopen the typeset PDF to check the result.

The original PDF is not modified. The larger page image remains available for preview and figure crops. The OCR engine sits behind an interface so other recognizers can be evaluated later.

The editor exposes LaTeX for math, and figures are selected manually. Cropped figures and equations are images. Equations rendered from LaTeX are visible, but their text selection and extraction may be incomplete. Edits are kept for the open session, so export before closing. The initial scope is small, single-column English notes.

## Evaluation

These existing visual reports show the decisions behind the current pipeline:

- [GLM and MiniCPM page recognition with Qwen formula detection](docs/reports/models/workflow-report.html) shows GLM whole-page recognition, MiniCPM's layout and recognition workflow, and Qwen's formula proposals on the same pages. Qwen's proposals are not a complete page pipeline.
- [GLM vs. MiniCPM: five-page recognition and timing comparison](docs/reports/models/fresh-comparison.html) compares their output on five pages and includes per-page timings. The timings measure different operations, so they are not a controlled speed comparison.
- [Resolution comparison](docs/reports/resolution/index.html) compares 2200 and 1100 pixels on 13 pages. The test used one run per size, pages from one writer, and a different downsampling implementation from the app's native filter.
- [Combined-document run](docs/reports/combined/index.html) shows the current native 1100-pixel pipeline on 12 pages. Its earlier 2200-pixel run used different conditions, which limits the timing comparison.

The reports include handwritten page images, references, and raw model output. Some references were generated after earlier model output was seen. These small samples do not establish accuracy across all handwriting. GitHub shows HTML files as source; clone the repository and open the reports locally to see their visual layouts.

## Getting started

You need an Apple Silicon Mac with macOS 26 or later, Xcode with Swift 6.2 or later, and the Metal toolchain. The development setup was built with Xcode 27.2. The first build downloads Swift dependencies, and the first recognition run downloads an approximately 2.2 GB model.

From the project folder, run:

```sh
./macos/run-app.sh
```

The script builds and opens the app. If the Metal toolchain is missing, install it with `xcodebuild -downloadComponent MetalToolchain`. This is a developer-run build; it is not signed for distribution or notarized.

Open a PDF to start recognition. If model setup fails, resolve the issue and use **Recognize Remaining** or **Retry Page**. You can remove the downloaded model with **Remove Model** in the app.

## Tech stack

- **App and interface:** Swift and SwiftUI.
- **PDF input and image preparation:** PDFKit and Core Image.
- **Local recognition:** [GLM-OCR](https://huggingface.co/zai-org/GLM-OCR), [GLM-OCR Swift](https://github.com/tansanrao/glm-ocr-swift), and MLX.
- **Preview and export:** WebKit, bundled [KaTeX](https://katex.org/), and PDFKit.


Built by [Satwik](https://satwiktungala.com).
