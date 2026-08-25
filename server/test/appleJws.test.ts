import { describe, expect, it } from "vitest";
import { AppleJwsError, decodeAppleJwsPayloadUnverified, verifyAppleJws } from "../src/appleJws";
import { APPLE_ROOT_CA_G3_DER } from "../src/appleRootCA";
import { mintCertificate, mintChain, signJws, toBase64 } from "./appleCertFixtures";

const DAY_MS = 24 * 60 * 60 * 1000;

describe("verifyAppleJws", () => {
  it("returns the payload of a well-formed chain", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app", productId: "monthly" });

    const payload = await verifyAppleJws(jws, { trustedRootDer: chain.root.der });

    expect(payload).toEqual({ bundleId: "com.example.app", productId: "monthly" });
  });

  it("verifies Apple's real chain shape: a P-256 leaf under P-384 CAs", async () => {
    // Not a hypothetical. Apple Root CA - G3 and the WWDR G6 intermediate are
    // both P-384 signing with ecdsa-with-SHA384, while the leaf that signs the
    // JWS is P-256/ES256. A verifier that assumes one curve for the whole
    // chain fails every real payload with "Named curve mismatch".
    const chain = await mintChain({ caCurve: "P-384" });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    const payload = await verifyAppleJws(jws, { trustedRootDer: chain.root.der });

    expect(payload.bundleId).toBe("com.example.app");
  });

  it("rejects a leaf whose key is not P-256, whatever the header claims", async () => {
    const chain = await mintChain({ caCurve: "P-384", leaf: { curve: "P-384" } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/ES256 requires a P-256 leaf key/);
  });

  it("rejects a chain rooted anywhere but the trusted root", async () => {
    // The attack this is the whole defence against: a valid, internally
    // consistent chain, signed by a key the attacker owns.
    const attacker = await mintChain();
    const jws = await signJws(attacker, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: APPLE_ROOT_CA_G3_DER }),
    ).rejects.toThrow(/does not terminate at the trusted root/);
  });

  it("rejects a tampered payload", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app", productId: "monthly" });
    const [header, , signature] = jws.split(".");
    const forged = btoa(JSON.stringify({ bundleId: "com.example.app", productId: "yearly" }))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");

    await expect(
      verifyAppleJws(`${header}.${forged}.${signature}`, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/signature does not verify/);
  });

  it("rejects a leaf that its stated intermediate did not sign", async () => {
    const chain = await mintChain();
    // A leaf signed by an unrelated CA, presented alongside the real chain.
    const impostorCa = await mintCertificate({ commonName: "Impostor CA" });
    const impostorLeaf = await mintCertificate({
      commonName: "Test Leaf",
      issuer: impostorCa,
      issuerCommonName: "Test Intermediate CA",
    });
    const spliced = {
      ...chain,
      leaf: impostorLeaf,
      x5c: [impostorLeaf.base64, chain.intermediate.base64, chain.root.base64],
    };
    const jws = await signJws(spliced, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[0\] is not signed by x5c\[1\]/);
  });

  it("rejects an expired certificate", async () => {
    const chain = await mintChain({
      leaf: {
        notBefore: new Date(Date.now() - 10 * DAY_MS),
        notAfter: new Date(Date.now() - DAY_MS),
      },
    });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/outside its validity period/);
  });

  it("accepts a certificate that was valid at the given instant", async () => {
    const notAfter = new Date(Date.now() - DAY_MS);
    const chain = await mintChain({
      leaf: { notBefore: new Date(Date.now() - 10 * DAY_MS), notAfter },
    });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    const payload = await verifyAppleJws(jws, {
      trustedRootDer: chain.root.der,
      now: new Date(notAfter.getTime() - 1000),
    });

    expect(payload.bundleId).toBe("com.example.app");
  });

  it("rejects an algorithm other than ES256", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app" }, { alg: "none" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/unsupported JWS algorithm/);
  });

  it("rejects a header with no x5c chain", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app" }, { x5c: undefined });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/no usable x5c chain/);
  });

  it("rejects a malformed envelope", async () => {
    await expect(
      verifyAppleJws("not-a-jws", { trustedRootDer: APPLE_ROOT_CA_G3_DER }),
    ).rejects.toBeInstanceOf(AppleJwsError);
  });

  it("rejects x5c entries that are not certificates", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app" }, { x5c: ["Zm9v", "YmFy"] });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/not a parseable certificate/);
  });
});

describe("decodeAppleJwsPayloadUnverified", () => {
  it("reads a payload without checking anything", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { notificationType: "DID_RENEW" });

    expect(decodeAppleJwsPayloadUnverified(jws)).toEqual({ notificationType: "DID_RENEW" });
  });

  it("returns null for a malformed envelope", () => {
    expect(decodeAppleJwsPayloadUnverified("garbage")).toBeNull();
  });
});

