# Newton Swarm logo options

Five distinct 1024×1024, opaque RGB PNGs are in [logos/](logos/README.md), in the requested order: mascot, geometric icon, ticker lettermark, coin emblem, and meme illustration. The selected primary image is [artifacts/logo.png](artifacts/logo.png), an exact copy of option 2.

The creator's [reference image](https://fxumiqjngmabtgvruvka.supabase.co/storage/v1/object/public/forum-attachments/posts/mv125ia6-cuvk4b.png) supplied the green amphibian scholar, white curled wig, purple accents, cobalt blue and gold palette. Each variation was drawn by OpenAI's built-in image generation tool (`image_gen.imagegen`), using that reference. Five drafts were generated, one per approach; all five designs are retained in the final logo files and none were rejected. There were no redraws. The downloaded reference is `artifacts/reference.png`. Redundant 1254×1254 intermediate renders were removed to keep the source bundle below the 8 MiB upload limit.

The generator returned 1254×1254 renders. FFmpeg performed only Lanczos resampling to the required 1024×1024 size and RGB PNG encoding. The final files were then losslessly re-encoded with mixed PNG prediction and compression level 9; every decoded RGB byte was compared before and after and remained identical. This preserves the full color depth and image detail. [artifacts/compression.json](artifacts/compression.json) records the byte savings and decoded pixel hashes. No script, vector or code drew the logo artwork, and no typography was added afterward. Only option 3 contains text: `SNEWT`.

I inspected every image and the [size-check sheet](artifacts/size-check.png). Columns are options 1–5. Rows show 160-pixel squares, 64-pixel squares on light, 64-pixel squares on dark, and pairs of actual 32-pixel circular crops on light and dark. The primary has a full-square blue background, one dominant face-and-wig mark, and no text, frame or outer border. Its face, eyes and white wig remain readable at 32 pixels.

Option 2 was selected for its simple shapes. The other drafts remain useful alternatives: option 1 has more portrait detail, option 3 intentionally contains lettering, option 4 intentionally has a coin rim, and option 5 has a busier comic treatment. Those distinctions make them less suitable than option 2 for the primary's strict borderless, text-free, 32-pixel requirement.

## Verification

The repository includes a dependency-free Foundry project that checks the actual image files. `src/LogoPng.sol` validates PNG headers, dimensions and chunk bounds; it is an asset-checking library. The suite verifies all six output files, distinct options, the primary copy, and rejection of malformed or incorrectly sized files. It does not test financial launch contracts.

```sh
forge build --offline
forge test --offline
forge test --offline --fuzz-seed 0x6e6577746f6e
forge fmt --check
python3 scripts/check_logos.py
```

Solidity is pinned to 0.8.26 with Cancun, optimizer enabled and `bytecode_hash = "none"`. FFI is disabled; the only filesystem permissions are reads of the two local image directories. There are no third-party imports, remote dependencies, RPC requests or skipped tests. The Python integrity checker uses only the standard library and verifies chunk CRCs, complete compressed image data, 1024×1024 dimensions, RGB opacity, unique hashes, and the selected copy. Its recorded result is [artifacts/validation.json](artifacts/validation.json).

To recreate the inspection sheet from the delivered art with the system FFmpeg executable:

```sh
python3 scripts/preview_logos.py
```

Both `forge build` and `forge test` were also run without additional flags. The final suite passes 11 tests, including 512 fuzz cases; a second seed also passes. The image inspector independently confirmed all six PNG files have valid structure and the required dimensions. Automated checks establish file properties; readability and the absence of unwanted text were visually checked.
