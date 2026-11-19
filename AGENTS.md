# Repository Guidelines

## Project Structure

This repository currently contains standalone PDF guides in its root:

- `Headscale_Keenetic_guide.pdf` covers remote access with Headscale and Keenetic.
- `Keenetic_ochistka_fleshki.pdf` is a guide concerning Keenetic storage cleanup.

There are no source-code, test, or asset directories at present. Keep new guides in the root unless a clear need for subdirectories emerges. Use descriptive filenames that identify the subject and format.

## Creating and Reviewing Guides

No build system or automated test suite is configured. When adding or updating a PDF, retain its editable source when available and document the generation method alongside it. Check the final PDF in a viewer, including page breaks, Cyrillic text, command formatting, links, and readability.

For technical instructions, verify commands and URLs against the relevant software versions. Clearly distinguish commands run on a router, a VPS, and a local computer. Do not include real credentials, private keys, or registration tokens.

If Poppler is available, render pages for visual review:

```sh
pdftoppm -png guide.pdf preview/page
```

Create the `preview` directory first; keep generated preview images out of the committed files unless they are intentional deliverables.

## Writing and Naming

Use clear, concise language and descriptive headings. Present procedures in execution order, show commands in separate code blocks, and state expected results where useful. Identify placeholders explicitly so readers do not run example addresses or keys unchanged. Follow the language and terminology of the guide being edited.

## Commits and Pull Requests

The repository has no commits yet, so no existing commit convention can be inferred. Use short, descriptive commit subjects, for example `Add Keenetic remote access guide`. In a pull request, summarize the change, identify affected guides, and explain how the PDF and technical instructions were checked. Include screenshots when they help reviewers assess a layout change.
