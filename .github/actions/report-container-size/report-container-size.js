import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { createAndUploadReport } from "@codecov/bundle-analyzer";
import { list } from "tar";

const [layout] = process.argv.slice(2);

function blobPath(digest) {
    return join(layout, "blobs", ...digest.split(":"));
}

async function readJson(path) {
    return JSON.parse(await readFile(path, "utf8"));
}

async function* images(index) {
    for (const descriptor of index.manifests) {
        const blob = await readJson(blobPath(descriptor.digest));

        if ("manifests" in blob) {
            yield* images(blob);
        } else if (descriptor.annotations?.["vnd.docker.reference.type"] !== "attestation-manifest") {
            yield { platform: descriptor.platform, manifest: blob };
        }
    }
}

function commonPath(paths) {
    const [first = [], ...rest] = paths.map((path) => path.split("/"));
    let length = first.length;

    for (const segments of rest) {
        let matching = 0;

        while (matching < length && segments[matching] === first[matching]) {
            matching += 1;
        }

        length = matching;
    }

    return first.slice(0, length).join("/");
}

async function layerAsset(layer) {
    const paths = [];
    let entries = 0;
    let size = 0;

    try {
        await list({
            file: blobPath(layer.digest),
            strict: true,
            onReadEntry: (entry) => {
                entries += 1;
                size += entry.size;

                if (entry.type !== "Directory") {
                    paths.push(entry.path);
                }
            },
        });
    } catch (error) {
        // `TAR_BAD_ARCHIVE` before the first entry means an empty layer, which is a valid tar
        if (error.code !== "TAR_BAD_ARCHIVE" || entries > 0) {
            throw error;
        }
    }

    const name = commonPath(paths) || "/";

    // pulling the image downloads each layer compressed, so `gzipSize` is the layer's compressed size from the manifest
    return { name, normalized: name, size, gzipSize: layer.size };
}

for await (const { platform, manifest } of images(await readJson(join(layout, "index.json")))) {
    const assets = await Promise.all(manifest.layers.map(layerAsset));

    await createAndUploadReport(
        [],
        {
            bundleName: ["container", platform.os, platform.architecture, platform.variant].filter(Boolean).join("-"),
            oidc: { useGitHubOIDC: true },
            telemetry: false,
        },
        {
            beforeReportUpload: async (report) => {
                report.assets = assets;

                return report;
            },
        },
    );
}
