# Added product image provenance

## WH-1000XM4C, black

- Manufacturer/product page: https://www.sony.com.ph/headphones/products/wh-1000xm4c
- The page's 360-degree viewer links to Sony's image asset `sonyglobalsolutions/01-61`.
- Exact retrieved image: https://sony.scene7.com/is/image/sonyglobalsolutions/01-61?fmt=png-alpha&wid=800&hei=800&fit=fit,1
- Retrieved: 2026-11-21.
- Source format: 800 × 800 PNG. The retrieved Sony rendition had transparent outer margins but an opaque white background behind and inside the headphones.
- The white background was removed with the OpenAI image generation/editing tool on 2026-11-21. The resulting 1254 × 1254 PNG has a transparent background; the product render was retained as the visual source, with generated antialiased cutout edges. It is stored at `Client/macos/Assets.xcassets/wh-1000xm4c.imageset/wh-1000xm4c.png` and `Client/resources/devices/wh-1000xm4c.png`.
- The macOS view scales the cutout 1.3× within its existing product-image frame to account for transparent padding while keeping the full headphone silhouette visible.

The product render and Sony marks belong to Sony. The repository's MIT code license does not grant rights to Sony imagery. Manufacturer asset rights are separate from the code license; this fork does not assert a separate redistribution license. Existing upstream image assets retain their respective rights and attribution.
