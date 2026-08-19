// Mints an ECDSA P-256 certificate chain and signs JWS envelopes with it, so
// the Apple JWS verifier can be tested without Apple's private key.
//
// Certificates are built here rather than committed as fixtures for one
// practical reason: a committed certificate has fixed validity dates and will
// eventually expire, turning a correct verifier into a failing test suite on
// some morning years from now. Minting them at run time means the happy path is
// always inside its validity window, and the expiry test can ask for a
// certificate that expired yesterday on purpose.
//
// Only the DER encoding the verifier actually reads is produced faithfully:
// version, serial, algorithm, issuer/subject names, validity, and the public
// key. Extensions are omitted — the verifier does not look at them.

const encoder = new TextEncoder();

// --- DER writing -----------------------------------------------------------

function derLength(length: number): number[] {
  if (length < 0x80) return [length];
  const bytes: number[] = [];
  let remaining = length;
  while (remaining > 0) {
    bytes.unshift(remaining & 0xff);
    remaining = Math.floor(remaining / 256);
  }
  return [0x80 | bytes.length, ...bytes];
}

function der(tag: number, content: Uint8Array): Uint8Array {
  const header = [tag, ...derLength(content.length)];
  const out = new Uint8Array(header.length + content.length);
  out.set(header, 0);
  out.set(content, header.length);
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

const derSequence = (...parts: Uint8Array[]) => der(0x30, concat(parts));
const derSet = (...parts: Uint8Array[]) => der(0x31, concat(parts));

function derInteger(value: number): Uint8Array {
  const bytes: number[] = [];
  let remaining = value;
  do {
    bytes.unshift(remaining & 0xff);
    remaining = Math.floor(remaining / 256);
  } while (remaining > 0);
  // INTEGER is signed: a leading high bit would read as negative.
  if (bytes[0] & 0x80) bytes.unshift(0);
  return der(0x02, new Uint8Array(bytes));
}

function derOid(dotted: string): Uint8Array {
  const parts = dotted.split(".").map(Number);
  const bytes: number[] = [parts[0] * 40 + parts[1]];
  for (const part of parts.slice(2)) {
    const chunks: number[] = [part & 0x7f];
    let remaining = Math.floor(part / 128);
    while (remaining > 0) {
      chunks.unshift((remaining & 0x7f) | 0x80);
      remaining = Math.floor(remaining / 128);
    }
    bytes.push(...chunks);
  }
  return der(0x06, new Uint8Array(bytes));
}

function derUtcTime(date: Date): Uint8Array {
  const pad = (value: number) => String(value).padStart(2, "0");
  const text =
    `${pad(date.getUTCFullYear() % 100)}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}` +
    `${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
  return der(0x17, encoder.encode(text));
}

/// A Name holding a single CN, which is all the verifier needs to see.
function derName(commonName: string): Uint8Array {
  return derSequence(
    derSet(derSequence(derOid("2.5.4.3"), der(0x0c, encoder.encode(commonName)))),
  );
}

const ECDSA_WITH_SHA256 = derSequence(derOid("1.2.840.10045.4.3.2"));
const ECDSA_WITH_SHA384 = derSequence(derOid("1.2.840.10045.4.3.3"));

/// Apple's real chain is mixed: a P-256 leaf signing the JWS, under P-384 CA
/// certificates signing with SHA-384. Fixtures can reproduce that shape.
const CURVES = {
  "P-256": { hash: "SHA-256", algorithm: ECDSA_WITH_SHA256 },
  "P-384": { hash: "SHA-384", algorithm: ECDSA_WITH_SHA384 },
} as const;

export type TestCurve = keyof typeof CURVES;

/// WebCrypto hands back fixed-width r||s; X.509 wants SEQUENCE { r, s }.
function rawEcdsaSignatureToDer(raw: Uint8Array): Uint8Array {
  const component = (bytes: Uint8Array) => {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    const trimmed = Array.from(bytes.subarray(start));
    if (trimmed[0] & 0x80) trimmed.unshift(0);
    return der(0x02, new Uint8Array(trimmed));
  };
  const half = raw.length / 2;
  return derSequence(component(raw.subarray(0, half)), component(raw.subarray(half)));
}

// --- Certificates ----------------------------------------------------------

export interface TestCertificate {
  der: Uint8Array;
  base64: string;
  keyPair: CryptoKeyPair;
  curve: TestCurve;
}

export interface MintOptions {
  commonName: string;
  /// Omit for a self-signed certificate.
  issuer?: TestCertificate;
  issuerCommonName?: string;
  notBefore?: Date;
  notAfter?: Date;
  serial?: number;
  curve?: TestCurve;
}

const YEAR_MS = 365 * 24 * 60 * 60 * 1000;

export async function mintCertificate(options: MintOptions): Promise<TestCertificate> {
  const curve = options.curve ?? "P-256";
  const keyPair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: curve },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const spki = new Uint8Array(
    (await crypto.subtle.exportKey("spki", keyPair.publicKey)) as ArrayBuffer,
  );

  const notBefore = options.notBefore ?? new Date(Date.now() - YEAR_MS);
  const notAfter = options.notAfter ?? new Date(Date.now() + YEAR_MS);
  const issuerName = options.issuerCommonName ?? options.commonName;

  // The signature algorithm is the *issuer's*, since the issuer's key makes
  // it — a P-256 leaf under a P-384 CA is signed with SHA-384.
  const signingAlgorithm = CURVES[options.issuer?.curve ?? curve];

  const tbs = derSequence(
    // [0] EXPLICIT version, v3.
    der(0xa0, derInteger(2)),
    derInteger(options.serial ?? 1),
    signingAlgorithm.algorithm,
    derName(issuerName),
    derSequence(derUtcTime(notBefore), derUtcTime(notAfter)),
    derName(options.commonName),
    spki,
  );

  // A self-signed certificate signs itself; anything else is signed by its
  // issuer's key.
  const signingKey = options.issuer?.keyPair.privateKey ?? keyPair.privateKey;
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: signingAlgorithm.hash }, signingKey, tbs),
  );
  const certificateDer = derSequence(
    tbs,
    signingAlgorithm.algorithm,
    // BIT STRING, zero unused bits.
    der(0x03, concat([new Uint8Array([0]), rawEcdsaSignatureToDer(rawSignature)])),
  );

  return { der: certificateDer, base64: toBase64(certificateDer), keyPair, curve };
}

export interface TestChain {
  root: TestCertificate;
  intermediate: TestCertificate;
  leaf: TestCertificate;
  /// In x5c order: leaf first, root last.
  x5c: string[];
}

export async function mintChain(
  overrides: { leaf?: Partial<MintOptions>; caCurve?: TestCurve } = {},
): Promise<TestChain> {
  const caCurve = overrides.caCurve ?? "P-256";
  const root = await mintCertificate({ commonName: "Test Root CA", curve: caCurve });
  const intermediate = await mintCertificate({
    commonName: "Test Intermediate CA",
    issuer: root,
    issuerCommonName: "Test Root CA",
    serial: 2,
    curve: caCurve,
  });
  const leaf = await mintCertificate({
    commonName: "Test Leaf",
    issuer: intermediate,
    issuerCommonName: "Test Intermediate CA",
    serial: 3,
    ...overrides.leaf,
  });
  return {
    root,
    intermediate,
    leaf,
    x5c: [leaf.base64, intermediate.base64, root.base64],
  };
}

// --- JWS -------------------------------------------------------------------

export async function signJws(
  chain: TestChain,
  payload: unknown,
  headerOverrides: Record<string, unknown> = {},
): Promise<string> {
  const header = toBase64Url(
    encoder.encode(JSON.stringify({ alg: "ES256", x5c: chain.x5c, ...headerOverrides })),
  );
  const body = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      chain.leaf.keyPair.privateKey,
      encoder.encode(`${header}.${body}`),
    ),
  );
  return `${header}.${body}.${toBase64Url(signature)}`;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