describe("the pinned Apple root", () => {
  // Guards the committed bytes against a careless edit: a truncated or
  // re-wrapped base64 blob would still decode to *something*, and the failure
  // would only show up as production notifications silently failing to verify.
  // Every other test in this file verifies chains built by our own fixture
  // code, which could agree with the parser on an encoding Apple does not use.
  // Presenting the real certificate proves the DER walk handles Apple's actual
  // bytes: it has to parse the certificate, read its 2014-2039 validity, and
  // import its P-256 key into WebCrypto before it can get as far as reporting
  // a signature mismatch. A parse or import failure would surface as a
  // different error here.
  it("is parsed, date-checked and key-imported from its real bytes", async () => {
    const chain = await mintChain();
    const jws = await signJws(chain, { bundleId: "com.example.app" }, {
      x5c: [chain.leaf.base64, chain.intermediate.base64, toBase64(APPLE_ROOT_CA_G3_DER)],
    });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: APPLE_ROOT_CA_G3_DER }),
    ).rejects.toThrow(/x5c\[1\] is not signed by x5c\[2\]/);
  });

  it("parses as the expected certificate", async () => {
    expect(APPLE_ROOT_CA_G3_DER.length).toBe(583);
    const digest = await crypto.subtle.digest("SHA-256", APPLE_ROOT_CA_G3_DER.slice().buffer);
    const fingerprint = [...new Uint8Array(digest)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    expect(fingerprint).toBe(
      "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    );
  });
});

// The check that turns a set of signatures into a chain. Without it, any
// end-entity certificate under the pinned root works as an intermediate — and
// Apple issues those to every Developer Program member, so the trust anchor
// stops meaning anything.
describe("issuer authority", () => {
  /// The attack, in full: a certificate the attacker owns, certified by an
  /// ordinary end-entity leaf that legitimately chains to the trusted root.
  async function forgeUnderEndEntity(chain: Awaited<ReturnType<typeof mintChain>>) {
    const forged = await mintCertificate({
      commonName: "Forged Receipt Signer",
      issuer: chain.leaf,
      issuerCommonName: "Test Leaf",
      serial: 99,
    });
    const header = toBase64Url(JSON.stringify({
      alg: "ES256",
      x5c: [toBase64(forged.der), chain.leaf.base64, chain.intermediate.base64, chain.root.base64],
    }));
    const payload = toBase64Url(JSON.stringify({ bundleId: "com.example.app" }));
    const signature = new Uint8Array(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      forged.keyPair.privateKey,
      new TextEncoder().encode(`${header}.${payload}`),
    ));
    return `${header}.${payload}.${toBase64Url(signature)}`;
  }

  it("rejects a leaf certified by another leaf", async () => {
    const chain = await mintChain();
    const jws = await forgeUnderEndEntity(chain);

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[1\] is not a CA certificate/);
  });

  it("rejects an intermediate whose basicConstraints says cA is false", async () => {
    const chain = await mintChain({ intermediate: { ca: false } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[1\] is not a CA certificate/);
  });

  it("rejects an intermediate with no basicConstraints at all", async () => {
    // RFC 5280: an absent extension means cA is false. Reading a missing
    // extension as permission is the same bug in a quieter form.
    const chain = await mintChain({ intermediate: { ca: undefined, keyCertSign: undefined } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[1\] is not a CA certificate/);
  });

  it("rejects a CA whose keyUsage does not assert keyCertSign", async () => {
    const chain = await mintChain({ intermediate: { ca: true, keyCertSign: false } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[1\] does not assert keyCertSign/);
  });

  it("accepts a CA that omits keyUsage entirely", async () => {
    // Optional in RFC 5280, and absent is "unconstrained" rather than "denied".
    const chain = await mintChain({ intermediate: { ca: true, keyCertSign: undefined } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    const payload = await verifyAppleJws(jws, { trustedRootDer: chain.root.der });

    expect(payload.bundleId).toBe("com.example.app");
  });

  it("accepts a leaf that omits basicConstraints, as a real one may", async () => {
    const chain = await mintChain({ leaf: { ca: undefined, keyCertSign: undefined } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    const payload = await verifyAppleJws(jws, { trustedRootDer: chain.root.der });

    expect(payload.bundleId).toBe("com.example.app");
  });

  it("rejects a leaf that is itself a CA", async () => {
    const chain = await mintChain({ leaf: { ca: true, keyCertSign: true } });
    const jws = await signJws(chain, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[0\] is a CA certificate, not a leaf/);
  });

  it("honours pathLenConstraint on an intermediate", async () => {
    // pathLen 0 permits no intermediate below this one, so a four-element
    // chain that puts a CA underneath it is out of bounds even when every
    // certificate in it is a CA.
    const chain = await mintChain({ intermediate: { pathLen: 0 } });
    const subCa = await mintCertificate({
      commonName: "Test Sub CA",
      issuer: chain.intermediate,
      issuerCommonName: "Test Intermediate CA",
      serial: 4,
      ca: true,
      keyCertSign: true,
    });
    const leaf = await mintCertificate({
      commonName: "Test Leaf",
      issuer: subCa,
      issuerCommonName: "Test Sub CA",
      serial: 5,
      ca: false,
    });
    const spliced = {
      ...chain,
      leaf,
      x5c: [leaf.base64, subCa.base64, chain.intermediate.base64, chain.root.base64],
    };
    const jws = await signJws(spliced, { bundleId: "com.example.app" });

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c\[2\] exceeds its pathLenConstraint/);
  });

  it("rejects a chain longer than Apple sends, before verifying any of it", async () => {
    const chain = await mintChain();
    const jws = await signJws(
      { ...chain, x5c: [...chain.x5c, chain.root.base64, chain.root.base64] },
      { bundleId: "com.example.app" },
    );

    await expect(
      verifyAppleJws(jws, { trustedRootDer: chain.root.der }),
    ).rejects.toThrow(/x5c chain is too long/);
  });
});

function toBase64Url(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
